#!/usr/bin/env python3
"""Train a font-only auxiliary output head on a frozen Fold-07 encoder.

The handwritten classifier is never updated. Font files, not glyph rows,
define fit/validation splits. The auxiliary head is evaluated on disjoint font
files and its candidate union is measured on Fold-07 inner-validation
handwriting. Training requires MPS; there is no CPU fallback.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
from pathlib import Path

import numpy as np
import torch
from torch import Tensor, nn
from torch.utils.data import DataLoader, TensorDataset

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ModelConversion"))
from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_raster_classifier import HinotoriStrokeSetClassifier
from train_hinotori_raster_classifier import collate_stroke_set, model_forward


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class FontBank(torch.utils.data.Dataset):
    def __init__(self, rows: list[dict], bank_path: Path, image_count: int,
                 font_hashes: set[str], split: str):
        self.rows = [row for row in rows if row["fontFileSHA256"] in font_hashes]
        if not self.rows:
            raise ValueError(f"typeset {split} font partition contains no glyphs")
        self.bank = np.memmap(bank_path, mode="r", dtype=np.uint8,
                              shape=(image_count, 64, 64))

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> tuple[Tensor, int]:
        row = self.rows[index]
        grayscale = np.array(self.bank[int(row["imageIndex"])], copy=True)
        if grayscale.shape != (64, 64) or grayscale.dtype != np.uint8:
            raise ValueError(f"invalid typeset raster at imageIndex={row['imageIndex']}")
        # The authoritative bank stores antialiased UInt8 grayscale with white
        # ink on zero background. Threshold to the binary ink contract used by
        # the frozen Fold-07 classifier; do not mistake 0...255 for 0...1.
        image = (grayscale >= 128).astype(np.float32)
        return torch.from_numpy(image).unsqueeze(0), int(row["vocabularyIndex"])


def raster_embeddings(model: HinotoriStrokeSetClassifier, images: Tensor) -> Tensor:
    raster_map = model.raster_features(images)
    pooled = torch.cat((nn.functional.adaptive_avg_pool2d(raster_map, 1).flatten(1),
                        nn.functional.adaptive_max_pool2d(raster_map, 1).flatten(1)), dim=1)
    return model.raster_projection(pooled)


def cache_font_embeddings(model: HinotoriStrokeSetClassifier, loader: DataLoader,
                           device: torch.device) -> tuple[Tensor, Tensor]:
    embeddings: list[Tensor] = []
    labels: list[Tensor] = []
    model.eval()
    with torch.inference_mode():
        for batch in loader:
            images, targets = batch[0], batch[1]
            images = images.to(device)
            embeddings.append(raster_embeddings(model, images).float().cpu())
            labels.append(targets.cpu().long())
    return torch.cat(embeddings), torch.cat(labels)


def fit_font_head(head: nn.Linear, embeddings: Tensor, global_labels: Tensor,
                  valid_embeddings: Tensor, valid_labels: Tensor, supported_indices: list[int], *,
                  epochs: int, batch_size: int, learning_rate: float, seed: int,
                  device: torch.device) -> tuple[list[dict], dict[str, Tensor], dict[str, Tensor]]:
    class_to_local = {label: i for i, label in enumerate(supported_indices)}
    local_labels = torch.tensor([class_to_local[int(x)] for x in global_labels.tolist()], dtype=torch.long)
    dataset = TensorDataset(embeddings, local_labels)
    generator = torch.Generator().manual_seed(seed)
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=True, generator=generator)
    weights = torch.bincount(local_labels, minlength=len(supported_indices)).float().clamp_min(1).pow(-0.5)
    weights /= weights.mean()
    optimizer = torch.optim.AdamW(head.parameters(), lr=learning_rate, weight_decay=1e-2)
    history: list[dict] = []
    best_top1 = (-1.0, None)
    best_top5 = (-1.0, None)
    for epoch in range(1, epochs + 1):
        head.train()
        total_loss = 0.0
        total = 0
        for features, targets in loader:
            features, targets = features.to(device), targets.to(device)
            optimizer.zero_grad(set_to_none=True)
            logits = head(features)
            loss = nn.functional.cross_entropy(logits, targets, weight=weights.to(device))
            loss.backward()
            optimizer.step()
            total_loss += float(loss.detach().item()) * targets.numel()
            total += targets.numel()
        valid_metrics = evaluate_font_head(head, valid_embeddings, valid_labels, supported_indices)
        row = {"epoch": epoch, "fitLoss": total_loss / total,
               "heldOutFontTop1": valid_metrics["top1"], "heldOutFontTop5": valid_metrics["top5"]}
        history.append(row)
        state = {key: value.detach().cpu().clone() for key, value in head.state_dict().items()}
        if valid_metrics["top1"] > best_top1[0]:
            best_top1 = (valid_metrics["top1"], state)
        if valid_metrics["top5"] > best_top5[0]:
            best_top5 = (valid_metrics["top5"], state)
    if best_top1[1] is None or best_top5[1] is None:
        raise RuntimeError("no held-out-font checkpoint was selected")
    return history, best_top1[1], best_top5[1]


def evaluate_font_head(head: nn.Linear, embeddings: Tensor, global_labels: Tensor,
                       supported_indices: list[int]) -> dict:
    class_to_local = {label: i for i, label in enumerate(supported_indices)}
    keep = torch.tensor([int(label) in class_to_local for label in global_labels], dtype=torch.bool)
    if not keep.any():
        raise ValueError("held-out evaluation has no labels supported by the typeset head")
    device = head.weight.device
    local_targets = torch.tensor([class_to_local[int(x)] for x in global_labels[keep]], dtype=torch.long, device=device)
    logits = head(embeddings[keep].to(device))
    k = min(5, logits.shape[1])
    return {
        "evaluatedExamples": int(keep.sum()),
        "excludedUnsupportedExamples": int((~keep).sum()),
        "top1": float((logits.argmax(1) == local_targets).float().mean()),
        "top5": float((logits.topk(k, dim=1).indices == local_targets[:, None]).any(1).float().mean()),
        "candidateCount": k,
    }


def handwriting_candidate_metrics(head: nn.Linear, embeddings: Tensor, labels: Tensor,
                                  primary_logits: Tensor, supported_indices: list[int]) -> dict:
    local_to_global = torch.tensor(supported_indices, dtype=torch.long)
    aux_top5_global = local_to_global[head(embeddings).topk(k=min(5, len(supported_indices)), dim=1).indices]
    primary_top5 = primary_logits.topk(5, dim=1).indices
    primary_top1 = primary_logits.argmax(1)
    union = torch.cat((primary_top5, aux_top5_global), dim=1)
    base_hit = (primary_top5 == labels[:, None]).any(1)
    union_hit = (union == labels[:, None]).any(1)
    aux_hit = (aux_top5_global == labels[:, None]).any(1)
    return {
        "examples": int(labels.numel()),
        "primaryTop1": float((primary_top1 == labels).float().mean()),
        "primaryTop5Coverage": float(base_hit.float().mean()),
        "typesetHeadTop5Coverage": float(aux_hit.float().mean()),
        "unionTop10Coverage": float(union_hit.float().mean()),
        "newlyRecoveredByTypesetHead": int((union_hit & ~base_hit).sum()),
        "meanUniqueUnionCandidates": float(torch.tensor([
            torch.unique(torch.cat((primary_top5[i], aux_top5_global[i]))).numel()
            for i in range(labels.numel())
        ], dtype=torch.float32).mean()),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, default=Path("runs/hinotori-raster-holdout-v2-20261103/fold-07/stroke-set/best.pt"))
    parser.add_argument("--font-manifest", type=Path, default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json"))
    parser.add_argument("--font-bank", type=Path, default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.u8"))
    parser.add_argument("--font-split-report", type=Path, default=Path("runs/agent-control/cycle630-firebird-pair-overlap-aug-v3/training-report.json"))
    parser.add_argument("--fit-teachers", type=Path, default=Path("runs/hinotori-raster-holdout-v2-20261103/fold-07/fit-teachers.jsonl"))
    parser.add_argument("--source-split", type=Path, default=Path("runs/hinotori-raster-holdout-v2-20261103/fold-07/fit-source-split.json"))
    parser.add_argument("--dataset-root", type=Path, default=Path("/Volumes/ORICO/Developer/inf6-training/dataset/mathwriting-2024"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=512)
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--seed", type=int, default=20261105)
    args = parser.parse_args()
    for path in (args.checkpoint, args.font_manifest, args.font_bank, args.font_split_report,
                 args.fit_teachers, args.source_split, args.dataset_root / "train"):
        if not path.exists():
            raise FileNotFoundError(path)
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite run directory: {args.output}")
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is unavailable; refusing to train outside the contracted Mac training device")
    device = torch.device("mps")
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    torch.mps.manual_seed(args.seed)

    checkpoint_bytes = args.checkpoint.read_bytes()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    run = checkpoint.get("run", {})
    if run.get("architecture") != "HinotoriStrokeSetClassifier" or run.get("task") != "isolated_symbol_exact_classification":
        raise ValueError("checkpoint must be the selected Fold-07 229-symbol stroke-set classifier")
    labels = run.get("classLabelsByIndex")
    if not isinstance(labels, list) or len(labels) != 229 or len(set(labels)) != 229:
        raise ValueError("checkpoint does not carry the exact ordered 229-label vocabulary")
    label_to_index = {label: index for index, label in enumerate(labels)}

    font_manifest_bytes = args.font_manifest.read_bytes()
    font_manifest = json.loads(font_manifest_bytes)
    font_split_bytes = args.font_split_report.read_bytes()
    font_split = json.loads(font_split_bytes)
    if font_manifest.get("schema") != "firebird-mac-font-glyph-raster-v1":
        raise ValueError("unexpected typeset glyph corpus schema")
    if font_manifest.get("vocabularySHA256") != run.get("vocabularySHA256"):
        raise ValueError("font corpus vocabulary differs from Fold-07 ordered vocabulary")
    if font_split.get("corpusManifestSHA256") != hashlib.sha256(font_manifest_bytes).hexdigest():
        raise ValueError("font split report was made from a different corpus manifest")
    fit_hashes, valid_hashes = set(font_split["fitFontFiles"]), set(font_split["validationFontFiles"])
    if fit_hashes & valid_hashes or not fit_hashes or not valid_hashes:
        raise ValueError("fit and validation font-file partitions overlap or are empty")

    corpus_rows = font_manifest["rows"]
    if len(corpus_rows) != int(font_manifest["renderedImageCount"]):
        raise ValueError("font manifest row count disagrees with rendered image count")
    if args.font_bank.stat().st_size != len(corpus_rows) * 64 * 64:
        raise ValueError("font raster bank byte size does not match its manifest")
    eligible_rows = []
    for row in corpus_rows:
        index = int(row["vocabularyIndex"])
        if not 0 <= index < 229 or labels[index] != row["label"]:
            raise ValueError(f"font glyph label/index mismatch at imageIndex={row['imageIndex']}")
        if row.get("kind") != "unicode-glyph":
            continue
        eligible_rows.append(row)
    supported_indices = sorted({int(row["vocabularyIndex"]) for row in eligible_rows})
    if len(supported_indices) < 2:
        raise ValueError("typeset corpus must support at least two verified symbol classes")

    fit_dataset = FontBank(eligible_rows, args.font_bank, len(corpus_rows), fit_hashes, "fit")
    valid_dataset = FontBank(eligible_rows, args.font_bank, len(corpus_rows), valid_hashes, "validation")
    fit_loader = DataLoader(fit_dataset, batch_size=args.batch_size, shuffle=False)
    valid_loader = DataLoader(valid_dataset, batch_size=args.batch_size, shuffle=False)

    model = HinotoriStrokeSetClassifier().to(device)
    model.load_state_dict(checkpoint["model"], strict=True)
    model.eval()
    for parameter in model.parameters():
        parameter.requires_grad_(False)
    fit_embeddings, fit_labels = cache_font_embeddings(model, fit_loader, device)
    valid_embeddings, valid_labels = cache_font_embeddings(model, valid_loader, device)
    head = nn.Linear(128, len(supported_indices)).to(device)
    history, best_top1_state, best_top5_state = fit_font_head(
        head, fit_embeddings, fit_labels, valid_embeddings, valid_labels, supported_indices,
        epochs=args.epochs, batch_size=args.batch_size,
        learning_rate=args.learning_rate, seed=args.seed, device=device)
    head.load_state_dict(best_top1_state)
    head.eval()
    valid_head = evaluate_font_head(head.cpu(), valid_embeddings, valid_labels, supported_indices)
    valid_head["distinctFontFiles"] = len(valid_hashes)

    handwriting_data = DirectAnchorDataset(args.fit_teachers, args.source_split, args.dataset_root, 128, "valid")
    handwriting_loader = DataLoader(handwriting_data, batch_size=128, shuffle=False, collate_fn=collate_stroke_set)
    handwriting_embeddings: list[Tensor] = []
    handwriting_labels: list[Tensor] = []
    handwriting_logits: list[Tensor] = []
    model.eval()
    with torch.inference_mode():
        for inputs, targets, _ in handwriting_loader:
            device_inputs = tuple(value.to(device) for value in inputs)
            primary_logits, _ = model_forward(model, device_inputs)
            handwriting_embeddings.append(raster_embeddings(model, device_inputs[0]).float().cpu())
            handwriting_labels.append(targets.long())
            handwriting_logits.append(primary_logits.float().cpu())
    handwriting_embeddings = torch.cat(handwriting_embeddings)
    handwriting_labels = torch.cat(handwriting_labels)
    handwriting_logits = torch.cat(handwriting_logits)
    handwritten_union = handwriting_candidate_metrics(head.cpu(), handwriting_embeddings,
                                                         handwriting_labels, handwriting_logits,
                                                         supported_indices)
    primary_after_parts: list[Tensor] = []
    with torch.inference_mode():
        for inputs, _, _ in handwriting_loader:
            primary_after, _ = model_forward(model, tuple(value.to(device) for value in inputs))
            primary_after_parts.append(primary_after.float().cpu())
    primary_after = torch.cat(primary_after_parts)
    if not torch.equal(handwriting_logits, primary_after):
        raise RuntimeError("primary logits changed between independent pre/post auxiliary-head inference passes")

    args.output.mkdir(parents=True)
    head_checkpoint = {
        "state_dict": {key: value.detach().cpu() for key, value in head.state_dict().items()},
        "supportedVocabularyIndices": supported_indices,
        "baseCheckpointSHA256": hashlib.sha256(checkpoint_bytes).hexdigest(),
        "fontManifestSHA256": hashlib.sha256(font_manifest_bytes).hexdigest(),
        "fitFontHashes": sorted(fit_hashes),
        "validationFontHashes": sorted(valid_hashes),
        "primaryModelParametersUpdated": False,
    }
    torch.save(head_checkpoint, args.output / "typeset-head-best-top1.pt")
    top5_checkpoint = dict(head_checkpoint)
    top5_checkpoint["state_dict"] = best_top5_state
    torch.save(top5_checkpoint, args.output / "typeset-head-best-top5.pt")
    head.load_state_dict(best_top5_state)
    top5_font_metrics = evaluate_font_head(head.cpu(), valid_embeddings, valid_labels, supported_indices)
    top5_font_metrics["distinctFontFiles"] = len(valid_hashes)
    top5_handwriting_union = handwriting_candidate_metrics(head, handwriting_embeddings,
                                                             handwriting_labels, handwriting_logits,
                                                             supported_indices)
    result = {
        "schema": "hinotori-typeset-auxiliary-head-experiment-v1",
        "task": "parallel candidate head for verified standalone typeset glyphs",
        "primaryClassifierChanged": False,
        "baseCheckpoint": str(args.checkpoint),
        "baseCheckpointSHA256": hashlib.sha256(checkpoint_bytes).hexdigest(),
        "fontManifest": str(args.font_manifest),
        "fontManifestSHA256": hashlib.sha256(font_manifest_bytes).hexdigest(),
        "fontSplitReport": str(args.font_split_report),
        "fontSplitReportSHA256": hashlib.sha256(font_split_bytes).hexdigest(),
        "trainingScriptSHA256": sha256(Path(__file__).resolve()),
        "fontFitFileCount": len(fit_hashes),
        "fontValidationFileCount": len(valid_hashes),
        "typesetGlyphFitCount": len(fit_dataset),
        "typesetGlyphValidationCount": len(valid_dataset),
        "supportedLabelCount": len(supported_indices),
        "unsupportedLabels": [labels[i] for i in range(229) if i not in supported_indices],
        "training": {"epochs": args.epochs, "batchSize": args.batch_size,
                     "learningRate": args.learning_rate, "device": str(device),
                     "frozen": "Fold-07 StrokeSet raster feature branch, raster projection, trajectory branch, fused embedding, and original 229-class output",
                     "auxiliaryInput": "frozen image-only raster projection (128 dimensions)"},
        "heldOutFonts": valid_head,
        "fold07InnerValidHandwritingCandidateCoverage": handwritten_union,
        "primaryLogitsBitwiseEqualBeforeAfterAuxiliaryScoring": True,
        "bestTop5HeldOutFonts": top5_font_metrics,
        "bestTop5Fold07InnerValidHandwritingCandidateCoverage": top5_handwriting_union,
        "history": history,
        "outerTestOpened": False,
        "interpretation": "Auxiliary candidate coverage only; it does not alter primary exact-class logits or claim corrected predictions.",
    }
    (args.output / "metrics.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    (args.output / "font-split.json").write_text(json.dumps({
        "schema": "hinotori-typeset-font-file-split-v1",
        "fitFontFileSHA256": sorted(fit_hashes),
        "validationFontFileSHA256": sorted(valid_hashes),
        "sourceSplitReportSHA256": hashlib.sha256(font_split_bytes).hexdigest(),
        "corpusManifestSHA256": hashlib.sha256(font_manifest_bytes).hexdigest(),
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    (args.output / "label-map.json").write_text(json.dumps({"supportedVocabularyIndices": supported_indices,
                                                             "labels": [labels[i] for i in supported_indices]},
                                                            ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"heldOutFonts": valid_head,
                      "innerValidHandwritingCandidateCoverage": handwritten_union,
                      "bestTop5HeldOutFonts": top5_font_metrics,
                      "bestTop5InnerValidHandwritingCandidateCoverage": top5_handwriting_union}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
