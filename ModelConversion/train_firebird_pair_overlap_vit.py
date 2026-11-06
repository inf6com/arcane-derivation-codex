#!/usr/bin/env python3
"""Train a symmetric ViT pair regressor on explicit raster shared-shape targets."""
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
from torch.utils.data import DataLoader, Dataset


SCALES = (64, 32, 16)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def canonicalize(image: np.ndarray) -> np.ndarray:
    occupied = np.any(image > 0, axis=0)
    points = np.argwhere(occupied)
    if not len(points):
        raise ValueError("empty contour/skeleton glyph cannot be canonicalized")
    y0, x0 = points.min(axis=0)
    y1, x1 = points.max(axis=0) + 1
    cropped = image[:, y0:y1, x0:x1]
    h, w = cropped.shape[-2:]
    out_h = max(1, round(h * 56 / max(h, w)))
    out_w = max(1, round(w * 56 / max(h, w)))
    ys = np.minimum(((np.arange(out_h) + .5) * h / out_h).astype(np.int64), h - 1)
    xs = np.minimum(((np.arange(out_w) + .5) * w / out_w).astype(np.int64), w - 1)
    resized = cropped[:, ys[:, None], xs[None, :]]
    result = np.zeros((2, 64, 64), dtype=np.uint8)
    top, left = (64 - out_h) // 2, (64 - out_w) // 2
    result[:, top:top + out_h, left:left + out_w] = (resized > 0).astype(np.uint8)
    return result


def target_scores(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Minimum directional shared-pixel coverage; symmetric in both glyphs."""
    scores = []
    for size in SCALES:
        step = 64 // size
        aa = a.reshape(2, size, step, size, step).max(axis=(2, 4)) if step > 1 else a
        bb = b.reshape(2, size, step, size, step).max(axis=(2, 4)) if step > 1 else b
        channel_scores = []
        for channel in range(2):
            left = aa[channel].astype(np.uint16)
            right = bb[channel].astype(np.uint16)
            denominator = max(int(left.sum()), int(right.sum()))
            channel_scores.append(1.0 if denominator == 0 else
                                  int((left * right).sum()) / denominator)
        scores.append(float(np.mean(channel_scores)))
    return np.asarray(scores, dtype=np.float32)


def pairwise_target_scores(images: np.ndarray) -> np.ndarray:
    """Vectorized target for every ordered pair in one font; result is symmetric."""
    scale_scores = []
    for size in SCALES:
        step = 64 // size
        level = images.reshape(len(images), 2, size, step, size, step).max(axis=(3, 5)) if step > 1 else images
        channel_scores = []
        for channel in range(2):
            masks = level[:, channel].reshape(len(level), -1).astype(np.float32)
            intersections = masks @ masks.T
            counts = masks.sum(axis=1)
            denominators = np.maximum(counts[:, None], counts[None, :])
            channel_scores.append(np.divide(intersections, denominators,
                                            out=np.ones_like(intersections), where=denominators > 0))
        scale_scores.append((channel_scores[0] + channel_scores[1]) * .5)
    return np.stack(scale_scores, axis=-1)


class PairOverlapViT(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        width = 96
        self.patch = nn.Conv2d(2, width, kernel_size=8, stride=8)
        self.position = nn.Parameter(torch.zeros(1, 64, width))
        layer = nn.TransformerEncoderLayer(d_model=width, nhead=4, dim_feedforward=width * 4,
                                           dropout=.1, activation="gelu", batch_first=True,
                                           norm_first=True)
        self.encoder = nn.TransformerEncoder(layer, num_layers=3, enable_nested_tensor=False)
        self.norm = nn.LayerNorm(width)
        self.head = nn.Sequential(nn.LayerNorm(width * 2), nn.Linear(width * 2, 96), nn.GELU(),
                                  nn.Dropout(.1), nn.Linear(96, len(SCALES)))
        nn.init.trunc_normal_(self.position, std=.02)

    def encode(self, image: torch.Tensor) -> torch.Tensor:
        tokens = self.patch(image).flatten(2).transpose(1, 2)
        return self.norm(self.encoder(tokens + self.position).mean(dim=1))

    def score_embeddings(self, a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
        symmetric = torch.cat(((a - b).abs(), a * b), dim=-1)
        return torch.sigmoid(self.head(symmetric))

    def forward(self, a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
        both = self.encode(torch.cat((a, b), dim=0))
        left, right = both.chunk(2, dim=0)
        return self.score_embeddings(left, right)


class PairDataset(Dataset):
    def __init__(self, corpus: np.memmap, records: np.ndarray, *, augment: bool = False,
                 seed: int = 0) -> None:
        self.corpus = corpus
        self.records = records
        self.augment = augment
        self.seed = seed
        self.epoch = 0

    def set_epoch(self, epoch: int) -> None:
        self.epoch = epoch

    @staticmethod
    def augment_glyph(image: np.ndarray, rng: np.random.Generator) -> np.ndarray:
        """Apply label-preserving raster/pose variation; reflections are deliberately excluded."""
        resolution = int(rng.choice((16, 32, 64)))
        step = 64 // resolution
        small = image.reshape(2, resolution, step, resolution, step).max(axis=(2, 4))

        scale = rng.uniform(0.90, 1.10)
        shift_x = rng.uniform(-1.5, 1.5) * resolution / 64.0
        shift_y = rng.uniform(-1.5, 1.5) * resolution / 64.0
        axis = np.arange(resolution, dtype=np.float32) - (resolution - 1) / 2.0
        out_x, out_y = np.meshgrid(axis, axis)
        src_x = (out_x - shift_x) / scale + (resolution - 1) / 2.0
        src_y = (out_y - shift_y) / scale + (resolution - 1) / 2.0
        ix = np.rint(src_x).astype(np.int64)
        iy = np.rint(src_y).astype(np.int64)
        valid = (ix >= 0) & (ix < resolution) & (iy >= 0) & (iy < resolution)
        transformed = np.zeros_like(small)
        transformed[:, valid] = small[:, iy[valid], ix[valid]]
        expanded = np.repeat(np.repeat(transformed, step, axis=1), step, axis=2)
        return expanded.astype(np.uint8, copy=False)

    def __len__(self) -> int:
        return len(self.records)

    def __getitem__(self, index: int):
        row_a, row_b, target0, target1, target2 = self.records[index]
        a = np.array(self.corpus[int(row_a)], copy=True)
        b = np.array(self.corpus[int(row_b)], copy=True)
        target = np.asarray((target0, target1, target2), dtype=np.float32)
        if self.augment:
            rng = np.random.default_rng(self.seed + self.epoch * 1_000_003 + index * 2_017)
            a = self.augment_glyph(a, rng)
            b = self.augment_glyph(b, rng)
            target = target_scores(a, b)
        a = a.astype(np.float32)
        b = b.astype(np.float32)
        return torch.from_numpy(a), torch.from_numpy(b), torch.from_numpy(target)


def font_pair_records(rows: list[dict], normalized: np.memmap, font_hashes: list[str], seed: int,
                      limit: int, require_positive: bool) -> tuple[np.ndarray, dict]:
    by_font_label: dict[str, dict[int, int]] = defaultdict(dict)
    selected_fonts = set(font_hashes)
    for row_id, row in enumerate(rows):
        if row["fontFileSHA256"] in selected_fonts:
            by_font_label[row["fontFileSHA256"]].setdefault(int(row["vocabularyIndex"]), row_id)
    all_records = []
    positives = negatives = 0
    for font_hash in font_hashes:
        entries = sorted(by_font_label.get(font_hash, {}).items())
        if len(entries) < 2:
            continue
        row_ids = np.asarray([row_id for _, row_id in entries], dtype=np.int64)
        images = np.asarray(normalized[row_ids], dtype=np.uint8)
        scores = pairwise_target_scores(images)
        font_records = []
        for i, (_, row_a) in enumerate(entries):
            for j in range(i + 1, len(entries)):
                row_b = entries[j][1]
                font_records.append((row_a, row_b, *scores[i, j].tolist()))
        positive_rows = [record for record in font_records if float(np.mean(record[2:])) >= .5]
        negative_rows = [record for record in font_records if float(np.mean(record[2:])) < .5]
        positives += len(positive_rows)
        negatives += len(negative_rows)
        all_records.extend(positive_rows)
        max_negative = max(1, len(positive_rows) * 3)
        if len(negative_rows) > max_negative:
            ranked = sorted(negative_rows, key=lambda r: hashlib.sha256(
                f"{seed}:{font_hash}:{r[0]}:{r[1]}".encode()).digest())
            negative_rows = ranked[:max_negative]
        all_records.extend(negative_rows)
    if not all_records:
        raise ValueError("pair-level raster teacher produced no trainable cross-symbol pairs")
    if require_positive and positives == 0:
        raise ValueError("no cross-symbol pair reaches the explicit 50% raster-overlap target")
    ranked = sorted(all_records, key=lambda r: hashlib.sha256(
        f"{seed}:{r[0]}:{r[1]}:{r[2]}:{r[3]}".encode()).digest())
    records = np.asarray(ranked[:limit], dtype=np.float32)
    records[:, :2] = records[:, :2].astype(np.int64)
    return records, {"candidatePairRows": sum(len(by_font_label[f]) * (len(by_font_label[f]) - 1) // 2
                                                  for f in font_hashes if f in by_font_label),
                     "teacherPositiveRowsBeforeSampling": positives,
                     "teacherNegativeRowsBeforeSampling": negatives,
                     "selectedPairRows": len(records)}


def evaluate(model: PairOverlapViT, corpus: np.memmap, records: np.ndarray, device: torch.device) -> dict:
    model.eval()
    predictions, targets = [], []
    loader = DataLoader(PairDataset(corpus, records), batch_size=128, shuffle=False, num_workers=0)
    with torch.inference_mode():
        for a, b, target in loader:
            pred = model(a.to(device), b.to(device)).cpu().numpy()
            predictions.append(pred)
            targets.append(target.numpy())
    p, y = np.concatenate(predictions), np.concatenate(targets)
    result = {}
    for i, size in enumerate(SCALES):
        truth, pred = y[:, i], p[:, i]
        tp = int(((truth >= .5) & (pred >= .5)).sum())
        fp = int(((truth < .5) & (pred >= .5)).sum())
        fn = int(((truth >= .5) & (pred < .5)).sum())
        tn = int(((truth < .5) & (pred < .5)).sum())
        result[str(size)] = {"mae": float(np.mean(np.abs(pred - truth))),
                             "balancedAccuracyAtHalf": float(.5 * (tp / max(tp + fn, 1) + tn / max(tn + fp, 1))),
                             "precisionAtHalf": float(tp / max(tp + fp, 1)),
                             "recallAtHalf": float(tp / max(tp + fn, 1)),
                             "falsePositiveCount": fp, "falseNegativeCount": fn,
                             "evaluatedPairs": len(y)}
    result["macroMAE"] = float(np.mean([result[str(size)]["mae"] for size in SCALES]))
    result["macroBalancedAccuracyAtHalf"] = float(np.mean(
        [result[str(size)]["balancedAccuracyAtHalf"] for size in SCALES]))
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json"))
    parser.add_argument("--images", type=Path, default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.u8"))
    parser.add_argument("--shape-corpus", type=Path, default=Path("runs/agent-control/cycle624-firebird-part-similarity-v1/contour-skeleton-corpus.u8"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=4)
    parser.add_argument("--max-pairs", type=int, default=30000)
    parser.add_argument("--pair-target-font-count", type=int, default=96)
    parser.add_argument("--seed", type=int, default=20261106)
    args = parser.parse_args()
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is required; CPU fallback is prohibited.")
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite run: {args.output}")
    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    rows = manifest["rows"]
    if manifest.get("schema") != "firebird-mac-font-glyph-raster-v1" or len(rows) != 68689:
        raise ValueError("unexpected authoritative 229-label Mac font corpus")
    if args.images.stat().st_size != len(rows) * 64 * 64:
        raise ValueError("raster corpus size does not match manifest")
    if args.shape_corpus.stat().st_size != len(rows) * 2 * 64 * 64:
        raise ValueError("contour/skeleton corpus size does not match manifest")

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    fonts = sorted({r["fontFileSHA256"] for r in rows})
    ordered = sorted(fonts, key=lambda f: hashlib.sha256(f"{args.seed}:{f}".encode()).digest())
    heldout = ordered[:max(1, round(len(ordered) * .20))]
    fit_fonts = sorted(set(fonts) - set(heldout))
    heldout_order = sorted(heldout, key=lambda f: hashlib.sha256(f"eval:{args.seed}:{f}".encode()).digest())
    valid_fonts, generation_fonts = heldout_order[:10], heldout_order[10:]
    args.output.mkdir(parents=True)

    source = np.memmap(args.shape_corpus, mode="r", dtype=np.uint8, shape=(len(rows), 2, 64, 64))
    normalized_path = args.output / "canonical-contour-skeleton.u8"
    normalized = np.memmap(normalized_path, mode="w+", dtype=np.uint8, shape=(len(rows), 2, 64, 64))
    for start in range(0, len(rows), 512):
        for row_id in range(start, min(start + 512, len(rows))):
            normalized[row_id] = canonicalize(source[row_id])
    normalized.flush()
    corpus_digest = sha256(normalized_path)

    if not 1 <= args.pair_target_font_count <= len(fit_fonts):
        raise ValueError("pair-target-font-count must be within the disjoint fit-font count")
    ranked_fit_target_fonts = sorted(fit_fonts, key=lambda f: hashlib.sha256(
        f"pair-target:{args.seed}:{f}".encode()).digest())
    fit_font_set = set(fit_fonts)
    font_counts_by_label: dict[int, set[str]] = defaultdict(set)
    for row in rows:
        if row["fontFileSHA256"] in fit_font_set:
            font_counts_by_label[int(row["vocabularyIndex"])].add(row["fontFileSHA256"])
    rare_label_support_fonts = {
        next(iter(font_hashes))
        for font_hashes in font_counts_by_label.values()
        if len(font_hashes) == 1
    }
    required_target_fonts = sorted(rare_label_support_fonts)
    if len(required_target_fonts) > args.pair_target_font_count:
        raise ValueError("pair-target font budget cannot cover every single-font glyph class")
    selected_target_fonts = set(required_target_fonts)
    for font_hash in ranked_fit_target_fonts:
        if len(selected_target_fonts) == args.pair_target_font_count:
            break
        selected_target_fonts.add(font_hash)
    fit_target_fonts = sorted(selected_target_fonts)
    train_records, train_counts = font_pair_records(rows, normalized, fit_target_fonts, args.seed,
                                                     args.max_pairs, require_positive=True)
    valid_records, valid_counts = font_pair_records(rows, normalized, valid_fonts, args.seed + 1,
                                                     min(8000, args.max_pairs), require_positive=False)
    # Use all held-out font files only for final subset generation, never for fitting or checkpoint selection.
    if set(fit_fonts) & (set(valid_fonts) | set(generation_fonts)) or set(valid_fonts) & set(generation_fonts):
        raise RuntimeError("font-file train/validation/generation leakage")

    corpus_ro = np.memmap(normalized_path, mode="r", dtype=np.uint8, shape=(len(rows), 2, 64, 64))
    train_dataset = PairDataset(corpus_ro, train_records, augment=True, seed=args.seed)
    train_loader = DataLoader(train_dataset, batch_size=128, shuffle=True,
                              num_workers=0, drop_last=False)
    device = torch.device("mps")
    model = PairOverlapViT().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=2e-4, weight_decay=1e-4)
    history, best_score, best_epoch = [], float("inf"), None
    for epoch in range(1, args.epochs + 1):
        train_dataset.set_epoch(epoch)
        model.train()
        loss_sum, seen = 0.0, 0
        for a, b, target in train_loader:
            a = a.to(device=device, dtype=torch.float32)
            b = b.to(device=device, dtype=torch.float32)
            target = target.to(device=device, dtype=torch.float32)
            pred = model(a, b)
            loss = F.smooth_l1_loss(pred, target)
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            loss_sum += float(loss.detach()) * len(target)
            seen += len(target)
        valid = evaluate(model, corpus_ro, valid_records, device)
        row = {"epoch": epoch, "fitLoss": loss_sum / max(seen, 1), "fitPairCount": seen,
               "validation": valid}
        history.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
        payload = {"state_dict": {k: v.detach().cpu() for k, v in model.state_dict().items()},
                   "architecture": "symmetric-shape-pair-vit-v3", "epoch": epoch,
                   "validationMacroMAE": valid["macroMAE"], "seed": args.seed,
                   "canonicalCorpusSHA256": corpus_digest}
        torch.save(payload, args.output / f"epoch-{epoch:03d}.pt")
        if valid["macroMAE"] < best_score:
            best_score, best_epoch = valid["macroMAE"], epoch
            torch.save(payload, args.output / "firebird-pair-overlap-vit.pt")
    if best_epoch is None:
        raise RuntimeError("no validation-selected pair model was produced")
    report = {"schema": "firebird-symmetric-shape-pair-vit-v3",
              "task": "predict symmetric minimum shared contour/skeleton coverage across cross-symbol pairs",
              "targetDefinition": "For each contour/skeleton channel and 64/32/16 raster scale, intersection pixels divided by the larger glyph-mask pixel count (equivalent to the smaller of the two directional coverages); arithmetic mean over both channels.",
              "targetIsHumanAnnotation": False,
              "fitFontFiles": fit_fonts, "pairTargetFontFiles": fit_target_fonts,
              "pairTargetFontCount": len(fit_target_fonts),
              "rareLabelSupportFontFilesForcedIntoPairTargets": required_target_fonts,
              "trainingDataAugmentation": {
                  "enabled": True,
                  "variantsPerPairPerEpoch": 1,
                  "independentPerGlyph": True,
                  "effectiveRasterResolutions": [16, 32, 64],
                  "scaleRange": [0.90, 1.10],
                  "rotationDegrees": [],
                  "translationPixels": [-1.5, 1.5],
                  "reflections": False,
                  "target": "recomputed from each transformed pair; synthetic views do not count as independent fonts"},
              "validationFontFiles": valid_fonts, "generationFontFiles": generation_fonts,
              "fitPairCounts": train_counts, "validationPairCounts": valid_counts,
              "corpusManifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
              "contourSkeletonCorpusSHA256": sha256(args.shape_corpus),
              "canonicalCorpusSHA256": corpus_digest,
              "history": history, "selectedEpoch": best_epoch,
              "checkpoint": str(args.output / "firebird-pair-overlap-vit.pt"),
              "trainingDevice": "mps", "outerTestOpened": False,
              "limitations": ["Pair labels are the explicit raster-overlap target, not human semantic part annotations.",
                              "A high held-out score measures agreement with this target definition, not human judgment.",
                              "The structural fraction symbol has no standalone glyph and remains a singleton."]}
    (args.output / "training-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"stage": "complete", "selectedEpoch": best_epoch,
                      "validation": history[best_epoch - 1]["validation"],
                      "checkpoint": report["checkpoint"]}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
