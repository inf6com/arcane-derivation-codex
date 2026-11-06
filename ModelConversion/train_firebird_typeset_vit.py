#!/usr/bin/env python3
"""Train a font-family-held-out ViT over the measured Mac typeset-glyph corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import time
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader, TensorDataset, WeightedRandomSampler


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--images", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--vocabulary", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--epochs", type=int, default=12)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--seed", type=int, default=2292026)
    return parser.parse_args()


class FontGlyphViT(nn.Module):
    def __init__(self, class_count: int) -> None:
        super().__init__()
        width = 128
        self.patch = nn.Conv2d(1, width, kernel_size=8, stride=8, bias=True)
        self.class_token = nn.Parameter(torch.zeros(1, 1, width))
        self.position = nn.Parameter(torch.zeros(1, 65, width))
        layer = nn.TransformerEncoderLayer(
            d_model=width,
            nhead=4,
            dim_feedforward=width * 4,
            dropout=0.1,
            activation="gelu",
            batch_first=True,
            norm_first=True,
        )
        self.encoder = nn.TransformerEncoder(layer, num_layers=4, enable_nested_tensor=False)
        self.norm = nn.LayerNorm(width)
        self.head = nn.Linear(width, class_count)
        nn.init.trunc_normal_(self.class_token, std=0.02)
        nn.init.trunc_normal_(self.position, std=0.02)

    def encode(self, image: torch.Tensor) -> torch.Tensor:
        patches = self.patch(image).flatten(2).transpose(1, 2)
        cls = self.class_token.expand(image.shape[0], -1, -1)
        return self.norm(self.encoder(torch.cat((cls, patches), dim=1) + self.position)[:, 0])

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        return self.head(self.encode(image))


def family_file_split(rows: list[dict], class_ids: dict[int, int], seed: int) -> tuple[list[int], list[int], dict]:
    files_by_class: dict[int, set[str]] = defaultdict(set)
    rows_by_file: dict[str, list[int]] = defaultdict(list)
    for index, row in enumerate(rows):
        class_id = class_ids[row["vocabularyIndex"]]
        file_hash = row["fontFileSHA256"]
        files_by_class[class_id].add(file_hash)
        rows_by_file[file_hash].append(index)

    all_files = sorted(rows_by_file)
    ranked = sorted(all_files, key=lambda value: hashlib.sha256(f"{seed}:{value}".encode()).digest())
    validation_files = set(ranked[: max(1, round(len(ranked) * 0.2))])
    # A label represented by one source font cannot have disjoint fit and
    # validation evidence. Keep that font in fit and exclude the label from
    # held-out metrics instead of silently creating a validation-only class.
    single_source_files = {
        next(iter(file_hashes))
        for file_hashes in files_by_class.values()
        if len(file_hashes) == 1
    }
    validation_files.difference_update(single_source_files)
    # Keep every multi-file class represented on both sides; the font file is the split unit.
    for class_id, file_hashes in files_by_class.items():
        held = file_hashes & validation_files
        train = file_hashes - validation_files
        if len(file_hashes) >= 2 and not held:
            candidates = file_hashes - single_source_files
            if candidates:
                candidate = min(candidates, key=lambda value: hashlib.sha256(f"val:{seed}:{value}".encode()).digest())
                validation_files.add(candidate)
        elif len(file_hashes) >= 2 and not train:
            candidates = file_hashes - single_source_files
            if candidates:
                candidate = min(candidates, key=lambda value: hashlib.sha256(f"train:{seed}:{value}".encode()).digest())
                validation_files.discard(candidate)

    train_rows = [i for file_hash in all_files if file_hash not in validation_files for i in rows_by_file[file_hash]]
    validation_rows = [i for file_hash in all_files if file_hash in validation_files for i in rows_by_file[file_hash]]
    train_classes = {class_ids[rows[i]["vocabularyIndex"]] for i in train_rows}
    validation_classes = {class_ids[rows[i]["vocabularyIndex"]] for i in validation_rows}
    evaluated_classes = sorted(train_classes & validation_classes)
    split = {
        "splitUnit": "SHA256 of exact source font file; no file hash appears on both sides",
        "seed": seed,
        "validationFractionRequested": 0.2,
        "trainFontFileSHA256": sorted(set(rows[i]["fontFileSHA256"] for i in train_rows)),
        "validationFontFileSHA256": sorted(validation_files),
        "trainImageCount": len(train_rows),
        "validationImageCount": len(validation_rows),
        "trainClassCount": len(train_classes),
        "validationClassCount": len(validation_classes),
        "evaluatedClassCount": len(evaluated_classes),
    }
    unsupported = sorted({
        vocabulary_index for vocabulary_index, class_id in class_ids.items()
        if len(files_by_class[class_id]) == 1
    })
    split["singleFontFileVocabularyIndices"] = unsupported
    split["singleFontFileLabelsWithoutHeldOutEvidence"] = [
        {"vocabularyIndex": vocabulary_index, "label": next(row["label"] for row in rows if row["vocabularyIndex"] == vocabulary_index)}
        for vocabulary_index in unsupported
    ]
    split["evaluatedVocabularyIndices"] = [
        vocabulary_index for vocabulary_index, class_id in class_ids.items() if class_id in evaluated_classes
    ]
    return train_rows, validation_rows, split


def main() -> None:
    args = parse_args()
    if args.epochs < 1 or args.batch_size < 1 or not torch.backends.mps.is_available():
        raise RuntimeError("Positive epochs/batch size and an available MPS device are required; CPU fallback is prohibited.")
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device("mps")

    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    vocabulary_bytes = args.vocabulary.read_bytes()
    vocabulary = json.loads(vocabulary_bytes)["labels"]
    if len(vocabulary) != 229 or len(set(vocabulary)) != 229:
        raise ValueError("Expected the exact 229-label vocabulary.")
    if manifest.get("schema") != "firebird-mac-font-glyph-raster-v1" or manifest["width"] != 64 or manifest["height"] != 64:
        raise ValueError("Unexpected glyph corpus schema or image geometry.")
    if manifest["vocabularySHA256"] != hashlib.sha256(vocabulary_bytes).hexdigest():
        raise ValueError("Glyph corpus and current vocabulary hashes differ.")
    rows = manifest["rows"]
    expected = manifest["renderedImageCount"] * 64 * 64
    if len(rows) != manifest["renderedImageCount"] or args.images.stat().st_size != expected:
        raise ValueError("Raster count/size does not match the corpus manifest.")
    vocabulary_indices = sorted({row["vocabularyIndex"] for row in rows})
    if any(vocabulary[index] != label for index, label in {(row["vocabularyIndex"], row["label"]) for row in rows}):
        raise ValueError("Raster row label does not match the 229-label vocabulary index.")
    class_ids = {vocabulary_index: class_id for class_id, vocabulary_index in enumerate(vocabulary_indices)}
    train_rows, validation_rows, split = family_file_split(rows, class_ids, args.seed)
    if not train_rows or not validation_rows or split["evaluatedClassCount"] == 0:
        raise ValueError("Font-file split produced an empty training or validation partition.")

    raw = np.memmap(args.images, mode="r", dtype=np.uint8, shape=(len(rows), 64, 64))
    images = torch.from_numpy(np.array(raw, copy=True)).unsqueeze(1)
    targets = torch.tensor([class_ids[row["vocabularyIndex"]] for row in rows], dtype=torch.long)
    train_x, train_y = images[train_rows], targets[train_rows]
    validation_x, validation_y = images[validation_rows], targets[validation_rows]
    class_counts = torch.bincount(train_y, minlength=len(class_ids)).float()
    weights = 1.0 / class_counts[train_y].clamp_min(1.0)
    sampler = WeightedRandomSampler(weights, num_samples=len(train_rows), replacement=True,
                                    generator=torch.Generator().manual_seed(args.seed))
    train_loader = DataLoader(TensorDataset(train_x, train_y), batch_size=args.batch_size, sampler=sampler,
                              num_workers=0, pin_memory=False)
    validation_loader = DataLoader(TensorDataset(validation_x, validation_y), batch_size=args.batch_size,
                                   shuffle=False, num_workers=0, pin_memory=False)

    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "font-file-split.json").write_text(json.dumps(split, ensure_ascii=False, indent=2) + "\n")
    model = FontGlyphViT(len(class_ids)).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=3e-4, weight_decay=0.05)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    criterion = nn.CrossEntropyLoss(label_smoothing=0.05)
    class_rows = [{"classIndex": class_id, "vocabularyIndex": vocabulary_index, "label": vocabulary[vocabulary_index]}
                  for vocabulary_index, class_id in sorted(class_ids.items(), key=lambda item: item[1])]
    (args.output / "class-map.json").write_text(json.dumps(class_rows, ensure_ascii=False, indent=2) + "\n")
    history = []
    best_top1 = -1.0
    started = time.time()
    for epoch in range(1, args.epochs + 1):
        model.train()
        loss_sum = 0.0
        correct = 0
        seen = 0
        for batch_x, batch_y in train_loader:
            batch_x = batch_x.to(device=device, dtype=torch.float32).div_(255.0)
            batch_y = batch_y.to(device)
            optimizer.zero_grad(set_to_none=True)
            logits = model(batch_x)
            loss = criterion(logits, batch_y)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            loss_sum += loss.item() * batch_y.numel()
            correct += (logits.argmax(1) == batch_y).sum().item()
            seen += batch_y.numel()

        model.eval()
        all_targets, all_logits, validation_loss = [], [], 0.0
        with torch.no_grad():
            for batch_x, batch_y in validation_loader:
                batch_x = batch_x.to(device=device, dtype=torch.float32).div_(255.0)
                batch_y = batch_y.to(device)
                logits = model(batch_x)
                validation_loss += criterion(logits, batch_y).item() * batch_y.numel()
                all_targets.append(batch_y.cpu())
                all_logits.append(logits.cpu())
        expected_y = torch.cat(all_targets)
        logits = torch.cat(all_logits)
        top5 = logits.topk(min(5, logits.shape[1]), dim=1).indices
        exact = logits.argmax(1).eq(expected_y)
        top5_ok = top5.eq(expected_y[:, None]).any(1)
        evaluated_class_ids = {class_ids[i] for i in split["evaluatedVocabularyIndices"]}
        class_top1 = []
        class_top5 = []
        for vocabulary_index in split["evaluatedVocabularyIndices"]:
            class_id = class_ids[vocabulary_index]
            mask = expected_y.eq(class_id)
            if mask.any():
                class_top1.append(float(exact[mask].float().mean()))
                class_top5.append(float(top5_ok[mask].float().mean()))
        evaluated_mask = torch.tensor([int(v) in evaluated_class_ids for v in expected_y.tolist()])
        record = {
            "epoch": epoch,
            "trainLoss": loss_sum / seen,
            "trainTop1": correct / seen,
            "validationLoss": validation_loss / expected_y.numel(),
            "validationTop1AllSamples": float(exact.float().mean()),
            "validationTop5AllSamples": float(top5_ok.float().mean()),
            "validationTop1EvaluableSamples": float(exact[evaluated_mask].float().mean()),
            "validationTop5EvaluableSamples": float(top5_ok[evaluated_mask].float().mean()),
            "validationTop1MacroOverEvaluableClasses": float(np.mean(class_top1)),
            "validationTop5MacroOverEvaluableClasses": float(np.mean(class_top5)),
            "validationImageCount": int(expected_y.numel()),
            "evaluatedClassCount": len(split["evaluatedVocabularyIndices"]),
            "learningRateNextEpoch": scheduler.get_last_lr()[0],
            "elapsedSeconds": time.time() - started,
        }
        history.append(record)
        print(json.dumps(record), flush=True)
        (args.output / "epoch-history.json").write_text(json.dumps(history, indent=2) + "\n")
        if record["validationTop1MacroOverEvaluableClasses"] > best_top1:
            best_top1 = record["validationTop1MacroOverEvaluableClasses"]
            torch.save({"epoch": epoch, "model": model.cpu().state_dict(), "classMap": class_rows,
                        "validation": record, "seed": args.seed}, args.output / "best-vit.pt")
            model.to(device)
        scheduler.step()

    report = {
        "schema": "firebird-typeset-vit-font-file-heldout-v1",
        "architecture": "ViT: grayscale 64x64, patch 8, width 128, 4 transformer encoder layers, 4 heads, 228 glyph labels",
        "device": str(device),
        "epochs": args.epochs,
        "seed": args.seed,
        "vocabularySHA256": hashlib.sha256(vocabulary_bytes).hexdigest(),
        "corpusManifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
        "rawRasterSHA256": sha256_file(args.images),
        "trainFontFileSplit": split,
        "history": history,
        "bestCheckpoint": "best-vit.pt",
            "checkpointMetric": "validationTop1MacroOverEvaluableClasses",
        "notEvaluated": "Math-structure label \\frac and labels with only one exact font-file source are not evidence for cross-font similarity groups.",
    }
    (args.output / "training-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"REPORT {args.output / 'training-report.json'}", flush=True)


if __name__ == "__main__":
    main()
