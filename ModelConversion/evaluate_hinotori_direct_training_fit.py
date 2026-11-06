#!/usr/bin/env python3
"""Measure Hinotori fit on every official direct training teacher.

Reports both the literal training-bank resubstitution result and leave-one-out
retrieval. The former includes each query as an exemplar and is explicitly not
an independent accuracy estimate. Leave-one-out omits singleton classes because
removing their only exemplar makes a 229-way result undefined.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path

import torch
import torch.nn.functional as F

from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_model import HinotoriRetrievalModel
from hinotori_retrieval import class_retrieval_logits
from hinotori_symbol_similarity_expansion import direct_similarity_labels


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def ranking_counts(ranking: list[int], target: int, similar: set[int]) -> tuple[int, int, int, int]:
    return (
        int(ranking[0] == target),
        int(target in ranking[:2]),
        int(target in ranking[:3]),
        int(target in ranking[:5]),
    ), (
        int(bool(similar.intersection(ranking[:1]))),
        int(bool(similar.intersection(ranking[:2]))),
        int(bool(similar.intersection(ranking[:3]))),
        int(bool(similar.intersection(ranking[:5]))),
    )


def class_logits_excluding_self(
    queries: torch.Tensor,
    anchors: torch.Tensor,
    anchor_classes: torch.Tensor,
    row_indices: torch.Tensor,
    class_count: int,
    temperature: float,
) -> torch.Tensor:
    if queries.shape[0] != row_indices.shape[0] or anchors.shape[0] != anchor_classes.shape[0]:
        raise ValueError("leave-one-out query and retrieval-bank rows are inconsistent")
    similarity = F.normalize(queries, p=2, dim=1) @ F.normalize(anchors, p=2, dim=1).transpose(0, 1)
    similarity[torch.arange(len(row_indices), device=similarity.device), row_indices] = float("-inf")
    logits = torch.empty((queries.shape[0], class_count), dtype=similarity.dtype, device=similarity.device)
    for class_index in range(class_count):
        selected = anchor_classes == class_index
        if not selected.any():
            raise ValueError(f"leave-one-out retrieval bank is missing class {class_index}")
        logits[:, class_index] = torch.logsumexp(similarity[:, selected] / temperature, dim=1)
    return logits


def metric_summary(rows: list[dict[str, object]], prefix: str, labels: dict[int, str]) -> dict[str, object]:
    eligible = [row for row in rows if row.get(f"{prefix}Ranking") is not None]
    if not eligible:
        raise ValueError(f"no eligible {prefix} rankings")
    counts = [0, 0, 0, 0]
    similar_counts = [0, 0, 0, 0]
    confusion: Counter[tuple[int, int]] = Counter()
    class_counts: Counter[int] = Counter()
    class_correct: Counter[int] = Counter()
    for row in eligible:
        target = int(row["targetClassIndex"])
        ranking = row[f"{prefix}Ranking"]
        if not isinstance(ranking, list) or len(ranking) != 229:
            raise ValueError(f"invalid {prefix} ranking")
        hit, similar_hit = ranking_counts(ranking, target, set(row["similarClassIndices"]))
        counts = [total + value for total, value in zip(counts, hit)]
        similar_counts = [total + value for total, value in zip(similar_counts, similar_hit)]
        confusion[(target, ranking[0])] += 1
        class_counts[target] += 1
        class_correct[target] += hit[0]
    size = len(eligible)
    return {
        "count": size,
        "top1": counts[0] / size,
        "top2": counts[1] / size,
        "top3": counts[2] / size,
        "top5": counts[3] / size,
        "similarFamilyAgreementTop1": similar_counts[0] / size,
        "similarFamilyAgreementTop2": similar_counts[1] / size,
        "similarFamilyAgreementTop3": similar_counts[2] / size,
        "similarFamilyAgreementTop5": similar_counts[3] / size,
        "perClass": [
            {"classIndex": index, "label": labels[index], "count": class_counts[index],
             "top1Correct": class_correct[index],
             "top1Accuracy": class_correct[index] / class_counts[index] if class_counts[index] else None}
            for index in range(229)
        ],
        "confusion": [
            {"actualClassIndex": actual, "actualLabel": labels[actual],
             "predictedClassIndex": predicted, "predictedLabel": labels[predicted], "count": count}
            for (actual, predicted), count in confusion.most_common()
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=64)
    args = parser.parse_args()
    if args.batch_size < 1:
        raise ValueError("batch-size must be positive")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required for Hinotori direct-teacher evaluation")
    direct_path = args.teachers / "direct-symbol-teachers.jsonl"
    for path in (direct_path, args.source_split, args.checkpoint):
        if not path.is_file():
            raise FileNotFoundError(f"required evaluation input is missing: {path}")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    report_path = args.output_dir / "report.json"
    predictions_path = args.output_dir / "predictions.jsonl"
    if report_path.exists() or predictions_path.exists():
        raise FileExistsError("direct training-fit output already exists; refusing to overwrite evidence")

    dataset = DirectAnchorDataset(direct_path, args.source_split, args.mathwriting_root, 32, "train")
    labels_by_class = {int(row["classIndex"]): str(row["label"]) for row in dataset.rows}
    if set(labels_by_class) != set(range(229)):
        raise ValueError("direct training teachers do not cover exactly 229 classes")
    class_counts = Counter(int(row["classIndex"]) for row in dataset.rows)
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    if checkpoint.get("contract") != "hinotori-retrieval-v1" or checkpoint.get("mpsRequired") is not True:
        raise ValueError("checkpoint is not a Hinotori MPS training artifact")
    model = HinotoriRetrievalModel().to("mps")
    model.load_state_dict(checkpoint["modelState"], strict=True)
    model.eval()

    groups = [dataset[index]["points"] for index in range(len(dataset))]
    anchor_classes = torch.tensor([int(row["classIndex"]) for row in dataset.rows], dtype=torch.int64, device="mps")
    embedding_parts: list[torch.Tensor] = []
    with torch.inference_mode():
        for start in range(0, len(groups), args.batch_size):
            embedding_parts.append(model.encode_groups(groups[start:start + args.batch_size]))
    embeddings = torch.cat(embedding_parts, dim=0)
    if embeddings.shape[0] != len(dataset) or not torch.isfinite(embeddings).all():
        raise ValueError("direct training embedding bank is incomplete or non-finite")
    catalog_path = Path(__file__).with_name("HinotoriSymbolSimilarityGroups.json")
    similar_by_class = {
        class_index: {
            index for index, candidate_label in labels_by_class.items()
            if candidate_label in direct_similarity_labels(labels_by_class[class_index], catalog_path)
        }
        for class_index in range(229)
    }

    staged: list[dict[str, object]] = []
    with torch.inference_mode():
        for start in range(0, len(dataset), args.batch_size):
            end = min(start + args.batch_size, len(dataset))
            indices = torch.arange(start, end, dtype=torch.int64, device="mps")
            query = embeddings[start:end]
            full_logits = class_retrieval_logits(query, embeddings, anchor_classes, 229, model.temperature)
            loo_logits = class_logits_excluding_self(query, embeddings, anchor_classes, indices, 229, model.temperature)
            full_ranked = full_logits.argsort(dim=1, descending=True).detach().cpu().tolist()
            loo_ranked = loo_logits.argsort(dim=1, descending=True).detach().cpu().tolist()
            for offset, dataset_index in enumerate(range(start, end)):
                target = int(dataset.rows[dataset_index]["classIndex"])
                staged.append({
                    "datasetIndex": dataset_index,
                    "sourceSampleId": dataset.rows[dataset_index]["sourceSampleId"],
                    "strokeIndices": dataset.rows[dataset_index]["strokeIndices"],
                    "targetClassIndex": target,
                    "similarClassIndices": sorted(similar_by_class[target]),
                    "trainingBankResubstitutionRanking": full_ranked[offset],
                    "leaveOneOutRanking": loo_ranked[offset] if class_counts[target] > 1 else None,
                })

    manifest = {
        "contract": "hinotori-direct-training-fit-v1",
        "checkpointSHA256": sha256(args.checkpoint),
        "directTeacherSHA256": sha256(direct_path),
        "sourceSplitSHA256": sha256(args.source_split),
        "similarityCatalogSHA256": sha256(catalog_path),
        "trainingDirectTeacherCount": len(dataset),
        "classCount": 229,
        "singletonTrainingClassCount": sum(count == 1 for count in class_counts.values()),
        "checkpointNextWeakPair": checkpoint.get("nextWeakPair"),
    }
    with predictions_path.open("x", encoding="utf-8") as output:
        for row in staged:
            output.write(json.dumps(row, ensure_ascii=False) + "\n")
        output.flush()
        os.fsync(output.fileno())
    report = {
        **manifest,
        "status": "COMPLETED",
        "trainingBankResubstitution": metric_summary(staged, "trainingBankResubstitution", labels_by_class),
        "leaveOneOut": metric_summary(staged, "leaveOneOut", labels_by_class),
        "leaveOneOutExcludedSingletonCount": sum(count == 1 for count in class_counts.values()),
        "leaveOneOutExcludedSingletonClasses": [
            {"classIndex": index, "label": labels_by_class[index]}
            for index, count in sorted(class_counts.items()) if count == 1
        ],
        "interpretation": "Both measurements use the model's complete direct-training exemplar bank. Training-bank resubstitution includes each query as its own candidate and is explicitly an optimistic memorization-fit upper bound. Leave-one-out removes each query exemplar; three singleton-class queries are undefined for a complete 229-way ranking and are reported excluded. Both are in-sample training-fit measurements, not held-out generalization. Similar-family agreement is a separately reported catalog relation and does not merge class labels or alter exact ranking.",
        "predictionArtifact": str(predictions_path),
    }
    temporary_report = report_path.with_suffix(".json.tmp")
    with temporary_report.open("x", encoding="utf-8") as output:
        output.write(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary_report, report_path)
    print(json.dumps({
        "trainingBankResubstitution": {key: report["trainingBankResubstitution"][key] for key in ("count", "top1", "top5", "similarFamilyAgreementTop5")},
        "leaveOneOut": {key: report["leaveOneOut"][key] for key in ("count", "top1", "top5", "similarFamilyAgreementTop5")},
        "leaveOneOutExcludedSingletonCount": report["leaveOneOutExcludedSingletonCount"],
        "report": str(report_path),
    }, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
