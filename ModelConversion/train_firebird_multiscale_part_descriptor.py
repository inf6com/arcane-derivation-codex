#!/usr/bin/env python3
"""Train a font-only multiscale contour/skeleton descriptor on Apple MPS."""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
from torch.utils.data import DataLoader, TensorDataset, WeightedRandomSampler

from train_firebird_part_similarity import affine_views, select_points


SCALES = (64, 32, 16)


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


class MultiScaleShapeViT(nn.Module):
    def __init__(self, width: int = 96, descriptor_dim: int = 24) -> None:
        super().__init__()
        self.patch = nn.Conv2d(2, width, kernel_size=8, stride=8, bias=True)
        self.position = nn.Parameter(torch.zeros(1, 64, width))
        layer = nn.TransformerEncoderLayer(
            d_model=width, nhead=4, dim_feedforward=width * 4, dropout=0.1,
            activation="gelu", batch_first=True, norm_first=True,
        )
        self.encoder = nn.TransformerEncoder(layer, num_layers=3, enable_nested_tensor=False)
        self.norm = nn.LayerNorm(width)
        self.project = nn.Linear(width, descriptor_dim)
        nn.init.trunc_normal_(self.position, std=0.02)

    def forward_levels(self, shape: torch.Tensor) -> dict[int, torch.Tensor]:
        result = {}
        for size in SCALES:
            view = shape if size == shape.shape[-1] else F.interpolate(shape, size=(size, size), mode="area")
            patches = self.patch(view).flatten(2).transpose(1, 2)
            token_side = int(patches.shape[1] ** .5)
            pos = self.position.transpose(1, 2).reshape(1, -1, 8, 8)
            pos = F.interpolate(pos, size=(token_side, token_side), mode="bicubic", align_corners=False)
            pos = pos.flatten(2).transpose(1, 2)
            tokens = self.norm(self.encoder(patches + pos))
            patches = self.project(tokens).transpose(1, 2).reshape(shape.shape[0], -1, token_side, token_side)
            result[size] = F.normalize(patches, p=2, dim=1, eps=1e-6)
        return result


def balanced_threshold(positive: list[float], negative: list[float]) -> dict:
    pos = np.asarray(positive, dtype=np.float32)
    neg = np.asarray(negative, dtype=np.float32)
    if not len(pos) or not len(neg):
        raise ValueError("threshold calibration has no positive or negative correspondences")
    candidates = np.unique(np.quantile(np.concatenate((pos, neg)), np.linspace(0, 1, 501)))
    scored = [(float((np.mean(pos >= t) + np.mean(neg < t)) / 2), float(t),
               float(np.mean(pos >= t)), float(np.mean(neg >= t))) for t in candidates]
    score, threshold, recall, false_match = max(scored, key=lambda row: (row[0], -row[3], row[1]))
    return {"threshold": threshold, "balancedAccuracy": score, "positiveRecall": recall,
            "differentSiteFalseMatchRate": false_match, "positiveCount": len(pos),
            "negativeCount": len(neg), "positiveCosineP05": float(np.quantile(pos, .05)),
            "negativeCosineP99": float(np.quantile(neg, .99))}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json"))
    parser.add_argument("--images", type=Path, default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.u8"))
    parser.add_argument("--shape-corpus", type=Path, default=Path("runs/agent-control/cycle624-firebird-part-similarity-v1/contour-skeleton-corpus.u8"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=96)
    parser.add_argument("--seed", type=int, default=20261105)
    return parser.parse_args()


def multiscale_loss(level_a: dict[int, torch.Tensor], level_b: dict[int, torch.Tensor],
                    grids: torch.Tensor, skeleton: torch.Tensor) -> tuple[torch.Tensor, dict[int, torch.Tensor]]:
    losses = {}
    for size in SCALES:
        a = level_a[size]
        b = level_b[size]
        token_side = size // 8
        grid_a = F.interpolate(grids[0].permute(0, 3, 1, 2), size=(token_side, token_side), mode="bilinear", align_corners=False).permute(0, 2, 3, 1)
        grid_b = F.interpolate(grids[1].permute(0, 3, 1, 2), size=(token_side, token_side), mode="bilinear", align_corners=False).permute(0, 2, 3, 1)
        a = F.normalize(F.grid_sample(a, grid_a, mode="bilinear", padding_mode="zeros", align_corners=False), dim=1)
        b = F.normalize(F.grid_sample(b, grid_b, mode="bilinear", padding_mode="zeros", align_corners=False), dim=1)
        mask = F.adaptive_max_pool2d(skeleton, (token_side, token_side))
        point_ids, valid = select_points(mask, min(32, token_side * token_side))
        n, dim, h, w = a.shape
        af = a.permute(0, 2, 3, 1).reshape(n, h * w, dim)
        bf = b.permute(0, 2, 3, 1).reshape(n, h * w, dim)
        aa = torch.gather(af, 1, point_ids[..., None].expand(-1, -1, dim))
        bb = torch.gather(bf, 1, point_ids[..., None].expand(-1, -1, dim))
        logits = torch.bmm(aa, bb.transpose(1, 2)) / 0.08
        logits = logits.masked_fill(~valid[:, None, :], -1e4)
        targets = torch.arange(point_ids.shape[1], device=point_ids.device).expand(n, -1)
        raw = F.cross_entropy(logits.reshape(-1, point_ids.shape[1]), targets.reshape(-1), reduction="none")
        weights = valid.reshape(-1).to(raw.dtype)
        losses[size] = (raw * weights).sum() / weights.sum().clamp_min(1)
    return sum(losses.values()) / len(SCALES), losses


def fixed_validation_views(x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    batch = x.shape[0]
    theta_a = torch.zeros((batch, 2, 3), device=x.device, dtype=x.dtype)
    theta_b = torch.zeros_like(theta_a)
    theta_a[:, 0, 0] = .96; theta_a[:, 1, 1] = .96
    theta_b[:, 0, 0] = 1.04; theta_b[:, 1, 1] = 1.04
    theta_a[:, 0, 2] = -.025; theta_a[:, 1, 2] = .025
    theta_b[:, 0, 2] = .025; theta_b[:, 1, 2] = -.025
    grid_a = F.affine_grid(theta_a, x.shape, align_corners=False)
    grid_b = F.affine_grid(theta_b, x.shape, align_corners=False)
    inv_a = torch.zeros_like(theta_a); inv_b = torch.zeros_like(theta_b)
    for source, target in ((theta_a, inv_a), (theta_b, inv_b)):
        target[:, 0, 0] = source[:, 0, 0].reciprocal()
        target[:, 1, 1] = source[:, 1, 1].reciprocal()
        target[:, 0, 2] = -source[:, 0, 2] / source[:, 0, 0]
        target[:, 1, 2] = -source[:, 1, 2] / source[:, 1, 1]
    align_a = F.affine_grid(inv_a, x.shape, align_corners=False)
    align_b = F.affine_grid(inv_b, x.shape, align_corners=False)
    va = F.grid_sample(x, grid_a, mode="bilinear", padding_mode="zeros", align_corners=False)
    vb = F.grid_sample(x, grid_b, mode="bilinear", padding_mode="zeros", align_corners=False)
    return va, vb, torch.stack((align_a, align_b), dim=0)


def evaluate(model: MultiScaleShapeViT, corpus: np.memmap, sampled: list[int], device: torch.device) -> dict:
    model.eval()
    positives = {size: [] for size in SCALES}
    negatives = {size: [] for size in SCALES}
    recalls = {size: [0, 0] for size in SCALES}
    with torch.inference_mode():
        for start in range(0, len(sampled), 32):
            ids = sampled[start:start + 32]
            x = torch.from_numpy(np.array(corpus[ids], copy=True)).to(device=device, dtype=torch.float32).div_(255.)
            va, vb, grids = fixed_validation_views(x)
            la, lb = model.forward_levels(va), model.forward_levels(vb)
            for size in SCALES:
                token_side = size // 8
                ga = F.interpolate(grids[0].permute(0, 3, 1, 2), size=(token_side, token_side), mode="bilinear", align_corners=False).permute(0, 2, 3, 1)
                gb = F.interpolate(grids[1].permute(0, 3, 1, 2), size=(token_side, token_side), mode="bilinear", align_corners=False).permute(0, 2, 3, 1)
                a = F.normalize(F.grid_sample(la[size], ga, align_corners=False), dim=1)
                b = F.normalize(F.grid_sample(lb[size], gb, align_corners=False), dim=1)
                ids_at_scale, valid = select_points(F.adaptive_max_pool2d(x[:, 1:2], (token_side, token_side)), min(32, token_side * token_side))
                n, dim, h, w = a.shape
                af = a.permute(0, 2, 3, 1).reshape(n, h * w, dim)
                bf = b.permute(0, 2, 3, 1).reshape(n, h * w, dim)
                aa = F.normalize(torch.gather(af, 1, ids_at_scale[..., None].expand(-1, -1, dim)), dim=-1)
                bb = F.normalize(torch.gather(bf, 1, ids_at_scale[..., None].expand(-1, -1, dim)), dim=-1)
                sims = torch.bmm(aa, bb.transpose(1, 2))
                positives[size].extend(sims.diagonal(dim1=1, dim2=2)[valid].cpu().tolist())
                off = ~torch.eye(sims.shape[1], device=device, dtype=torch.bool).unsqueeze(0)
                off = off & valid[:, :, None] & valid[:, None, :]
                negatives[size].extend(sims[off].cpu().tolist())
                predicted = sims.masked_fill(~valid[:, None, :], -2).argmax(-1)
                correct = predicted.eq(torch.arange(sims.shape[1], device=device)[None, :]) & valid
                recalls[size][0] += int(correct.sum())
                recalls[size][1] += int(valid.sum())
    return {str(size): {**balanced_threshold(positives[size], negatives[size]),
                        "correspondenceRecallAt1": recalls[size][0] / max(recalls[size][1], 1),
                        "sampledHeldoutGlyphImages": len(sampled)} for size in SCALES}


def main() -> None:
    args = parse_args()
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is unavailable; training is refused rather than silently moved to CPU.")
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite run: {args.output}")
    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    rows = manifest["rows"]
    if manifest.get("schema") != "firebird-mac-font-glyph-raster-v1" or len(rows) != 68689:
        raise ValueError("unexpected authoritative Mac font corpus")
    expected_bytes = len(rows) * 2 * 64 * 64
    if args.shape_corpus.stat().st_size != expected_bytes:
        raise ValueError("contour/skeleton corpus size does not match the manifest")
    if args.images.stat().st_size != len(rows) * 64 * 64:
        raise ValueError("raster corpus size does not match the manifest")

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    device = torch.device("mps")
    fonts = sorted({r["fontFileSHA256"] for r in rows})
    ranked = sorted(fonts, key=lambda h: hashlib.sha256(f"{args.seed}:{h}".encode()).digest())
    heldout = set(ranked[:max(1, round(len(ranked) * .20))])
    fit_ids = [i for i, row in enumerate(rows) if row["fontFileSHA256"] not in heldout]
    valid_ids = [i for i, row in enumerate(rows) if row["fontFileSHA256"] in heldout]
    if {rows[i]["fontFileSHA256"] for i in fit_ids} & heldout:
        raise RuntimeError("font-file train/validation leakage")
    by_font = defaultdict(list)
    for index in valid_ids:
        by_font[rows[index]["fontFileSHA256"]].append(index)
    sampled = []
    per_font = max(1, 2048 // max(len(by_font), 1))
    for font_hash in sorted(by_font):
        font_rows = sorted(by_font[font_hash], key=lambda index: hashlib.sha256(
            f"{args.seed}:validation:{index}".encode()).digest())
        sampled.extend(font_rows[:per_font])
    sampled = sampled[:2048]
    args.output.mkdir(parents=True)
    corpus = np.memmap(args.shape_corpus, mode="r", dtype=np.uint8, shape=(len(rows), 2, 64, 64))
    fit = torch.from_numpy(np.array(corpus[fit_ids], copy=True))
    classes = torch.tensor([int(rows[i]["vocabularyIndex"]) for i in fit_ids])
    counts = torch.bincount(classes)
    sampler = WeightedRandomSampler(counts[classes].clamp_min(1).float().reciprocal(), len(fit_ids), replacement=True,
                                    generator=torch.Generator().manual_seed(args.seed))
    loader = DataLoader(TensorDataset(fit), batch_size=args.batch_size, sampler=sampler, num_workers=0, drop_last=True)
    model = MultiScaleShapeViT().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=2e-4, weight_decay=1e-4)
    history = []
    best_validation_score = -1.0
    best_state = None
    best_validation = None
    best_epoch = None
    for epoch in range(1, args.epochs + 1):
        model.train()
        total = {size: 0.0 for size in SCALES}
        batches = 0
        for (batch,) in loader:
            x = batch.to(device=device, dtype=torch.float32).div_(255.)
            va, vb, grids = affine_views(x)
            # Independent raster resolution loss: retain coarse glyph parts as well as fine contours.
            resolutions = torch.tensor((8, 12, 16, 24, 32, 48, 64), device=device)
            chosen_a = resolutions[torch.randint(len(resolutions), (len(x),), device=device)]
            chosen_b = resolutions[torch.randint(len(resolutions), (len(x),), device=device)]
            for size in torch.unique(torch.cat((chosen_a, chosen_b))).tolist():
                if size == 64:
                    continue
                mask_a, mask_b = chosen_a == size, chosen_b == size
                if mask_a.any():
                    low = F.interpolate(va[mask_a], size=(size, size), mode="bilinear",
                                        align_corners=False, antialias=True)
                    va[mask_a] = F.interpolate(low, size=(64, 64), mode="bilinear", align_corners=False)
                if mask_b.any():
                    low = F.interpolate(vb[mask_b], size=(size, size), mode="bilinear",
                                        align_corners=False, antialias=True)
                    vb[mask_b] = F.interpolate(low, size=(64, 64), mode="bilinear", align_corners=False)
            loss, components = multiscale_loss(model.forward_levels(va), model.forward_levels(vb), grids, x[:, 1:2])
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            for size, part in components.items():
                total[size] += float(part.detach())
            batches += 1
            if batches % 100 == 0:
                print(json.dumps({"stage": "training", "epoch": epoch, "batch": batches,
                                  "batchCount": len(loader), "scaleLoss": {s: total[s] / batches for s in SCALES}}), flush=True)
        record = {"epoch": epoch, "batches": batches, "scaleLoss": {s: total[s] / max(batches, 1) for s in SCALES},
                  "fitFontFiles": len(fonts) - len(heldout), "heldoutFontFiles": len(heldout),
                  "fitGlyphImages": len(fit_ids), "validationGlyphImages": len(valid_ids),
                  "validation": evaluate(model, corpus, sampled, device)}
        validation_score = float(np.mean([record["validation"][str(size)]["correspondenceRecallAt1"] for size in SCALES]))
        record["validationSelectionScore"] = validation_score
        history.append(record)
        print(json.dumps(record), flush=True)
        payload = {"state_dict": {k: v.detach().cpu() for k, v in model.state_dict().items()},
                   "architecture": {"type": "MultiScaleShapeViT", "inputChannels": ["contour", "skeleton"],
                                    "patchSize": 8, "width": 96, "transformerEncoderLayers": 3,
                                    "attentionHeads": 4, "descriptorDimension": 24, "scales": list(SCALES)},
                   "epoch": epoch, "validationSelectionScore": validation_score, "seed": args.seed}
        torch.save(payload, args.output / f"epoch-{epoch:03d}.pt")
        if validation_score > best_validation_score:
            best_validation_score = validation_score
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
            best_validation = record["validation"]
            best_epoch = epoch
            torch.save(payload, args.output / "firebird-multiscale-part-vit.pt")
    if best_state is None or best_validation is None or best_epoch is None:
        raise RuntimeError("training produced no validation-selected checkpoint")
    report = {"schema": "firebird-typeset-multiscale-part-vit-v1",
              "corpusManifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
              "corpusRasterSHA256": digest(args.images),
              "contourSkeletonCorpusSHA256": digest(args.shape_corpus),
              "fontSplitSHA256": hashlib.sha256(json.dumps(sorted(heldout)).encode()).hexdigest(),
              "trainingFontFiles": sorted({rows[i]["fontFileSHA256"] for i in fit_ids}),
              "heldoutFontFiles": sorted(heldout), "epochs": history,
              "checkpoint": str(args.output / "firebird-multiscale-part-vit.pt"), "selectedEpoch": best_epoch,
              "checkpointSelection": f"highest mean heldout-font correspondence Recall@1 across {list(SCALES)}; fixed validation transforms",
              "heldoutMultiscaleValidation": best_validation, "trainingDevice": "mps", "outerTestOpened": False,
              "scope": "Mac typeset glyph contour/skeleton only; handwriting and classifier confusions are excluded.",
              "limitations": ["Heldout correspondence metrics validate transformed local matches, not semantic symbol-pair similarity.",
                              "Pair subset quality requires human-reviewed part-overlap labels; none are available in the corpus."]}
    (args.output / "training-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"stage": "complete", "checkpoint": str(args.output / 'firebird-multiscale-part-vit.pt'),
                      "selectedEpoch": best_epoch, "validation": best_validation}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
