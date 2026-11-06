#!/usr/bin/env python3
"""Measure ViT glyph confusions across controlled raster degradation views."""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path

import numpy as np
import torch
from torch.nn import functional as F

from train_firebird_typeset_vit import FontGlyphViT


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def degraded(batch: torch.Tensor, condition: str) -> torch.Tensor:
    if condition == "clean":
        return batch
    if condition.startswith("res-"):
        size = int(condition.removeprefix("res-"))
        low = F.interpolate(batch, size=(size, size), mode="bilinear", align_corners=False, antialias=True)
        return F.interpolate(low, size=(64, 64), mode="bilinear", align_corners=False)
    if condition.startswith("blur-"):
        sigma = float(condition.removeprefix("blur-"))
        radius = int(np.ceil(3 * sigma))
        coords = torch.arange(-radius, radius + 1, device=batch.device, dtype=batch.dtype)
        one = torch.exp(-(coords * coords) / (2 * sigma * sigma)); one /= one.sum()
        kernel = torch.outer(one, one).view(1, 1, len(coords), len(coords))
        return F.conv2d(batch, kernel, padding=radius).clamp_(0, 1)
    if condition.startswith("resblur-"):
        size_text, sigma_text = condition.removeprefix("resblur-").split("-")
        return degraded(degraded(batch, f"res-{size_text}"), f"blur-{sigma_text}")
    raise ValueError(f"unknown raster condition: {condition}")


def complete_link_partition(labels: list[str], edges: dict[tuple[str, str], float]) -> list[list[str]]:
    adjacency = {label: set() for label in labels}
    for left, right in edges:
        adjacency[left].add(right); adjacency[right].add(left)
    groups = [{label} for label in labels]
    group_of = {label: index for index, label in enumerate(labels)}
    for (left, right), _ in sorted(edges.items(), key=lambda item: (-item[1], item[0])):
        a, b = group_of[left], group_of[right]
        if a == b:
            continue
        ga, gb = groups[a], groups[b]
        if all(y in adjacency[x] for x in ga for y in gb):
            merged = ga | gb
            groups[a], groups[b] = merged, set()
            for label in merged:
                group_of[label] = a
    return sorted((sorted(group) for group in groups if group), key=lambda group: group[0])


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--images", type=Path, required=True)
    p.add_argument("--manifest", type=Path, required=True)
    p.add_argument("--vocabulary", type=Path, required=True)
    p.add_argument("--font-split", type=Path, required=True)
    p.add_argument("--class-map", type=Path, required=True)
    p.add_argument("--font-hand-partition", type=Path, action="append", required=True,
                   help="same checkpoint's font plus held-out handwriting-validation evidence")
    p.add_argument("--checkpoint", action="append", required=True, metavar="NAME=PATH")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--batch-size", type=int, default=256)
    p.add_argument("--threshold", type=float, default=0.10)
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required; CPU fallback is prohibited")
    args = p.parse_args()
    if args.output.exists() or args.batch_size < 1 or not 0 < args.threshold <= 1:
        raise ValueError("output must be new; batch size and confusion threshold must be valid")

    vocab_bytes = args.vocabulary.read_bytes(); vocabulary = json.loads(vocab_bytes)["labels"]
    if len(vocabulary) != 229 or len(set(vocabulary)) != 229:
        raise ValueError("expected the ordered 229-symbol vocabulary")
    manifest_bytes = args.manifest.read_bytes(); manifest = json.loads(manifest_bytes); rows = manifest["rows"]
    if manifest.get("schema") != "firebird-mac-font-glyph-raster-v1" or manifest.get("vocabularySHA256") != hashlib.sha256(vocab_bytes).hexdigest():
        raise ValueError("font raster manifest does not match the ordered vocabulary")
    if args.images.stat().st_size != len(rows) * 64 * 64:
        raise ValueError("font raster byte count differs from its manifest")
    split = json.loads(args.font_split.read_text()); held_files = set(split["validationFontFileSHA256"])
    class_map = json.loads(args.class_map.read_text())
    vi_to_ci = {int(row["vocabularyIndex"]): int(row["classIndex"]) for row in class_map}
    ci_to_vi = {int(row["classIndex"]): int(row["vocabularyIndex"]) for row in class_map}
    evaluated = set(split["evaluatedVocabularyIndices"])
    if len(vi_to_ci) != 228 or set(ci_to_vi) != set(range(228)):
        raise ValueError("expected the baseline ViT's 228 standalone glyph classes")
    indices, truth_vi = [], []
    for i, row in enumerate(rows):
        vi = int(row["vocabularyIndex"])
        if vi not in vi_to_ci:
            raise ValueError(f"font-rendered label is absent from the ViT class map: {row['label']}")
        if vi in evaluated and row["fontFileSHA256"] in held_files:
            indices.append(i); truth_vi.append(vi)
    if not indices:
        raise ValueError("held-out font evaluation set is empty")
    raw = np.memmap(args.images, mode="r", dtype=np.uint8, shape=(len(rows), 64, 64))
    x = torch.from_numpy(np.array(raw[indices], copy=True)).unsqueeze(1).float().div_(255)
    y = torch.tensor([vi_to_ci[vi] for vi in truth_vi], dtype=torch.long)
    font_loader = torch.utils.data.DataLoader(torch.utils.data.TensorDataset(x, y), batch_size=args.batch_size, shuffle=False)
    conditions = ("clean", "res-16", "res-24", "res-32", "res-48", "blur-0.45", "blur-0.75", "blur-1.05", "resblur-16-0.75", "resblur-32-0.75")
    labels = list(vocabulary)
    candidate_parts = []
    if len(args.font_hand_partition) != len(args.checkpoint):
        raise ValueError("supply one matching held-out-handwriting partition for every checkpoint")
    for candidate_index, spec in enumerate(args.checkpoint):
        if "=" not in spec:
            raise ValueError(f"checkpoint must use NAME=PATH: {spec}")
        name, path_text = spec.split("=", 1); path = Path(path_text)
        if not name or not path.is_file():
            raise FileNotFoundError(path)
        checkpoint = torch.load(path, map_location="cpu", weights_only=False)
        if checkpoint.get("classMap") != class_map or not isinstance(checkpoint.get("validation"), dict):
            raise ValueError(f"candidate checkpoint provenance or class map mismatch: {path}")
        model = FontGlyphViT(228).to("mps"); model.load_state_dict(checkpoint["model"], strict=True); model.eval()
        cond_results, edge_conditions, edge_rates, edge_counts = {}, {}, {}, {}
        for condition in conditions:
            counts_by_source = {vi: Counter() for vi in evaluated}
            correct1 = correct5 = total = 0
            per_class_hits: dict[int, list[int]] = {vi: [0, 0, 0] for vi in evaluated}
            with torch.inference_mode():
                for images, targets in font_loader:
                    images = degraded(images.to("mps"), condition)
                    logits = model(images)
                    top1 = logits.argmax(1).cpu(); top5 = logits.topk(5, dim=1).indices.cpu()
                    targets = targets.cpu()
                    for source_ci, predicted_ci in zip(targets.tolist(), top1.tolist()):
                        source_vi, target_vi = ci_to_vi[source_ci], ci_to_vi[predicted_ci]
                        counts_by_source[source_vi][target_vi] += 1
                    hit1 = top1.eq(targets); hit5 = top5.eq(targets[:, None]).any(1)
                    correct1 += int(hit1.sum()); correct5 += int(hit5.sum()); total += len(targets)
                    for j, vi in enumerate([ci_to_vi[i] for i in targets.tolist()]):
                        per_class_hits[vi][0] += int(hit1[j]); per_class_hits[vi][1] += int(hit5[j]); per_class_hits[vi][2] += 1
            valid_classes = [vi for vi in evaluated if per_class_hits[vi][2]]
            cond_results[condition] = {"top1": correct1 / total, "top5": correct5 / total, "count": total,
                                       "macroTop1": float(np.mean([per_class_hits[vi][0] / per_class_hits[vi][2] for vi in valid_classes])),
                                       "macroTop5": float(np.mean([per_class_hits[vi][1] / per_class_hits[vi][2] for vi in valid_classes]))}
            for left_pos, left in enumerate(sorted(evaluated)):
                left_total = sum(counts_by_source[left].values())
                for right in sorted(evaluated)[left_pos + 1:]:
                    right_total = sum(counts_by_source[right].values())
                    c_lr, c_rl = counts_by_source[left].get(right, 0), counts_by_source[right].get(left, 0)
                    r_lr = c_lr / left_total if left_total else 0.0
                    r_rl = c_rl / right_total if right_total else 0.0
                    if max(c_lr, c_rl) >= 1 and max(r_lr, r_rl) >= args.threshold:
                        pair = (vocabulary[left], vocabulary[right])
                        edge_conditions.setdefault(pair, []).append(condition)
                        score = max(r_lr, r_rl)
                        if score > edge_rates.get(pair, -1):
                            edge_rates[pair] = score; edge_counts[pair] = [c_lr, c_rl]
        hand_partition = args.font_hand_partition[candidate_index]
        hand_doc = json.loads(hand_partition.read_text())
        if hand_doc.get("vit", {}).get("sha256") != hashlib.sha256(path.read_bytes()).hexdigest():
            raise ValueError(f"handwriting validation evidence was not generated by checkpoint {name}")
        hand_edges, hand_rows = {}, {r["symbol"]: r for r in hand_doc["perSymbolEvidence"]}
        for i, left in enumerate(labels):
            a = hand_rows.get(left)
            if not a: continue
            ca = a.get("handwritingRecognitionCountsByLabel", {})
            na = int(a.get("handwritingImageCount", 0))
            for right in labels[i + 1:]:
                b = hand_rows.get(right)
                if not b: continue
                cb = b.get("handwritingRecognitionCountsByLabel", {})
                nb = int(b.get("handwritingImageCount", 0))
                c1, c2 = int(ca.get(right, 0)), int(cb.get(left, 0))
                r1, r2 = c1 / na if na else 0.0, c2 / nb if nb else 0.0
                if max(c1, c2) >= 1 and max(r1, r2) >= args.threshold:
                    hand_edges[(left, right)] = {"rates": [r1, r2], "counts": [c1, c2]}
        edges = {pair: rate for pair, rate in edge_rates.items()}
        for pair, evidence in hand_edges.items():
            edges[pair] = max(edges.get(pair, 0.0), *evidence["rates"])
        groups = complete_link_partition(labels, edges)
        evidence_pairs = []
        for pair in sorted(set(edge_rates) | set(hand_edges)):
            evidence_pairs.append({"symbols": list(pair),
                                   "font": ({"maxDirectionalRate": edge_rates[pair], "counts": edge_counts[pair],
                                             "conditions": edge_conditions[pair]} if pair in edge_rates else None),
                                   "handwritingValidation": hand_edges.get(pair)})
        candidate_parts.append({"name": name, "checkpoint": str(path), "checkpointSHA256": sha256(path),
                                "selectedEpoch": checkpoint["epoch"], "cleanAndDegradedFontMetrics": cond_results,
                                "fontEvaluationCount": len(indices), "fontEvaluatedClassCount": len(evaluated),
                                "handwritingValidation": hand_doc["recognitionEvidence"]["handwriting"],
                                "subsetCount": len(groups), "multiMemberSubsetCount": sum(len(g) > 1 for g in groups),
                                "largestSubsetSize": max(map(len, groups)),
                                "subsets": [{"subsetKey": g[0], "members": g} for g in groups],
                                "pairwiseEvidence": evidence_pairs})
    result = {"schema": "firebird-vit-degradation-confusion-subsets-v1",
              "task": "build complete 229-label similarity partitions from font-image confusion across controlled raster degradations plus source-disjoint handwriting validation confusion",
              "groupingRule": f"symmetric pair edge if either direction has at least one error at >= {args.threshold:.3f} in any listed font condition or held-out handwriting validation; deterministic complete-link merging; no stroke sequence or coordinates used",
              "conditions": list(conditions), "outerTestOpened": False,
              "fontSplitSHA256": sha256(args.font_split), "fontManifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
              "fontRasterSHA256": sha256(args.images), "fontValidationFileHashes": sorted(held_files),
              "handwritingValidationPartitionSHA256ByCandidate": {
                  candidate["name"]: sha256(args.font_hand_partition[index])
                  for index, candidate in enumerate(candidate_parts)
              },
              "candidatePartitions": candidate_parts}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"output": str(args.output), "candidates": [
        {"name": c["name"], "subsetCount": c["subsetCount"], "multiMemberSubsetCount": c["multiMemberSubsetCount"],
         "largestSubsetSize": c["largestSubsetSize"], "cleanTop1": c["cleanAndDegradedFontMetrics"]["clean"]["top1"],
         "cleanTop5": c["cleanAndDegradedFontMetrics"]["clean"]["top5"]} for c in candidate_parts]}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
