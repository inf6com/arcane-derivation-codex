#!/usr/bin/env python3
"""Train ViT local-window descriptors and generate font-shape neighborhoods."""
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
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler

class ShapeBank(Dataset):
    def __init__(self, bank: np.memmap, rows: list[dict], indices: list[int],
                 synthetic_sources: list[tuple[np.memmap, list[dict]]] | None = None):
        self.items = [(bank, index, int(rows[index]["vocabularyIndex"])) for index in indices]
        for synthetic_bank, synthetic_rows in synthetic_sources or []:
            self.items.extend((synthetic_bank, int(row["imageIndex"]),
                               int(row["vocabularyIndex"])) for row in synthetic_rows)
        self.labels = [label for _, _, label in self.items]

    def __len__(self):
        return len(self.items)

    def __getitem__(self, item: int):
        bank, index, label = self.items[item]
        return torch.from_numpy(np.array(bank[index], copy=True)), label


class WindowSetViT(nn.Module):
    """ViT over an unordered set of local dot-pattern windows."""
    def __init__(self, window_size: int, width: int = 96, descriptor_dim: int = 48):
        super().__init__()
        if 64 % window_size:
            raise ValueError("window size must divide the 64-dot source canvas")
        self.window_size = window_size
        self.patch = nn.Conv2d(2, width, kernel_size=window_size, stride=window_size, bias=True)
        layer = nn.TransformerEncoderLayer(d_model=width, nhead=4, dim_feedforward=width * 3,
                                           dropout=0.1, activation="gelu", batch_first=True,
                                           norm_first=True)
        self.transformer = nn.TransformerEncoder(layer, num_layers=3, enable_nested_tensor=False)
        self.norm = nn.LayerNorm(width)
        self.project = nn.Linear(width, descriptor_dim)

    def forward(self, dots: torch.Tensor) -> torch.Tensor:
        # No canvas-position embedding: a local window descriptor is independent
        # of where that window occurs in the glyph. Dot arrangement inside each
        # window remains encoded by the patch projection.
        tokens = self.patch(dots).flatten(2).transpose(1, 2)
        active = F.max_pool2d(dots[:, 1:2], self.window_size,
                              stride=self.window_size).flatten(1) > .5
        tokens = self.transformer(tokens, src_key_padding_mask=~active)
        return self.project(self.norm(tokens))


def local_vicreg_loss(a: torch.Tensor, b: torch.Tensor, valid: torch.Tensor):
    """Make transformed corresponding windows agree without repelling other windows."""
    left = a[valid]
    right = b[valid]
    if left.shape[0] < 2:
        raise ValueError("VICReg requires at least two active window correspondences")
    invariance = F.mse_loss(left, right)
    joined = torch.cat((left, right), dim=0)
    centered = joined - joined.mean(dim=0, keepdim=True)
    variance = torch.sqrt(centered.var(dim=0, unbiased=False) + 1e-4)
    variance_loss = F.relu(1.0 - variance).mean()
    covariance = centered.T @ centered / max(centered.shape[0] - 1, 1)
    covariance = covariance - torch.diag_embed(torch.diagonal(covariance))
    covariance_loss = covariance.square().sum() / covariance.shape[0]
    total = 25.0 * invariance + 25.0 * variance_loss + covariance_loss
    return total, {"invariance": invariance, "variance": variance_loss,
                   "covariance": covariance_loss}


def continuous_scale_views(x: torch.Tensor, low: float, high: float):
    """Two isotropically scaled/translated views and inverse grids to source."""
    batch = x.shape[0]
    theta = torch.zeros((batch, 2, 3), device=x.device, dtype=x.dtype)
    scale_a = torch.empty(batch, device=x.device, dtype=x.dtype).uniform_(low, high)
    scale_b = torch.empty(batch, device=x.device, dtype=x.dtype).uniform_(low, high)
    theta[:, 0, 0] = scale_a; theta[:, 1, 1] = scale_a
    theta[:, 0, 2] = torch.empty(batch, device=x.device, dtype=x.dtype).uniform_(-0.06, 0.06)
    theta[:, 1, 2] = torch.empty(batch, device=x.device, dtype=x.dtype).uniform_(-0.06, 0.06)
    other = torch.zeros_like(theta)
    other[:, 0, 0] = scale_b; other[:, 1, 1] = scale_b
    other[:, 0, 2] = torch.empty(batch, device=x.device, dtype=x.dtype).uniform_(-0.06, 0.06)
    other[:, 1, 2] = torch.empty(batch, device=x.device, dtype=x.dtype).uniform_(-0.06, 0.06)
    size = x.shape
    view_a = F.grid_sample(x, F.affine_grid(theta, size, align_corners=False),
                           mode="bilinear", padding_mode="zeros", align_corners=False)
    view_b = F.grid_sample(x, F.affine_grid(other, size, align_corners=False),
                           mode="bilinear", padding_mode="zeros", align_corners=False)

    def inverse_grid(source):
        inverse = torch.zeros_like(source)
        inverse[:, 0, 0] = source[:, 0, 0].reciprocal()
        inverse[:, 1, 1] = source[:, 1, 1].reciprocal()
        inverse[:, 0, 2] = -source[:, 0, 2] / source[:, 0, 0]
        inverse[:, 1, 2] = -source[:, 1, 2] / source[:, 1, 1]
        return F.affine_grid(inverse, (batch, 1, 64, 64), align_corners=False)
    return view_a, view_b, inverse_grid(theta), inverse_grid(other)


def sample_active_windows(skeleton: torch.Tensor, window: int, limit: int = 32):
    """One deterministic sample location per active source window."""
    active = F.max_pool2d(skeleton, window, stride=window).flatten(1) > 0.5
    batch, total = active.shape
    ids = torch.zeros((batch, limit), dtype=torch.long, device=skeleton.device)
    valid = torch.zeros((batch, limit), dtype=torch.bool, device=skeleton.device)
    windows_per_row = 64 // window
    for row in range(batch):
        found = torch.nonzero(active[row], as_tuple=False).flatten()
        if found.numel() == 0:
            continue
        take = min(limit, int(found.numel()))
        slots = torch.linspace(0, found.numel() - 1, take, device=skeleton.device).round().long()
        ids[row, :take] = found[slots]
        valid[row, :take] = True
    # Return pixel centers so aligned dense feature maps can be sampled.
    y = (ids // windows_per_row) * window + window // 2
    x = (ids % windows_per_row) * window + window // 2
    pixels = y * 64 + x
    # Keep the true 2-D patch identity. Dividing a flattened pixel index by
    # window width does not identify its patch and aliases unrelated rows.
    patch_ids = (y // window) * windows_per_row + (x // window)
    return pixels, patch_ids, valid


def aligned_descriptors(model: WindowSetViT, image: torch.Tensor, inverse_grid: torch.Tensor,
                        normalize: bool = True):
    tokens = model(image)
    side = 64 // model.window_size
    fmap = tokens.transpose(1, 2).reshape(len(image), -1, side, side)
    # Each token represents one filter window; nearest expansion keeps each
    # window's descriptor constant within its local dot set.
    dense = F.interpolate(fmap, size=(64, 64), mode="nearest")
    aligned = F.grid_sample(dense, inverse_grid, mode="bilinear",
                            padding_mode="zeros", align_corners=False)
    return F.normalize(aligned, dim=1, eps=1e-6) if normalize else aligned


def gather_points(dense: torch.Tensor, pixels: torch.Tensor) -> torch.Tensor:
    flat = dense.permute(0, 2, 3, 1).reshape(len(dense), 4096, -1)
    return torch.gather(flat, 1, pixels[..., None].expand(-1, -1, flat.shape[-1]))


def stable_hash(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def eval_correspondence(model: WindowSetViT, bank: np.memmap, indices: list[int],
                        window: int, low: float, high: float, device, limit: int = 32):
    model.eval(); hits = total = 0; positive = []; negative = []
    generator_state = torch.random.get_rng_state()
    torch.manual_seed(881 + window)
    with torch.inference_mode():
        for start in range(0, min(len(indices), 2048), 48):
            ids = indices[start:start + 48]
            x = torch.from_numpy(np.array(bank[ids], copy=True)).to(device=device, dtype=torch.float32).div_(255.)
            a, b, ga, gb = continuous_scale_views(x, low, high)
            da = aligned_descriptors(model, a, ga); db = aligned_descriptors(model, b, gb)
            points, patch_ids, valid = sample_active_windows(x[:, 1:2], window, limit)
            pa, pb = gather_points(da, points), gather_points(db, points)
            sims = torch.bmm(pa, pb.transpose(1, 2))
            diag = sims.diagonal(dim1=1, dim2=2)
            positive.extend(diag[valid].cpu().tolist())
            # Ignore duplicate/padded tokens when collecting within-glyph negatives.
            off = ~torch.eye(sims.shape[1], device=device, dtype=torch.bool).unsqueeze(0)
            off = off & valid[:, :, None] & valid[:, None, :]
            off &= patch_ids[:, :, None] != patch_ids[:, None, :]
            negative.extend(sims[off].cpu().tolist())
            masked = sims.masked_fill(~valid[:, None, :], -2)
            predictions = masked.argmax(dim=-1)
            hits += int(((predictions == torch.arange(sims.shape[1], device=device)[None]) & valid).sum())
            total += int(valid.sum())
    torch.random.set_rng_state(generator_state)
    if not positive or not negative:
        raise ValueError("validation did not produce positive and distinct-window negative correspondences")
    return {"glyphImages": min(len(indices), 2048), "points": total,
            "correspondenceRecallAt1": hits / max(total, 1),
            "positiveCosineMedian": float(np.median(positive)),
            "negativeCosineP99": float(np.quantile(negative, .99)),
            "positiveScores": positive, "negativeScores": negative}


def eval_position_free_set_coverage(model: WindowSetViT, bank: np.memmap,
                                    indices: list[int], window: int, low: float,
                                    high: float, threshold: float, device):
    """Match transformed glyphs as unordered sets of local-window descriptors."""
    model.eval(); coverages = []; matched_total = 0; window_total = 0
    with torch.inference_mode():
        for start in range(0, min(len(indices), 2048), 48):
            ids = indices[start:start + 48]
            x = torch.from_numpy(np.array(bank[ids], copy=True)).to(
                device=device, dtype=torch.float32).div_(255.)
            a, b, _, _ = continuous_scale_views(x, low, high)
            tokens_a = model(a)
            tokens_b = model(b)
            active_a = F.max_pool2d(a[:, 1:2], window, stride=window).flatten(1) > .5
            active_b = F.max_pool2d(b[:, 1:2], window, stride=window).flatten(1) > .5
            for row in range(len(ids)):
                va = F.normalize(tokens_a[row, active_a[row]], dim=-1).cpu().numpy()
                vb = F.normalize(tokens_b[row, active_b[row]], dim=-1).cpu().numpy()
                if not len(va) or not len(vb):
                    continue
                coverage, matched = greedy_shared(va, vb, threshold)
                coverages.append(coverage)
                matched_total += matched
                window_total += max(len(va), len(vb))
    if not coverages:
        raise ValueError("position-free validation produced no active window sets")
    return {"glyphImages": len(coverages),
            "meanSharedWindowCoverage": float(np.mean(coverages)),
            "medianSharedWindowCoverage": float(np.median(coverages)),
            "aggregateMatchedWindows": matched_total,
            "aggregateLargerSideWindows": window_total,
            "aggregateSharedWindowCoverage": matched_total / max(window_total, 1),
            "threshold": threshold,
            "absoluteCanvasPositionsUsedForMatching": False}


def balanced_threshold(positive: list[float], negative: list[float]):
    pos, neg = np.asarray(positive), np.asarray(negative)
    candidates = np.unique(np.quantile(np.concatenate((pos, neg)), np.linspace(0, 1, 301)))
    best = None
    for threshold in candidates:
        tpr = float(np.mean(pos >= threshold)); fpr = float(np.mean(neg >= threshold))
        score = .5 * (tpr + 1 - fpr)
        if best is None or score > best[0]:
            best = (score, float(threshold), tpr, fpr)
    return {"threshold": best[1], "balancedAccuracy": best[0],
            "positiveRecall": best[2], "negativeFalseMatchRate": best[3]}


def extract_token_sets(model: WindowSetViT,
                      sources: list[tuple[np.memmap, list[dict]]], device):
    result: dict[str, dict[int, list[tuple[np.ndarray, dict]]]] = defaultdict(
        lambda: defaultdict(list))
    model.eval()
    with torch.inference_mode():
        for bank, rows in sources:
            for start in range(0, len(rows), 64):
                batch = rows[start:start + 64]
                x = torch.from_numpy(np.array([bank[r["imageIndex"]] for r in batch], copy=True)).to(
                    device=device, dtype=torch.float32).div_(255.)
                tokens = F.normalize(model(x), dim=-1)
                active = F.max_pool2d(x[:, 1:2], model.window_size,
                                      stride=model.window_size).flatten(1) > .5
                for i, row in enumerate(batch):
                    keep = active[i]
                    vecs = tokens[i, keep].cpu().numpy()
                    if len(vecs):
                        parent_font = row.get("fontFileSHA256", row.get("parentFontFileSHA256"))
                        if not parent_font:
                            raise ValueError("candidate glyph view has no source-font identity")
                        result[str(parent_font)][int(row["vocabularyIndex"])].append((vecs, row))
    return result


def greedy_shared(a: np.ndarray, b: np.ndarray, threshold: float):
    scores = a @ b.T
    candidates = np.flatnonzero(scores >= threshold)
    if not candidates.size:
        return 0.0, 0
    order = candidates[np.argsort(scores.reshape(-1)[candidates])[::-1]]
    used_a = np.zeros(len(a), bool); used_b = np.zeros(len(b), bool); matched = 0
    for flat in order:
        i, j = np.unravel_index(flat, scores.shape)
        if scores[i, j] < threshold:
            break
        if not used_a[i] and not used_b[j]:
            used_a[i] = True; used_b[j] = True; matched += 1
    return matched / max(len(a), len(b)), matched


def build_subsets(model, sources, vocabulary, threshold: float, device,
                  max_fonts_per_pair: int):
    per_font = extract_token_sets(model, sources, device)
    evidence: dict[tuple[int, int], list[dict]] = defaultdict(list)
    fonts_by_label: dict[int, set[str]] = defaultdict(set)
    for font_hash, symbols in per_font.items():
        for label in symbols:
            fonts_by_label[label].add(font_hash)
    label_ids = sorted(fonts_by_label)
    for offset, a in enumerate(label_ids):
        for b in label_ids[offset + 1:]:
            common_fonts = fonts_by_label[a] & fonts_by_label[b]
            chosen_fonts = sorted(
                common_fonts,
                key=lambda font: hashlib.sha256(f"{a}:{b}:{font}".encode()).digest(),
            )[:max_fonts_per_pair]
            for font_hash in chosen_fonts:
                views_a = per_font[font_hash][a]
                views_b = per_font[font_hash][b]
                view_scores = []
                for va, row_a in views_a:
                    for vb, row_b in views_b:
                        shared, matched = greedy_shared(va, vb, threshold)
                        view_scores.append({"sharedCoverage": shared,
                                            "matchedWindows": matched,
                                            "windowsA": len(va), "windowsB": len(vb),
                                            "imageA": int(row_a["imageIndex"]),
                                            "imageB": int(row_b["imageIndex"]),
                                            "viewA": row_a.get("modality", "font-glyph"),
                                            "viewB": row_b.get("modality", "font-glyph")})
                coverage_values = [item["sharedCoverage"] for item in view_scores]
                evidence[(a, b)].append({
                    "fontFileSHA256": font_hash,
                    "sharedCoverage": float(np.median(coverage_values)),
                    "viewPairCount": len(view_scores),
                    "viewPairs": view_scores,
                    "windowsA": max((item["windowsA"] for item in view_scores), default=0),
                    "windowsB": max((item["windowsB"] for item in view_scores), default=0)})
    edges = []
    for (a, b), observations in evidence.items():
        values = [x["sharedCoverage"] for x in observations]
        median = float(np.median(values))
        if median >= .5:
            edges.append({"indexA": a, "indexB": b, "medianSharedCoverage": median,
                          "sourceFontObservationCount": len(observations),
                          "fontObservations": observations})
    labels = {int(v["index"]): str(v["label"]) for v in vocabulary}
    combining_names = {"\\dot": "点アクセント", "\\hat": "山形アクセント",
                       "\\overline": "上線", "\\tilde": "チルダ",
                       "\\underline": "下線", "\\vec": "ベクトル矢印"}
    display = {}
    for item in vocabulary:
        index = int(item["index"])
        if item.get("kind") == "math-structure":
            display[index] = "分数構造"
        elif item.get("kind") == "unicode-combining":
            display[index] = combining_names[item["label"]]
        else:
            display[index] = chr(int(item["unicodeScalar"][2:], 16))
    neighbors = {i: set() for i in range(229)}
    for edge in edges:
        neighbors[edge["indexA"]].add(edge["indexB"]); neighbors[edge["indexB"]].add(edge["indexA"])
    subsets = []
    for focus in range(229):
        ids = [focus, *sorted(neighbors[focus])]
        subsets.append({"focusIndex": focus, "focus": labels[focus], "focusDisplay": display[focus],
                        "members": [{"index": i, "label": labels[i], "display": display[i]} for i in ids]})
    return {"schema": "firebird-local-window-set-vit-subsets-v1",
            "status": "font-derived candidates; not human semantic gold",
            "windowSize": model.window_size,
            "candidateFontPoolCount": len(per_font),
            "maxFontObservationsPerPair": max_fonts_per_pair,
            "similarityRule": "All original and generated glyph views are grouped by their source font and symbol. Active local-window descriptors are greedily matched one-to-one without absolute canvas positions. Each source-font score is the median across its available view pairs; an edge is included when the median across selected source-font scores reaches the user-specified 0.50 shared-coverage criterion. No majority-of-fonts support gate is applied.",
            "threshold": threshold, "pairCount": len(edges),
            "labelsWithNeighbors": sum(bool(x) for x in neighbors.values()),
            "labelsWithoutNeighbors": sum(not x for x in neighbors.values()),
            "outerTestOpened": False, "humanSemanticGold": False,
            "subsets": subsets, "acceptedPairEvidence": edges}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--window-sizes", type=int, nargs="+", default=[4, 8, 16])
    parser.add_argument("--scale-low", type=float, default=.90)
    parser.add_argument("--scale-high", type=float, default=1.10)
    parser.add_argument("--max-fonts-per-pair", type=int, default=12)
    parser.add_argument("--synthetic-base-bank", type=Path,
                        default=Path("runs/agent-control/cycle635-font-handwriting-gap-fill/synthetic-font-shapes.u8"))
    parser.add_argument("--synthetic-base-index", type=Path,
                        default=Path("runs/agent-control/cycle635-font-handwriting-gap-fill/synthetic-font-shapes.jsonl"))
    parser.add_argument("--synthetic-gap-bank", type=Path,
                        default=Path("runs/agent-control/cycle637-synthetic-font-gap-fill-corrected/synthetic-font-gap-variants.u8"))
    parser.add_argument("--synthetic-gap-index", type=Path,
                        default=Path("runs/agent-control/cycle637-synthetic-font-gap-fill-corrected/synthetic-font-gap-variants.jsonl"))
    args = parser.parse_args()
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is required; CPU fallback is prohibited.")
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite run: {args.output}")
    if (args.epochs < 1 or args.batch_size < 8 or args.max_fonts_per_pair < 1
            or not (0 < args.scale_low < args.scale_high)):
        raise ValueError("invalid epoch, batch, or continuous scale range")
    if any(w not in (4, 8, 16) for w in args.window_sizes) or len(set(args.window_sizes)) != len(args.window_sizes):
        raise ValueError("window sizes must be distinct members of 4, 8, 16")

    manifest_path = Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json")
    bank_path = Path("runs/agent-control/cycle624-firebird-part-similarity-v1/contour-skeleton-corpus.u8")
    vocab_path = Path("runs/agent-control/cycle621-firebird-label-kinds.json")
    split_path = Path("runs/agent-control/cycle625-firebird-pair-overlap-v2/training-report.json")
    manifest_bytes = manifest_path.read_bytes(); manifest = json.loads(manifest_bytes)
    vocabulary_bytes = vocab_path.read_bytes(); vocabulary_manifest = json.loads(vocabulary_bytes)
    split_report = json.loads(split_path.read_text(encoding="utf-8"))
    rows = manifest["rows"]
    if len(vocabulary_manifest["entries"]) != 229 or len(rows) != manifest["renderedImageCount"]:
        raise ValueError("authoritative font corpus or 229-symbol vocabulary mismatch")
    if manifest.get("vocabularySHA256") != vocabulary_manifest.get("vocabularySHA256"):
        raise ValueError("font corpus and 229-symbol vocabulary are not the same ordered contract")
    if split_report.get("corpusManifestSHA256") != hashlib.sha256(manifest_bytes).hexdigest():
        raise ValueError("fixed font split belongs to another corpus manifest")
    if bank_path.stat().st_size != len(rows) * 2 * 64 * 64:
        raise ValueError("contour/skeleton point bank byte size disagrees with font manifest")
    bank = np.memmap(bank_path, mode="r", dtype=np.uint8, shape=(len(rows), 2, 64, 64))
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
    if split_report.get("corpusManifestSHA256") != manifest_sha:
        raise ValueError("fixed 202/10/40 font split belongs to another corpus manifest")
    fit_fonts = set(split_report["fitFontFiles"])
    validation_fonts = set(split_report["validationFontFiles"])
    generation_fonts = set(split_report["generationFontFiles"])
    if (len(fit_fonts), len(validation_fonts), len(generation_fonts)) != (202, 10, 40):
        raise ValueError("expected the fixed 202 fit / 10 validation / 40 generation font split")
    if fit_fonts & validation_fonts or fit_fonts & generation_fonts or validation_fonts & generation_fonts:
        raise AssertionError("font leakage in the fixed 202/10/40 split")
    observed_fonts = {row["fontFileSHA256"] for row in rows}
    if fit_fonts | validation_fonts | generation_fonts != observed_fonts:
        raise ValueError("fixed split does not partition every font in the corpus")
    fit_ids = [i for i, row in enumerate(rows) if row["fontFileSHA256"] in fit_fonts]
    ordered_validation = sorted(validation_fonts)
    epoch_fonts = set(ordered_validation[:5])
    calibration_fonts = set(ordered_validation[5:])

    def one_glyph_per_font_label(font_files: set[str]) -> list[int]:
        chosen: dict[tuple[str, int], int] = {}
        for index, row in enumerate(rows):
            font = row["fontFileSHA256"]
            if font in font_files:
                chosen.setdefault((font, int(row["vocabularyIndex"])), index)
        return [chosen[key] for key in sorted(chosen)]

    epoch_ids = one_glyph_per_font_label(epoch_fonts)
    calibration_ids = one_glyph_per_font_label(calibration_fonts)
    generation_ids = one_glyph_per_font_label(generation_fonts)
    if not epoch_ids or not calibration_ids or not generation_ids:
        raise ValueError("font split produced an empty validation/calibration/generation set")

    synthetic_sources = []
    synthetic_counts = {}
    for name, bank_path_arg, index_path_arg in (
        ("cycle635", args.synthetic_base_bank, args.synthetic_base_index),
        ("cycle637", args.synthetic_gap_bank, args.synthetic_gap_index),
    ):
        manifest_path_arg = bank_path_arg.parent / "manifest.json"
        synthetic_manifest = json.loads(manifest_path_arg.read_text(encoding="utf-8"))
        if synthetic_manifest.get("inputs", {}).get("fontManifestSHA256") != manifest_sha:
            raise ValueError(f"{name} synthetic views were generated from another font manifest")
        synthetic_rows = [json.loads(line) for line in index_path_arg.read_text(encoding="utf-8").splitlines() if line]
        if bank_path_arg.stat().st_size != len(synthetic_rows) * 2 * 64 * 64:
            raise ValueError(f"{name} synthetic bank size does not match its index")
        for row in synthetic_rows:
            parent_font = row.get("parentFontFileSHA256")
            if parent_font not in fit_fonts:
                raise ValueError(f"{name} synthetic view is not derived from a fit font")
            if int(row["vocabularyIndex"]) < 0 or int(row["vocabularyIndex"]) >= 229:
                raise ValueError(f"{name} synthetic view has an unknown symbol label")
        synthetic_bank = np.memmap(bank_path_arg, mode="r", dtype=np.uint8,
                                   shape=(len(synthetic_rows), 2, 64, 64))
        synthetic_sources.append((synthetic_bank, synthetic_rows))
        synthetic_counts[name] = {"rowsInArtifact": len(synthetic_rows),
                                  "fitRows": len(synthetic_rows),
                                  "candidateRows": len(synthetic_rows),
                                  "bankSHA256": stable_hash(bank_path_arg),
                                  "indexSHA256": stable_hash(index_path_arg)}
    args.output.mkdir(parents=True)
    device = torch.device("mps")
    summary = {"schema": "firebird-local-window-set-vit-sweep-v1",
               "fontManifestSHA256": manifest_sha,
               "shapeBankSHA256": stable_hash(bank_path),
               "splitReportSHA256": hashlib.sha256(split_path.read_bytes()).hexdigest(),
               "vocabularySHA256": vocabulary_manifest["vocabularySHA256"],
               "fitFontCount": len(set(rows[i]["fontFileSHA256"] for i in fit_ids)),
               "epochSelectionFontCount": len(epoch_fonts),
               "thresholdCalibrationFontCount": len(calibration_fonts),
               "subsetGenerationFontCount": len(generation_fonts), "fitGlyphRows": len(fit_ids),
               "epochSelectionGlyphs": len(epoch_ids), "thresholdCalibrationGlyphs": len(calibration_ids),
               "subsetGenerationGlyphs": len(generation_ids), "trainingDevice": str(device),
               "epochs": args.epochs, "objective": "VICReg invariance + variance + covariance; no different-window negatives",
               "syntheticTypesetViews": synthetic_counts,
               "handwritingUsed": False,
               "batchSize": args.batch_size, "optimizer": "AdamW", "learningRate": 1e-4,
               "seedBase": 20261105,
               "scaleAugmentation": {"kind": "continuous isotropic linear scaling",
                                                               "low": args.scale_low, "high": args.scale_high},
               "windows": []}

    for window in args.window_sizes:
        torch.manual_seed(20261105 + window); np.random.seed(20261105 + window)
        model = WindowSetViT(window).to(device)
        training_dataset = ShapeBank(bank, rows, fit_ids, synthetic_sources)
        fit_labels = np.asarray(training_dataset.labels, dtype=np.int64)
        counts = np.bincount(fit_labels, minlength=229)
        weights = torch.as_tensor(1 / np.maximum(counts[fit_labels], 1), dtype=torch.double)
        sampler = WeightedRandomSampler(weights, len(training_dataset), replacement=True,
                                        generator=torch.Generator().manual_seed(20261105 + window))
        loader = DataLoader(training_dataset, batch_size=args.batch_size,
                            sampler=sampler, num_workers=0, drop_last=True)
        optimizer = torch.optim.AdamW(model.parameters(), lr=1e-4, weight_decay=1e-4)
        history = []; best_set_coverage = -1.; selected_state = None; selected_epoch = None
        for epoch in range(1, args.epochs + 1):
            model.train(); epoch_loss = 0.; observations = 0
            for batch_index, (dots, _) in enumerate(loader, start=1):
                x = dots.to(device=device, dtype=torch.float32).div_(255.)
                a, b, grid_a, grid_b = continuous_scale_views(x, args.scale_low, args.scale_high)
                da = aligned_descriptors(model, a, grid_a, normalize=False)
                db = aligned_descriptors(model, b, grid_b, normalize=False)
                points, _, valid = sample_active_windows(x[:, 1:2], window)
                pa, pb = gather_points(da, points), gather_points(db, points)
                loss, loss_parts = local_vicreg_loss(pa, pb, valid)
                optimizer.zero_grad(set_to_none=True); loss.backward()
                nn.utils.clip_grad_norm_(model.parameters(), 1.0); optimizer.step()
                epoch_loss += float(loss.detach()); observations += 1
                if batch_index % 100 == 0:
                    print(json.dumps({"window": window, "epoch": epoch,
                                      "batch": batch_index, "batchCount": len(loader),
                                      "fitLoss": epoch_loss / observations,
                                      "invarianceLoss": float(loss_parts["invariance"].detach()),
                                      "varianceLoss": float(loss_parts["variance"].detach()),
                                      "covarianceLoss": float(loss_parts["covariance"].detach())},
                                     ensure_ascii=False), flush=True)
            calibration_validation = eval_correspondence(
                model, bank, calibration_ids, window, args.scale_low, args.scale_high, device)
            calibration = balanced_threshold(calibration_validation["positiveScores"],
                                             calibration_validation["negativeScores"])
            selection = eval_position_free_set_coverage(
                model, bank, epoch_ids, window, args.scale_low, args.scale_high,
                calibration["threshold"], device)
            record = {"epoch": epoch, "fitLoss": epoch_loss / max(observations, 1),
                      "trainingBatches": observations,
                      "calibrationCorrespondenceRecallAt1": calibration_validation["correspondenceRecallAt1"],
                      "calibrationPositiveCosineMedian": calibration_validation["positiveCosineMedian"],
                      "calibrationNegativeCosineP99": calibration_validation["negativeCosineP99"],
                      "calibrationThreshold": calibration,
                      "epochSelectionPositionFreeSetCoverage": selection}
            history.append(record)
            print(json.dumps({"window": window, **record}, ensure_ascii=False), flush=True)
            if selection["meanSharedWindowCoverage"] > best_set_coverage:
                best_set_coverage = selection["meanSharedWindowCoverage"]
                selected_epoch = epoch
                selected_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
            epoch_checkpoint = args.output / f"window-{window}-epoch-{epoch}.pt"
            epoch_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
            torch.save({"state_dict": epoch_state, "windowSize": window,
                        "descriptorDimension": 48, "epoch": epoch,
                        "positionFreeSetCoverage": selection["meanSharedWindowCoverage"]},
                       epoch_checkpoint)
        if selected_state is None:
            raise RuntimeError(f"no checkpoint selected for window {window}")
        model.load_state_dict(selected_state, strict=True); model.to(device).eval()
        ckpt = args.output / f"window-{window}-vit.pt"
        torch.save({"state_dict": selected_state, "windowSize": window,
                    "descriptorDimension": 48, "selectedEpoch": selected_epoch}, ckpt)
        calibration_validation = eval_correspondence(model, bank, calibration_ids, window,
                                                      args.scale_low, args.scale_high, device)
        calibration = balanced_threshold(calibration_validation["positiveScores"],
                                         calibration_validation["negativeScores"])
        selected_validation = eval_position_free_set_coverage(
            model, bank, epoch_ids, window, args.scale_low, args.scale_high,
            calibration["threshold"], device)
        synthetic_parent_fonts = {
            str(row["parentFontFileSHA256"])
            for _, synthetic_rows in synthetic_sources for row in synthetic_rows
        }
        candidate_fonts = generation_fonts | synthetic_parent_fonts
        candidate_rows = [row for row in rows if row["fontFileSHA256"] in candidate_fonts]
        candidate_sources = [(bank, candidate_rows), *synthetic_sources]
        subsets = build_subsets(model, candidate_sources, vocabulary_manifest["entries"],
                                calibration["threshold"], device, args.max_fonts_per_pair)
        subsets["candidateGlyphViewCount"] = len(candidate_rows) + sum(
            len(synthetic_rows) for _, synthetic_rows in synthetic_sources)
        subsets["candidateInputModalities"] = ["font-glyph", "synthetic-font-resolution-variant"]
        subset_json = args.output / f"window-{window}-subsets.json"
        subset_json.write_text(json.dumps(subsets, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        table = [f"# 火の鳥・ViT局所窓 {window} の類似部分集合", "",
                 f"直接候補 {subsets['pairCount']}組、近傍あり {subsets['labelsWithNeighbors']}記号、単独 {subsets['labelsWithoutNeighbors']}記号。", "",
                 "| 行 | 記号 | 類似部分集合 |", "|---:|---|---|"]
        for subset in subsets["subsets"]:
            table.append(f"| {subset['focusIndex'] + 1} | {subset['focusDisplay']} | " +
                         "、".join(item["display"] for item in subset["members"]) + " |")
        (args.output / f"window-{window}-subsets.md").write_text("\n".join(table) + "\n", encoding="utf-8")
        summary["windows"].append({"windowSize": window, "history": history,
                                  "selectedEpoch": selected_epoch,
                                  "epochSelection": history[selected_epoch - 1],
                                  "selectedCheckpointPositionFreeValidation": selected_validation,
                                  "calibrationCorrespondenceValidation": {k: v for k, v in calibration_validation.items()
                                                                           if k not in ("positiveScores", "negativeScores")},
                                  "thresholdCalibration": calibration,
                                  "candidateFontPoolCount": len(candidate_fonts),
                                  "candidateGlyphViewCount": subsets["candidateGlyphViewCount"],
                                  "subsetPairCount": subsets["pairCount"],
                                  "labelsWithNeighbors": subsets["labelsWithNeighbors"],
                                  "labelsWithoutNeighbors": subsets["labelsWithoutNeighbors"],
                                  "checkpoint": str(ckpt), "checkpointSHA256": stable_hash(ckpt),
                                  "subsets": str(subset_json)})
        del model, optimizer, loader
        if hasattr(torch.mps, "empty_cache"):
            torch.mps.empty_cache()

    report_path = args.output / "sweep-report.json"
    report_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"stage": "complete", "report": str(report_path),
                      "windowSizes": args.window_sizes}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
