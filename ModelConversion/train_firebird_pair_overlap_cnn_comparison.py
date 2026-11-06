#!/usr/bin/env python3
"""Compare shared-encoder CNNs with the pair-overlap ViT on identical font pairs."""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
from pathlib import Path

import numpy as np
import torch
from torch import Tensor, nn
from torch.nn import functional as F
from torch.utils.data import DataLoader

from train_firebird_pair_overlap_vit import (
    PairDataset,
    PairOverlapViT,
    SCALES,
    evaluate,
    font_pair_records,
    sha256,
)


class ResidualBlock(nn.Module):
    def __init__(self, in_channels: int, out_channels: int, stride: int = 1) -> None:
        super().__init__()
        self.body = nn.Sequential(
            nn.Conv2d(in_channels, out_channels, 3, stride=stride, padding=1, bias=False),
            nn.GroupNorm(8, out_channels),
            nn.GELU(),
            nn.Conv2d(out_channels, out_channels, 3, padding=1, bias=False),
            nn.GroupNorm(8, out_channels),
        )
        self.skip = nn.Identity() if stride == 1 and in_channels == out_channels else nn.Sequential(
            nn.Conv2d(in_channels, out_channels, 1, stride=stride, bias=False),
            nn.GroupNorm(8, out_channels),
        )

    def forward(self, x: Tensor) -> Tensor:
        return F.gelu(self.body(x) + self.skip(x))


class ResidualEncoder(nn.Module):
    """Spatially preserving residual CNN with global average/max descriptors."""

    def __init__(self) -> None:
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(2, 32, 3, padding=1, bias=False), nn.GroupNorm(8, 32), nn.GELU(),
            ResidualBlock(32, 32), ResidualBlock(32, 48, stride=2),
            ResidualBlock(48, 48), ResidualBlock(48, 64, stride=2),
            ResidualBlock(64, 64), ResidualBlock(64, 96, stride=2),
            ResidualBlock(96, 96),
        )
        self.project = nn.Sequential(nn.Linear(192, 128), nn.GELU(), nn.LayerNorm(128))

    def forward(self, image: Tensor) -> Tensor:
        feature = self.features(image)
        pooled = torch.cat((F.adaptive_avg_pool2d(feature, 1).flatten(1),
                            F.adaptive_max_pool2d(feature, 1).flatten(1)), dim=1)
        return self.project(pooled)


class DepthwiseBlock(nn.Module):
    def __init__(self, in_channels: int, out_channels: int, stride: int) -> None:
        super().__init__()
        self.depthwise = nn.Sequential(
            nn.Conv2d(in_channels, in_channels, 3, stride=stride, padding=1,
                      groups=in_channels, bias=False),
            nn.BatchNorm2d(in_channels), nn.SiLU(),
        )
        self.pointwise = nn.Sequential(
            nn.Conv2d(in_channels, out_channels, 1, bias=False),
            nn.BatchNorm2d(out_channels), nn.SiLU(),
        )
        self.residual = stride == 1 and in_channels == out_channels

    def forward(self, x: Tensor) -> Tensor:
        y = self.pointwise(self.depthwise(x))
        return y + x if self.residual else y


class MobileEncoder(nn.Module):
    """Depthwise-separable CNN candidate for a smaller on-device encoder."""

    def __init__(self) -> None:
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(2, 24, 3, stride=2, padding=1, bias=False), nn.BatchNorm2d(24), nn.SiLU(),
            DepthwiseBlock(24, 24, 1), DepthwiseBlock(24, 32, 2),
            DepthwiseBlock(32, 32, 1), DepthwiseBlock(32, 48, 2),
            DepthwiseBlock(48, 48, 1), DepthwiseBlock(48, 64, 2),
            DepthwiseBlock(64, 96, 2), DepthwiseBlock(96, 96, 1),
        )
        self.project = nn.Sequential(nn.Linear(192, 128), nn.SiLU(), nn.LayerNorm(128))

    def forward(self, image: Tensor) -> Tensor:
        feature = self.features(image)
        pooled = torch.cat((F.adaptive_avg_pool2d(feature, 1).flatten(1),
                            F.adaptive_max_pool2d(feature, 1).flatten(1)), dim=1)
        return self.project(pooled)


class MultiScaleEncoder(nn.Module):
    """Multi-kernel CNN with spatial-pyramid pooling to retain coarse layout."""

    def __init__(self) -> None:
        super().__init__()
        branch_width = 24
        self.branches = nn.ModuleList([
            nn.Sequential(nn.Conv2d(2, branch_width, kernel, padding=kernel // 2, bias=False),
                          nn.GroupNorm(8, branch_width), nn.GELU())
            for kernel in (3, 5, 7)
        ])
        self.fuse = nn.Sequential(nn.Conv2d(branch_width * 3, 48, 1, bias=False),
                                  nn.GroupNorm(8, 48), nn.GELU())
        self.features = nn.Sequential(
            ResidualBlock(48, 48), ResidualBlock(48, 64, stride=2),
            ResidualBlock(64, 64), ResidualBlock(64, 96, stride=2),
            ResidualBlock(96, 96),
        )
        self.project = nn.Sequential(nn.Linear(96 * 21, 128), nn.GELU(), nn.LayerNorm(128))

    def forward(self, image: Tensor) -> Tensor:
        feature = self.features(self.fuse(torch.cat([branch(image) for branch in self.branches], dim=1)))
        pyramid = [F.adaptive_avg_pool2d(feature, (side, side)).flatten(1) for side in (1, 2, 4)]
        return self.project(torch.cat(pyramid, dim=1))


class PairOverlapCNN(nn.Module):
    def __init__(self, family: str) -> None:
        super().__init__()
        encoders = {
            "residual": ResidualEncoder,
            "mobile": MobileEncoder,
            "multiscale": MultiScaleEncoder,
        }
        self.family = family
        self.encoder = encoders[family]()
        self.head = nn.Sequential(nn.LayerNorm(256), nn.Linear(256, 128), nn.GELU(),
                                  nn.Dropout(0.1), nn.Linear(128, len(SCALES)))

    def forward(self, a: Tensor, b: Tensor) -> Tensor:
        encoded = self.encoder(torch.cat((a, b), dim=0))
        left, right = encoded.chunk(2, dim=0)
        symmetric = torch.cat(((left - right).abs(), left * right), dim=1)
        return torch.sigmoid(self.head(symmetric))


def parameter_count(model: nn.Module) -> int:
    return sum(parameter.numel() for parameter in model.parameters())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-report", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--shape-corpus", type=Path, required=True)
    parser.add_argument("--canonical-corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--all-fit-fonts", action="store_true",
                        help="build pair teachers from every font in the disjoint fit split")
    args = parser.parse_args()
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is required; CPU training is prohibited.")
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite comparison run: {args.output}")

    reference = json.loads(args.reference_report.read_text())
    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    rows = manifest["rows"]
    expected_hashes = {
        "corpusManifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
        "contourSkeletonCorpusSHA256": sha256(args.shape_corpus),
        "canonicalCorpusSHA256": sha256(args.canonical_corpus),
    }
    for key, actual in expected_hashes.items():
        if actual != reference[key]:
            raise ValueError(f"{key} differs from ViT reference report")
    if manifest.get("schema") != "firebird-mac-font-glyph-raster-v1" or len(rows) != 68_689:
        raise ValueError("authoritative 68,689-row font corpus is required")
    expected_size = len(rows) * 2 * 64 * 64
    if args.shape_corpus.stat().st_size != expected_size or args.canonical_corpus.stat().st_size != expected_size:
        raise ValueError("contour/skeleton corpus byte count does not match the manifest")

    corpus = np.memmap(args.canonical_corpus, mode="r", dtype=np.uint8,
                       shape=(len(rows), 2, 64, 64))
    seed = 20261106
    pair_target_fonts = reference["fitFontFiles"] if args.all_fit_fonts else reference["pairTargetFontFiles"]
    train_records, train_counts = font_pair_records(
        rows, corpus, pair_target_fonts, seed, 30_000, require_positive=True)
    valid_records, valid_counts = font_pair_records(
        rows, corpus, reference["validationFontFiles"], seed + 1, 8_000, require_positive=False)
    if not args.all_fit_fonts and train_counts != reference["fitPairCounts"]:
        raise ValueError("reconstructed fit records differ from the ViT reference counts")
    if valid_counts != reference["validationPairCounts"]:
        raise ValueError("reconstructed validation records differ from the ViT reference counts")
    args.output.mkdir(parents=True)
    device = torch.device("mps")
    read_only_corpus = np.memmap(args.canonical_corpus, mode="r", dtype=np.uint8,
                                 shape=(len(rows), 2, 64, 64))
    history: dict[str, list[dict]] = {}
    selected: dict[str, dict] = {}
    model_factories = {
        "vit": PairOverlapViT,
        "residual": lambda: PairOverlapCNN("residual"),
        "mobile": lambda: PairOverlapCNN("mobile"),
        "multiscale": lambda: PairOverlapCNN("multiscale"),
    }
    for family, factory in model_factories.items():
        torch.manual_seed(seed)
        np.random.seed(seed)
        model = factory().to(device)
        fit_data = PairDataset(read_only_corpus, train_records, augment=True, seed=seed)
        fit_generator = torch.Generator(device="cpu").manual_seed(seed + 1)
        loader = DataLoader(fit_data, batch_size=128, shuffle=True, generator=fit_generator,
                            num_workers=0, drop_last=False)
        optimizer = torch.optim.AdamW(model.parameters(), lr=2e-4, weight_decay=1e-4)
        best_mae = float("inf")
        family_history = []
        for epoch in range(1, 13):
            fit_data.set_epoch(epoch)
            model.train()
            loss_sum = 0.0
            seen = 0
            for a, b, target in loader:
                a = a.to(device=device, dtype=torch.float32)
                b = b.to(device=device, dtype=torch.float32)
                target = target.to(device=device, dtype=torch.float32)
                prediction = model(a, b)
                loss = F.smooth_l1_loss(prediction, target)
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                optimizer.step()
                loss_sum += float(loss.detach()) * len(target)
                seen += len(target)
            validation = evaluate(model, read_only_corpus, valid_records, device)
            epoch_row = {"epoch": epoch, "fitLoss": loss_sum / seen,
                         "fitPairCount": seen, "validation": validation}
            family_history.append(epoch_row)
            print(json.dumps({"architecture": family, **epoch_row}, ensure_ascii=False), flush=True)
            if validation["macroMAE"] < best_mae:
                best_mae = validation["macroMAE"]
                checkpoint = args.output / f"{family}-best.pt"
                torch.save({"state_dict": {k: v.detach().cpu() for k, v in model.state_dict().items()},
                            "architecture": family, "epoch": epoch,
                            "validationMacroMAE": best_mae, "seed": seed,
                            "canonicalCorpusSHA256": expected_hashes["canonicalCorpusSHA256"]}, checkpoint)
                selected[family] = {"epoch": epoch, "validation": validation,
                                    "parameterCount": parameter_count(model),
                                    "checkpoint": str(checkpoint)}
        history[family] = family_history
        del model, fit_data, loader, optimizer
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()

    report = {
        "schema": "firebird-pair-overlap-cnn-architecture-comparison-v1",
        "task": reference["task"],
        "targetDefinition": reference["targetDefinition"],
        "targetIsHumanAnnotation": False,
        "conditions": {
            "seed": seed, "epochs": 12, "batchSize": 128, "optimizer": "AdamW",
            "learningRate": 0.0002, "weightDecay": 0.0001, "loss": "SmoothL1",
            "gradientClipNorm": 1.0, "augmentation": reference["trainingDataAugmentation"],
            "trainingDevice": "Apple MPS", "fitPoolFonts": reference["fitFontFiles"],
            "pairTargetFonts": pair_target_fonts,
            "pairTargetFontPolicy": "all 202 disjoint fit fonts" if args.all_fit_fonts else "the 96-font ViT reference subset",
            "validationFonts": reference["validationFontFiles"],
            "generationFontsNotOpened": True, "outerTestNotOpened": True,
        },
        "inputHashes": expected_hashes,
        "fitPairCounts": train_counts, "validationPairCounts": valid_counts,
        "architectures": selected,
        "history": history,
        "viTReferencePriorRun": {
            "run": reference["checkpoint"], "selectedEpoch": reference["selectedEpoch"],
            "macroMAE": reference["history"][reference["selectedEpoch"] - 1]["validation"]["macroMAE"],
            "macroBalancedAccuracyAtHalf": reference["history"][reference["selectedEpoch"] - 1]["validation"]["macroBalancedAccuracyAtHalf"],
            "note": "prior run; architecture screening is additionally retrained under the common loader below",
        },
        "limitations": [
            "The target is raster contour/skeleton overlap, not human semantic similarity.",
            "Model selection uses the same 10 validation fonts; this is not an outer-test result.",
            "No semantic subset is accepted solely from these architecture metrics.",
        ],
    }
    report_path = args.output / "comparison-report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"stage": "complete", "report": str(report_path),
                      "selected": {name: {"epoch": value["epoch"],
                                          "macroMAE": value["validation"]["macroMAE"],
                                          "macroBalancedAccuracyAtHalf": value["validation"]["macroBalancedAccuracyAtHalf"]}
                                   for name, value in selected.items()},
                      "device": platform.node()}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
