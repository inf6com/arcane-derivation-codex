#!/usr/bin/env python3
"""Evaluate held-out direct anchors for the MPS Hinotori retrieval model."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import io
import json
import os
import torch.nn.functional as F
from pathlib import Path

import torch

from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_model import HinotoriRetrievalModel
from hinotori_retrieval import class_retrieval_logits
from hinotori_position_candidate_ranking import add_position_rankings
from hinotori_symbol_similarity_expansion import add_similarity_expansions, direct_similarity_labels
from train_hinotori_retrieval import class_complete_bank


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--candidate-records", type=Path, help="Write source-linked model rankings for later context evaluation")
    parser.add_argument("--mean-anchor-score", action="store_true", help="Experimental class-count normalization; evaluation only")
    parser.add_argument("--batch-size", type=int, default=128)
    args = parser.parse_args()
    if args.batch_size < 1:
        raise ValueError("batch-size must be positive")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required for Hinotori evaluation and is unavailable")
    if not args.checkpoint.is_file():
        raise FileNotFoundError(f"evaluation checkpoint is missing: {args.checkpoint}")
    if args.report.exists():
        raise FileExistsError(f"refusing to overwrite evaluation report: {args.report}")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    checkpoint_artifact = args.report.with_name(f"{args.report.stem}.checkpoint.pt")
    if checkpoint_artifact.exists():
        raise FileExistsError(f"refusing to overwrite retained checkpoint: {checkpoint_artifact}")
    checkpoint_bytes = args.checkpoint.read_bytes()
    checkpoint_sha256 = hashlib.sha256(checkpoint_bytes).hexdigest()
    checkpoint = torch.load(io.BytesIO(checkpoint_bytes), map_location="cpu", weights_only=False)
    if checkpoint.get("contract") != "hinotori-retrieval-v1" or checkpoint.get("mpsRequired") is not True:
        raise ValueError("checkpoint is not a Hinotori MPS training artifact")
    checkpoint_position = checkpoint.get("nextWeakPair")
    if not isinstance(checkpoint_position, int) or isinstance(checkpoint_position, bool) or checkpoint_position < 0:
        raise ValueError("checkpoint is missing a valid nextWeakPair")
    try:
        with checkpoint_artifact.open("xb") as artifact:
            artifact.write(checkpoint_bytes)
            artifact.flush()
            os.fsync(artifact.fileno())
    except BaseException:
        checkpoint_artifact.unlink(missing_ok=True)
        raise
    if hashlib.sha256(checkpoint_artifact.read_bytes()).hexdigest() != checkpoint_sha256:
        checkpoint_artifact.unlink(missing_ok=True)
        raise IOError("retained evaluation checkpoint hash differs from the evaluated input")
    model = HinotoriRetrievalModel().to("mps")
    model.load_state_dict(checkpoint["modelState"])
    model.eval()
    direct_path = args.teachers / "direct-symbol-teachers.jsonl"
    train = DirectAnchorDataset(direct_path, args.source_split, args.mathwriting_root, 32, "train")
    valid = DirectAnchorDataset(direct_path, args.source_split, args.mathwriting_root, 32, "valid")
    bank, bank_classes, _ = class_complete_bank(train)
    bank_classes = bank_classes.to("mps")
    correct = {1: 0, 2: 0, 3: 0, 5: 0}
    observed_classes: set[int] = set()
    confusion = Counter()
    candidate_records: list[dict[str, object]] = []
    class_labels = {int(row["classIndex"]): str(row["label"]) for row in train.rows}
    similarity_catalog_path = Path(__file__).with_name("HinotoriSymbolSimilarityGroups.json")
    similarity_families = {
        class_index: {
            index for index, candidate_label in class_labels.items()
            if candidate_label in direct_similarity_labels(label, similarity_catalog_path)
        }
        for class_index, label in class_labels.items()
    }
    similarity_family_correct = {1: 0, 2: 0, 3: 0, 5: 0}
    with torch.no_grad():
        anchors = model.encode_groups(bank)
        anchor_class_sums = torch.zeros((229, anchors.shape[1]), dtype=anchors.dtype, device=anchors.device)
        anchor_class_counts = torch.bincount(bank_classes, minlength=229).to(dtype=anchors.dtype)
        anchor_class_sums.index_add_(0, bank_classes, F.normalize(anchors, p=2, dim=1))
        class_prototypes = F.normalize(anchor_class_sums / anchor_class_counts.unsqueeze(1), p=2, dim=1)
        for start in range(0, len(valid), args.batch_size):
            samples = [valid[index] for index in range(start, min(start + args.batch_size, len(valid)))]
            groups = [sample["points"] for sample in samples]
            if not all(isinstance(group, torch.Tensor) for group in groups):
                raise ValueError("valid anchor points must be tensors")
            labels = torch.tensor([sample["classIndex"] for sample in samples], dtype=torch.int64, device="mps")
            observed_classes.update(labels.detach().cpu().tolist())
            query_embeddings = model.encode_groups(groups)
            logits = class_retrieval_logits(query_embeddings, anchors, bank_classes, 229, model.temperature)
            feature_distances = 1.0 - F.normalize(query_embeddings, p=2, dim=1) @ class_prototypes.transpose(0, 1)
            feature_distances = feature_distances.clamp(min=0.0, max=2.0)
            if args.mean_anchor_score:
                counts = torch.bincount(bank_classes, minlength=229).to(dtype=logits.dtype)
                logits = logits - counts.log().unsqueeze(0)
            ranked = logits.argsort(dim=1, descending=True)
            if args.candidate_records is not None:
                for sample, ordering, distances in zip(samples, ranked.detach().cpu().tolist(), feature_distances.detach().cpu().tolist()):
                    candidate_records.append({"sourceSampleId": sample["sourceSampleId"], "strokeIndices": sample["strokeIndices"], "targetClassIndex": sample["classIndex"], "modelCandidateClassIndices": ordering, "classFeatureDistances": distances, "featureDistanceContract": "query-to-class-centroid-cosine-distance-v1"})
            for sample, predicted in zip(samples, ranked[:, 0].detach().cpu().tolist()):
                actual = int(sample["classIndex"])
                confusion[(actual, predicted)] += 1
            for count in correct:
                correct[count] += int((ranked[:, :count] == labels.unsqueeze(1)).any(dim=1).sum().item())
            similarity_rankings = ranked.detach().cpu().tolist()
            for row, sample in enumerate(samples):
                family = similarity_families[int(sample["classIndex"])]
                predicted = similarity_rankings[row]
                for count in similarity_family_correct:
                    similarity_family_correct[count] += int(bool(family.intersection(predicted[:count])))
    report = {"contract": "hinotori-retrieval-v1", "mode": "MPS_HELD_OUT_DIRECT_ANCHOR_EVALUATION", "checkpointPath": str(args.checkpoint), "checkpointArtifact": str(checkpoint_artifact), "checkpointSHA256": checkpoint_sha256, "checkpointNextWeakPair": checkpoint_position, "mpsBuilt": True, "mpsAvailable": True, "validAnchorCount": len(valid), "validObservedClassCount": len(observed_classes), "validMissingClassCount": 229 - len(observed_classes), "top1": correct[1] / len(valid), "top2": correct[2] / len(valid), "top3": correct[3] / len(valid), "top5": correct[5] / len(valid)}
    report["similarityFamilyAgreement"] = {
        f"top{count}": similarity_family_correct[count] / len(valid)
        for count in similarity_family_correct
    }
    report["similarityFamilyAgreementContract"] = "A prediction in a directly shared catalog group is counted as similarity agreement only; overlapping groups are not traversed transitively. Exact-label metrics above remain authoritative for the 229 distinct symbol classes; similarity does not merge labels or MathML output."
    report["anchorScoreNormalization"] = "class-mean" if args.mean_anchor_score else "class-sum"
    report["confusion"] = [{"actualClass": actual, "actualLabel": class_labels[actual], "predictedClass": predicted, "predictedLabel": class_labels[predicted], "count": count} for (actual, predicted), count in confusion.most_common()]
    if args.candidate_records is not None:
        vocabulary_path = (
            Path(__file__).resolve().parent.parent
            / "Models"
            / "Hinotori"
            / "Fold07StrokeSetEmbeddingV2"
            / "HinotoriVocabulary.json"
        )
        vocabulary = json.loads(vocabulary_path.read_text(encoding="utf-8"))
        if vocabulary.get("labels") != [class_labels[index] for index in range(229)]:
            raise ValueError("packaged Hinotori vocabulary does not match the evaluated teacher class order")
        similarity_candidate_records = add_similarity_expansions(
            candidate_records,
            vocabulary_path,
            Path(__file__).with_name("HinotoriSymbolSimilarityGroups.json"),
        )
        position_candidate_records = add_position_rankings(
            similarity_candidate_records,
            direct_path,
            args.source_split,
            args.mathwriting_root,
            vocabulary_path,
            Path(__file__).with_name("HinotoriPositionSensitiveSubset.json"),
        )
        args.candidate_records.parent.mkdir(parents=True, exist_ok=True)
        with args.candidate_records.open("x", encoding="utf-8") as output:
            for record in position_candidate_records:
                output.write(json.dumps(record, ensure_ascii=False) + "\n")
        similarity_supplements = [candidate for record in position_candidate_records for candidate in record["similaritySupplementCandidates"]]
        similarity_added_targets = sum(
            record["targetClassIndex"] in record["similaritySupplementCandidateClassIndices"]
            and record["targetClassIndex"] not in record["similarityExpansionInputCandidateClassIndices"]
            for record in position_candidate_records
        )
        report["shapeSimilarityExpansion"] = {
            "ruleVersion": "hinotori-symbol-similarity-v3",
            "coordinateIndependent": True,
            "records": len(position_candidate_records),
            "supplementCandidateCount": len(similarity_supplements),
            "recordsWithSupplements": sum(bool(record["similaritySupplementCandidates"]) for record in position_candidate_records),
            "correctTargetsAddedToDisplayedChoiceSet": similarity_added_targets,
            "note": "Similarity alternatives are generated from the model's displayed labels and the fixed Hinotori vocabulary before source coordinates are read. They receive no displayed model score.",
        }
        report["positionSensitiveCandidateRanking"] = {
            "ruleVersion": "hinotori-position-rules-v1",
            "recordCount": len(position_candidate_records),
            "contextRecordCount": sum(record["positionContextInstanceCount"] > 1 for record in position_candidate_records),
            "overlappingSourceRecordCount": sum(record["positionContextStatus"] == "overlapping-direct-groups-excluded" for record in position_candidate_records),
            "conditionalOnDirectSymbolSegmentation": True,
            "sourceCoordinateSpace": "MathWriting-InkML-raw-X-right-Y-down",
            "note": "This candidate artifact is position-rule ordered; top-k metrics above remain shape-model-only. Position-rule effects require evaluate_position_sensitive_ranking.py on this artifact.",
        }
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
