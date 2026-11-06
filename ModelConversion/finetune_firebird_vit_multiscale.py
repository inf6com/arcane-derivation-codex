#!/usr/bin/env python3
"""Controlled ViT fine-tuning for raster-resolution and blur robustness."""
from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
from torch.utils.data import DataLoader, TensorDataset, WeightedRandomSampler

from train_firebird_typeset_vit import FontGlyphViT


def degrade(images: torch.Tensor, mode: str) -> torch.Tensor:
    """Apply label-preserving, 64x64 raster degradation to training batches only."""
    if mode == "none":
        return images
    batch = images.shape[0]
    output = images.clone()
    if mode in {"resolution", "combined"}:
        sizes = torch.tensor((16, 24, 32, 48, 64), device=images.device)
        chosen = sizes[torch.randint(len(sizes), (batch,), device=images.device)]
        for size in torch.unique(chosen).tolist():
            mask = chosen == size
            if size != 64:
                low = F.interpolate(images[mask], size=(size, size), mode="bilinear",
                                    align_corners=False, antialias=True)
                output[mask] = F.interpolate(low, size=(64, 64), mode="bilinear", align_corners=False)
    if mode in {"blur", "combined"}:
        kernels = (3, 5, 7)
        chosen = torch.randint(len(kernels) + 1, (batch,), device=images.device)
        for selection, kernel_size in enumerate(kernels, start=1):
            mask = chosen == selection
            if not mask.any():
                continue
            sigma = (0.45, 0.75, 1.05)[selection - 1]
            axis = torch.arange(kernel_size, device=images.device, dtype=images.dtype) - (kernel_size - 1) / 2
            kernel = torch.exp(-(axis * axis) / (2 * sigma * sigma))
            kernel = kernel / kernel.sum()
            kernel2d = torch.outer(kernel, kernel).view(1, 1, kernel_size, kernel_size)
            output[mask] = F.conv2d(output[mask], kernel2d, padding=kernel_size // 2)
    return output.clamp_(0.0, 1.0)


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--images", type=Path, required=True)
    p.add_argument("--manifest", type=Path, required=True)
    p.add_argument("--split", type=Path, required=True)
    p.add_argument("--class-map", type=Path, required=True)
    p.add_argument("--checkpoint", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--epochs", type=int, default=4)
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--learning-rate", type=float, default=0.00001)
    p.add_argument("--seed", type=int, default=20261104)
    args = p.parse_args()
    if args.epochs < 1 or args.batch_size < 1 or args.learning_rate <= 0:
        raise ValueError("epochs, batch size, and learning rate must be positive")
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required; CPU fallback is prohibited")
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite experiment output: {args.output}")
    for path in (args.images, args.manifest, args.split, args.class_map, args.checkpoint):
        if not path.is_file():
            raise FileNotFoundError(path)

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    torch.mps.manual_seed(args.seed)
    device = torch.device("mps")
    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    rows = manifest["rows"]
    if manifest.get("schema") != "firebird-mac-font-glyph-raster-v1" or (manifest["width"], manifest["height"]) != (64, 64):
        raise ValueError("expected the verified 64x64 Mac-font raster corpus")
    if args.images.stat().st_size != len(rows) * 64 * 64:
        raise ValueError("raster byte count does not match manifest")
    class_map = json.loads(args.class_map.read_text())
    vocab_to_class = {int(x["vocabularyIndex"]): int(x["classIndex"]) for x in class_map}
    if len(vocab_to_class) != 228 or set(x["classIndex"] for x in class_map) != set(range(228)):
        raise ValueError("checkpoint class map must contain the verified contiguous 228 glyph labels")
    split = json.loads(args.split.read_text())
    train_fonts, valid_fonts = set(split["trainFontFileSHA256"]), set(split["validationFontFileSHA256"])
    if train_fonts & valid_fonts:
        raise ValueError("font file leakage detected")

    raw = np.memmap(args.images, mode="r", dtype=np.uint8, shape=(len(rows), 64, 64))
    train_indices, valid_indices, train_targets, valid_targets = [], [], [], []
    for i, row in enumerate(rows):
        vi = int(row["vocabularyIndex"])
        if vi not in vocab_to_class:
            raise ValueError(f"corpus label missing from checkpoint class map: {row['label']}")
        font_hash = row["fontFileSHA256"]
        if font_hash in train_fonts:
            train_indices.append(i); train_targets.append(vocab_to_class[vi])
        elif font_hash in valid_fonts:
            valid_indices.append(i); valid_targets.append(vocab_to_class[vi])
        else:
            raise ValueError("manifest row font is absent from the frozen split")
    train_x = torch.from_numpy(np.array(raw[train_indices], copy=True)).unsqueeze(1).float().div_(255)
    valid_x = torch.from_numpy(np.array(raw[valid_indices], copy=True)).unsqueeze(1).float().div_(255)
    train_y = torch.tensor(train_targets, dtype=torch.long)
    valid_y = torch.tensor(valid_targets, dtype=torch.long)
    train_counts = torch.bincount(train_y, minlength=228).float()
    valid_loader = DataLoader(TensorDataset(valid_x, valid_y), batch_size=args.batch_size, shuffle=False)

    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    if checkpoint.get("classMap") != class_map:
        raise ValueError("checkpoint and supplied class map differ")
    init_state = checkpoint["model"]
    baseline_report = json.loads(Path("runs/firebird-typeset-vit-fold7-corrected-20261104/training-report.json").read_text())
    if hashlib.sha256(manifest_bytes).hexdigest() != baseline_report["corpusManifestSHA256"]:
        raise ValueError("font manifest differs from the baseline ViT training corpus")
    if digest(args.images) != baseline_report["rawRasterSHA256"]:
        raise ValueError("font raster bytes differ from the baseline ViT training corpus")
    expected_checkpoint = Path("runs/firebird-typeset-vit-fold7-corrected-20261104") / baseline_report["bestCheckpoint"]
    if args.checkpoint.resolve() != expected_checkpoint.resolve():
        raise ValueError("initial checkpoint path differs from the recorded baseline")
    modes = ("resolution", "blur", "combined")
    args.output.mkdir(parents=True)
    manifest_out = {
        "schema": "firebird-vit-multiscale-finetune-screen-v1",
        "startingCheckpoint": str(args.checkpoint), "startingCheckpointSHA256": digest(args.checkpoint),
        "sourceFontManifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
        "fontSplitSHA256": digest(args.split), "classMapSHA256": digest(args.class_map),
        "trainFontCount": len(train_fonts), "validationFontCount": len(valid_fonts),
        "trainImageCount": len(train_y), "validationImageCount": len(valid_y),
        "validationUsesUnmodifiedRasters": True,
        "candidateModes": list(modes), "epochs": args.epochs, "batchSize": args.batch_size,
        "learningRate": args.learning_rate, "seed": args.seed,
        "degradation": {"resolutionEdges": [16, 24, 32, 48, 64],
                         "downsample": "antialiased bilinear", "upsample": "bilinear to 64x64",
                         "blurKernels": {"3x3": 0.45, "5x5": 0.75, "7x7": 1.05},
                         "modes": "one random degradation per image; no stroke or coordinate inputs"},
        "selectionRule": "highest held-out-font macro Top1; Top5 and clean-view Top1 are co-reported",
        "outerTestOpened": False,
    }
    (args.output / "experiment.json").write_text(json.dumps(manifest_out, ensure_ascii=False, indent=2) + "\n")
    all_results = {}
    for mode_index, mode in enumerate(modes):
        torch.manual_seed(args.seed + mode_index)
        sampler = WeightedRandomSampler(train_counts[train_y].clamp_min(1).reciprocal(), len(train_y),
                                        replacement=True, generator=torch.Generator().manual_seed(args.seed))
        train_loader = DataLoader(TensorDataset(train_x, train_y), batch_size=args.batch_size, sampler=sampler)
        model = FontGlyphViT(228).to(device)
        model.load_state_dict(init_state, strict=True)
        optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=0.01)
        history, best_macro, best_state = [], -1.0, None
        for epoch in range(1, args.epochs + 1):
            model.train()
            loss_sum, seen = 0.0, 0
            for images, labels in train_loader:
                images = degrade(images.to(device), mode)
                labels = labels.to(device)
                optimizer.zero_grad(set_to_none=True)
                logits = model(images)
                loss = F.cross_entropy(logits, labels, label_smoothing=0.05)
                loss.backward()
                nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                optimizer.step()
                loss_sum += float(loss.item()) * labels.numel(); seen += labels.numel()
            model.eval(); true, logits_parts = [], []
            with torch.inference_mode():
                for images, labels in valid_loader:
                    logits_parts.append(model(images.to(device)).cpu()); true.append(labels)
            y, logits = torch.cat(true), torch.cat(logits_parts)
            top = logits.topk(5, dim=1).indices
            correct1, correct5 = logits.argmax(1).eq(y), top.eq(y[:, None]).any(1)
            per_class1, per_class5 = [], []
            for cls in torch.unique(y):
                mask = y.eq(cls)
                per_class1.append(float(correct1[mask].float().mean()))
                per_class5.append(float(correct5[mask].float().mean()))
            row = {"epoch": epoch, "mode": mode, "trainLoss": loss_sum / seen,
                   "validationTop1": float(correct1.float().mean()),
                   "validationTop5": float(correct5.float().mean()),
                   "validationMacroTop1": float(np.mean(per_class1)),
                   "validationMacroTop5": float(np.mean(per_class5)),
                   "validationCount": int(y.numel()), "evaluatedClassCount": len(per_class1)}
            history.append(row)
            print(json.dumps(row), flush=True)
            if row["validationMacroTop1"] > best_macro:
                best_macro = row["validationMacroTop1"]
                best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
                torch.save({"epoch": epoch, "model": best_state, "classMap": class_map,
                            "validation": row, "startingCheckpointSHA256": manifest_out["startingCheckpointSHA256"],
                            "augmentationMode": mode, "seed": int(split["seed"]),
                            "finetuningSeed": args.seed}, args.output / f"{mode}-best.pt")
        all_results[mode] = history
        (args.output / f"{mode}-history.json").write_text(json.dumps(history, ensure_ascii=False, indent=2) + "\n")
    baseline = json.loads(Path("runs/firebird-typeset-vit-fold7-corrected-20261104/epoch-history.json").read_text())
    baseline_best = max(baseline, key=lambda x: x["validationTop1MacroOverEvaluableClasses"])
    report = {"schema": "firebird-vit-multiscale-finetune-results-v1", "experiment": manifest_out,
              "baselineBestValidation": baseline_best, "candidates": all_results,
              "conclusionRule": "no candidate is adopted unless it improves held-out-font macro Top1 without reducing macro Top5; handwriting confusion is assessed separately before subset publication"}
    (args.output / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
