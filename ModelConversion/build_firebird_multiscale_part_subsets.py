#!/usr/bin/env python3
"""Generate symmetric 229-label subsets from learned multiscale glyph parts."""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch
from torch.nn import functional as F

from train_firebird_multiscale_part_descriptor import MultiScaleShapeViT, SCALES


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def one_to_one_coverage(a: np.ndarray, b: np.ndarray, threshold: float) -> dict:
    if len(a) < 2 or len(b) < 2:
        return {"eligible": False, "sharedCoverage": None, "matchedSites": 0,
                "sitesA": len(a), "sitesB": len(b)}
    similarities = a @ b.T
    order = np.argsort(similarities, axis=None)[::-1]
    used_a = np.zeros(len(a), dtype=bool)
    used_b = np.zeros(len(b), dtype=bool)
    matched = 0
    for flat in order:
        i, j = np.unravel_index(flat, similarities.shape)
        if similarities[i, j] < threshold:
            break
        if not used_a[i] and not used_b[j]:
            used_a[i] = True
            used_b[j] = True
            matched += 1
    coverage_a, coverage_b = matched / len(a), matched / len(b)
    return {"eligible": True, "sharedCoverage": min(coverage_a, coverage_b),
            "coverageA": coverage_a, "coverageB": coverage_b, "matchedSites": matched,
            "sitesA": len(a), "sitesB": len(b)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json"))
    parser.add_argument("--images", type=Path, default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.u8"))
    parser.add_argument("--shape-corpus", type=Path, default=Path("runs/agent-control/cycle624-firebird-part-similarity-v1/contour-skeleton-corpus.u8"))
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--max-fonts-per-pair", type=int, default=3)
    parser.add_argument("--output-name", default="similarity-subsets.json")
    args = parser.parse_args()
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is unavailable; subset inference is refused rather than silently moved to CPU.")

    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    rows = manifest["rows"]
    report = json.loads((args.run / "training-report.json").read_text())
    if report.get("schema") != "firebird-typeset-multiscale-part-vit-v1":
        raise ValueError("run is not a trained multiscale part descriptor")
    if report["corpusManifestSHA256"] != hashlib.sha256(manifest_bytes).hexdigest():
        raise ValueError("descriptor and corpus manifest differ")
    if report["corpusRasterSHA256"] != digest(args.images):
        raise ValueError("descriptor and authoritative raster corpus differ")
    shape_path = args.shape_corpus
    if not shape_path.is_file() or shape_path.stat().st_size != len(rows) * 2 * 64 * 64:
        raise FileNotFoundError("manifest-matched contour/skeleton raster corpus is missing or has an invalid size")
    if report["contourSkeletonCorpusSHA256"] != digest(shape_path):
        raise ValueError("descriptor and contour/skeleton raster corpus differ")
    if args.max_fonts_per_pair < 0:
        raise ValueError("max-fonts-per-pair must be nonnegative")
    thresholds = {int(size): report["heldoutMultiscaleValidation"][str(size)]["threshold"] for size in SCALES}
    heldout = set(report["heldoutFontFiles"])
    font_order = sorted(heldout, key=lambda value: hashlib.sha256(("part-subset-calibration:" + value).encode()).digest())
    calibration_fonts = set(font_order[:len(font_order) // 2])
    generation_fonts = {row["fontFileSHA256"] for row in rows} - calibration_fonts

    device = torch.device("mps")
    model = MultiScaleShapeViT().to(device)
    checkpoint_path = args.run / "firebird-multiscale-part-vit.pt"
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
    model.load_state_dict(checkpoint["state_dict"], strict=True)
    model.eval()
    shape = np.memmap(shape_path, mode="r", dtype=np.uint8, shape=(len(rows), 2, 64, 64))
    instances: dict[int, list[dict]] = defaultdict(list)
    displays = {}
    labels = {}
    for row in rows:
        index = int(row["vocabularyIndex"])
        labels[index] = row["label"]
        displays[index] = chr(int(row["unicodeScalar"][2:], 16))
        if row["fontFileSHA256"] in generation_fonts:
            instances[index].append(row)
    for index in instances:
        unique = {row["fontFileSHA256"]: row for row in instances[index]}
        instances[index] = [unique[key] for key in sorted(unique)]
    selected = [row for index in sorted(instances) for row in instances[index]]

    features_by_image = {}
    with torch.inference_mode():
        for start in range(0, len(selected), 32):
            batch = selected[start:start + 32]
            x = torch.from_numpy(np.array([shape[row["imageIndex"]] for row in batch], copy=True)).to(device=device, dtype=torch.float32).div_(255.)
            levels = model.forward_levels(x)
            for local, row in enumerate(batch):
                scales = {}
                for size in SCALES:
                    token_side = size // 8
                    skeleton = F.adaptive_max_pool2d(
                        x[local:local + 1, 1:2], (token_side, token_side)
                    )[0, 0] > .5
                    coords = torch.nonzero(skeleton, as_tuple=False)
                    if len(coords) < 2:
                        continue
                    desc = levels[size][local]
                    values = desc[:, coords[:, 0], coords[:, 1]].T
                    scales[size] = values.cpu().numpy()
                if scales:
                    features_by_image[row["imageIndex"]] = (scales, row)

    samples_by_label: dict[int, dict[str, tuple[dict[int, np.ndarray], dict]]] = defaultdict(dict)
    for row in selected:
        item = features_by_image.get(row["imageIndex"])
        if item is not None:
            samples_by_label[int(row["vocabularyIndex"])][row["fontFileSHA256"]] = item

    evidence = []
    edges = []
    indices = sorted(set(range(229)) | set(labels))
    for offset, a in enumerate(indices):
        for b in indices[offset + 1:]:
            common = sorted(samples_by_label.get(a, {}).keys() & samples_by_label.get(b, {}).keys(),
                            key=lambda font: hashlib.sha256(f"{a}:{b}:{font}".encode()).digest())
            if args.max_fonts_per_pair:
                common = common[:args.max_fonts_per_pair]
            font_scores = []
            for font in common:
                scales_a, _ = samples_by_label[a][font]
                scales_b, _ = samples_by_label[b][font]
                by_scale = {}
                for size in SCALES:
                    if size not in scales_a or size not in scales_b:
                        continue
                    by_scale[size] = one_to_one_coverage(scales_a[size], scales_b[size], thresholds[size])
                eligible = [value["sharedCoverage"] for value in by_scale.values() if value["eligible"]]
                if len(eligible) < 2:
                    continue
                # Equal weight per measured scale prevents a dense 64px skeleton from dominating.
                score = float(np.mean(eligible))
                font_scores.append({"fontFileSHA256": font, "sharedCoverageAcrossScales": score,
                                    "eligibleScaleCount": len(eligible),
                                    "scaleEvidence": {str(size): value for size, value in by_scale.items()}})
            scores = [item["sharedCoverageAcrossScales"] for item in font_scores]
            median = float(np.median(scores)) if scores else None
            passing = sum(value >= .5 for value in scores)
            accepted = len(scores) >= 2 and median is not None and median >= .5 and passing >= 2
            item = {"indexA": a, "symbolA": labels.get(a, "分数结构"), "displayA": displays.get(a, "分数"),
                    "indexB": b, "symbolB": labels.get(b, "分数構造"), "displayB": displays.get(b, "分数"),
                    "sharedFontCount": len(scores), "medianSharedCoverageAcrossScales": median,
                    "fontsAtLeastHalf": passing, "accepted": accepted, "fontEvidence": font_scores}
            if scores:
                evidence.append(item)
            if accepted:
                edges.append(item)

    neighbors = {index: set() for index in range(229)}
    for edge in edges:
        neighbors[edge["indexA"]].add(edge["indexB"])
        neighbors[edge["indexB"]].add(edge["indexA"])
    subsets = []
    for focus in range(229):
        member_indices = [focus, *sorted(neighbors[focus])]
        subsets.append({"focusIndex": focus, "focus": labels.get(focus, "分数構造"),
                        "focusDisplay": displays.get(focus, "分数"),
                        "members": [{"index": index, "symbol": labels.get(index, "分数構造"),
                                     "display": displays.get(index, "分数")} for index in member_indices],
                        "directPairEvidence": [edge for edge in edges if focus in (edge["indexA"], edge["indexB"])
                                               and (edge["indexA"] if edge["indexB"] == focus else edge["indexB"]) in neighbors[focus]]})

    output = {"schema": "firebird-typeset-multiscale-part-subsets-v1",
              "task": "Build symmetric visual-part neighborhoods across the fixed 229-label vocabulary from font-rendered glyphs.",
              "input": "Mac CoreText typeset contour and medial-skeleton raster maps only; no handwritten examples, recognition confusions, or user-authored pairs.",
              "checkpoint": str(checkpoint_path), "checkpointSHA256": digest(checkpoint_path),
              "corpusManifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
              "thresholdCalibrationHeldoutFontCount": len(calibration_fonts),
              "subsetGenerationSourceFontCount": len(generation_fonts),
              "scales": list(SCALES), "scaleThresholds": thresholds,
              "pairRule": "For each same-font glyph pair, greedily create symmetric one-to-one descriptor correspondences at the native ViT patch-token sites for 64/32/16px inputs. Skeleton occupancy is pooled to the same token grid; interpolated duplicate feature sites are never counted. Divide matched sites by each glyph's active token sites, take the smaller directional coverage, and average eligible scales equally; a font counts only when at least two scales have at least two active token sites per glyph. Accept only with at least two shared source fonts, median coverage >= 0.50, and >=2 fonts individually >=0.50.",
              "subsetSemantics": "Overlapping direct-neighbor sets; no transitive closure. Each of the 229 vocabulary indices has exactly one focal set; labels without accepted neighbors remain singleton sets.",
              "outerTestOpened": False, "acceptedDirectPairCount": len(edges),
              "labelsWithNeighbors": sum(bool(neighbors[index]) for index in neighbors),
              "labelsWithoutNeighbors": sum(not neighbors[index] for index in neighbors),
              "subsets": subsets, "acceptedPairEvidence": edges,
              "limitations": ["Font files used for descriptor fitting also occur in subset-generation fonts; these are candidate generation results, not independent generalization estimates.",
                              "Calibration is for local correspondence, not semantic correctness of symbol-pair similarity.",
                              "No human-marked shared-part reference set exists, so pair precision and recall are not measured.",
                              "The structure-only fraction label has no standalone glyph raster and remains an explicit singleton."]}
    output_path = args.run / args.output_name
    output_path.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n")
    table = ["# 活字の輪郭・骨格による多解像度類似部分集合", "",
             f"229記号。採用ペア {len(edges)}、近傍あり {output['labelsWithNeighbors']}、近傍なし {output['labelsWithoutNeighbors']}。", "",
             "| 行 | 中心記号 | 類似部分集合 |", "|---:|---|---|"]
    for row in subsets:
        members = "、".join(member["display"] for member in row["members"])
        table.append(f"| {row['focusIndex'] + 1} | {row['focusDisplay']} | {members} |")
    output_path.with_suffix(".md").write_text("\n".join(table) + "\n")
    print(json.dumps({"output": str(output_path), "labels": len(subsets), "acceptedPairs": len(edges),
                      "labelsWithNeighbors": output["labelsWithNeighbors"],
                      "labelsWithoutNeighbors": output["labelsWithoutNeighbors"]}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
