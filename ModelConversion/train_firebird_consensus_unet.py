#!/usr/bin/env python3
"""Train a PPM-free U-Net to predict fit-font consensus glyph maps."""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from itertools import combinations
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler


class GlyphConsensusDataset(Dataset):
    def __init__(self, shape_bank, rows, indices, consensus):
        self.bank = shape_bank
        self.rows = rows
        self.indices = indices
        self.consensus = consensus

    def __len__(self):
        return len(self.indices)

    def __getitem__(self, item):
        image_index = self.indices[item]
        label = int(self.rows[image_index]["vocabularyIndex"])
        image = np.asarray(self.bank[image_index], dtype=np.float32) / 255.0
        target = self.consensus[label]
        return torch.from_numpy(image.copy()), torch.from_numpy(target[None, ...].copy())


class ConvBlock(nn.Module):
    def __init__(self, input_channels: int, output_channels: int):
        super().__init__()
        self.layers = nn.Sequential(
            nn.Conv2d(input_channels, output_channels, 3, padding=1, bias=False),
            nn.GroupNorm(8, output_channels), nn.GELU(),
            nn.Conv2d(output_channels, output_channels, 3, padding=1, bias=False),
            nn.GroupNorm(8, output_channels), nn.GELU(),
        )

    def forward(self, x):
        return self.layers(x)


class FirebirdConsensusUNet(nn.Module):
    """U-Net with native-resolution deep-supervision heads; no PPM module."""
    def __init__(self):
        super().__init__()
        self.pool = nn.MaxPool2d(2)
        self.enc1 = ConvBlock(2, 32)
        self.enc2 = ConvBlock(32, 64)
        self.enc3 = ConvBlock(64, 128)
        self.enc4 = ConvBlock(128, 192)
        self.bottleneck = ConvBlock(192, 256)
        self.dec4 = ConvBlock(256 + 192, 192)
        self.dec3 = ConvBlock(192 + 128, 128)
        self.dec2 = ConvBlock(128 + 64, 64)
        self.dec1 = ConvBlock(64 + 32, 48)
        self.head64 = nn.Conv2d(48, 1, 1)
        self.head32 = nn.Conv2d(64, 1, 1)
        self.head16 = nn.Conv2d(128, 1, 1)
        self.head8 = nn.Conv2d(192, 1, 1)
        self.head4 = nn.Conv2d(256, 1, 1)

    @staticmethod
    def upsample(x, skip):
        return F.interpolate(x, size=skip.shape[-2:], mode="bilinear", align_corners=False)

    def forward(self, image):
        e1 = self.enc1(image)
        e2 = self.enc2(self.pool(e1))
        e3 = self.enc3(self.pool(e2))
        e4 = self.enc4(self.pool(e3))
        b = self.bottleneck(self.pool(e4))
        x = self.dec4(torch.cat((self.upsample(b, e4), e4), dim=1))
        x = self.dec3(torch.cat((self.upsample(x, e3), e3), dim=1))
        x = self.dec2(torch.cat((self.upsample(x, e2), e2), dim=1))
        x = self.dec1(torch.cat((self.upsample(x, e1), e1), dim=1))
        return [self.head64(x), self.head32(e2), self.head16(e3),
                self.head8(e4), self.head4(b)]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def write_subset_table(path: Path, subsets):
    lines = [
        "# 火の鳥・字形合意U-Net 類似部分集合候補",
        "",
        "活字画像から機械生成した候補です。人手意味ゴールドによる確定評価ではありません。",
        "",
        "| 行 | 記号 | 類似候補（中央値IoU） |",
        "|---:|:---:|:---|",
    ]
    for row in subsets["subsets"]:
        neighbors = "、".join(
            f'{subsets["subsets"][item["symbolIndex"]]["label"]}（{item["medianConsensusMapIoU"]:.3f}）'
            for item in row["neighbors"]
        ) or "なし"
        lines.append(f'| {row["symbolIndex"] + 1} | {row["label"]} | {neighbors} |')
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def one_per_font_label(rows, font_files):
    selected = {}
    for index, row in enumerate(rows):
        font = row["fontFileSHA256"]
        if font in font_files:
            selected.setdefault((font, int(row["vocabularyIndex"])), index)
    return [selected[key] for key in sorted(selected)]


def build_consensus_targets(raw_bank, rows, fit_indices, threshold_fraction):
    counts = np.zeros((229, 64, 64), dtype=np.uint16)
    support = np.zeros(229, dtype=np.uint16)
    for index in fit_indices:
        row = rows[index]
        label = int(row["vocabularyIndex"])
        counts[label] += np.asarray(raw_bank[index] > 0, dtype=np.uint16)
        support[label] += 1
    targets = np.zeros((229, 64, 64), dtype=np.float32)
    for label in range(229):
        denominator = int(support[label])
        if denominator == 0:
            continue
        cutoff = int(np.floor(threshold_fraction * denominator))
        keep = counts[label] > cutoff
        targets[label][keep] = counts[label][keep].astype(np.float32) / denominator
    return targets, support


def multiscale_bce(logits, target):
    pieces = []
    for prediction in logits:
        scale_target = F.adaptive_avg_pool2d(target, prediction.shape[-2:])
        pieces.append(F.binary_cross_entropy_with_logits(prediction, scale_target))
    return torch.stack(pieces).mean(), [float(piece.detach()) for piece in pieces]


def pixel_iou(a, b):
    intersection = np.logical_and(a, b).sum()
    union = np.logical_or(a, b).sum()
    return float(intersection / union) if union else 0.0


def evaluate(model, loader, rows, indices, targets, device):
    model.eval()
    total_loss = 0.0
    samples = 0
    ious, dices = [], []
    level_ious = [[] for _ in range(5)]
    by_font_symbol = {}
    with torch.inference_mode():
        cursor = 0
        for images, target in loader:
            images = images.to(device)
            target = target.to(device)
            logits = model(images)
            loss, _ = multiscale_bce(logits, target)
            probabilities = [head.sigmoid().cpu().numpy()[:, 0] for head in logits]
            probs = probabilities[0]
            truths = [(F.adaptive_avg_pool2d(target, (p.shape[-2], p.shape[-1]))
                       .cpu().numpy()[:, 0] >= 0.5) for p in probabilities]
            preds = [p >= 0.5 for p in probabilities]
            truth, pred = truths[0], preds[0]
            intersection = (pred & truth).sum(axis=(1, 2))
            union = (pred | truth).sum(axis=(1, 2))
            denom = pred.sum(axis=(1, 2)) + truth.sum(axis=(1, 2))
            ious.extend((intersection / np.maximum(union, 1)).tolist())
            dices.extend((2 * intersection / np.maximum(denom, 1)).tolist())
            for level, (level_pred, level_truth) in enumerate(zip(preds, truths)):
                level_intersection = (level_pred & level_truth).sum(axis=(1, 2))
                level_union = (level_pred | level_truth).sum(axis=(1, 2))
                level_ious[level].extend((level_intersection / np.maximum(level_union, 1)).tolist())
            batch_indices = indices[cursor:cursor + len(images)]
            for offset, source_index in enumerate(batch_indices):
                row = rows[source_index]
                key = (row["fontFileSHA256"], int(row["vocabularyIndex"]))
                by_font_symbol[key] = [p[offset] for p in probabilities]
            cursor += len(images)
            total_loss += float(loss) * len(images)
            samples += len(images)
    return {"multiscaleBCE": total_loss / max(samples, 1),
            "meanIoUAt0_5": float(np.mean(ious)),
            "meanDiceAt0_5": float(np.mean(dices)),
            "meanIoUByResolution64_32_16_8_4": [float(np.mean(values)) for values in level_ious],
            "samples": samples,
            "predictedConsensusMaps": by_font_symbol}


def evaluate_known_pairs(predictions, vocabulary):
    by_scalar = {entry.get("unicodeScalar"): int(entry["index"]) for entry in vocabulary["entries"]}
    pairs = [("X/x", "U+0058", "U+0078"), ("S/s", "U+0053", "U+0073"),
             ("M/m", "U+004D", "U+006D"), ("V/v", "U+0056", "U+0076"),
             ("Z/2", "U+005A", "U+0032"), ("A/𝔸", "U+0041", "U+1D538")]
    output = []
    for name, left_scalar, right_scalar in pairs:
        if left_scalar not in by_scalar or right_scalar not in by_scalar:
            continue
        left, right = by_scalar[left_scalar], by_scalar[right_scalar]
        fonts = sorted({font for font, label in predictions if label == left}
                       & {font for font, label in predictions if label == right})
        observations = []
        for font in fonts:
            maps_a = predictions[(font, left)]
            maps_b = predictions[(font, right)]
            level_scores = [pixel_iou(a >= 0.5, b >= 0.5) for a, b in zip(maps_a, maps_b)]
            observations.append({"meanIoUAcrossNativeResolutions": float(np.mean(level_scores)),
                                 "iouByResolution64_32_16_8_4": level_scores})
        scores = [item["meanIoUAcrossNativeResolutions"] for item in observations]
        output.append({"pair": name, "observedFonts": len(observations),
                       "medianPredictedMapIoU": float(np.median(scores)) if scores else None,
                       "passingFontsAt0_5": sum(score >= 0.5 for score in scores),
                       "perFontIoU": observations})
    return output


def display_label(entry):
    scalar = entry.get("unicodeScalar")
    if scalar:
        character = chr(int(scalar.removeprefix("U+"), 16))
        if entry.get("kind") == "unicode-combining":
            return {"U+0307": "結合点（上）", "U+0302": "山形アクセント",
                    "U+0305": "上線", "U+0303": "チルダ", "U+0332": "下線",
                    "U+20D7": "ベクトル矢印"}.get(scalar, f"結合記号 {character}")
        return character
    if entry.get("kind") == "math-structure":
        return "分数構造"
    raise ValueError(f"vocabulary entry lacks a displayable identity: {entry}")


def generate_subsets(model, bank, rows, generation_indices, vocabulary, device):
    model.eval()
    predicted = {}
    with torch.inference_mode():
        for start in range(0, len(generation_indices), 64):
            selected = generation_indices[start:start + 64]
            images = torch.from_numpy(np.asarray(bank[selected], dtype=np.float32).copy()).to(device).div_(255.0)
            probabilities = [head.sigmoid().cpu().numpy()[:, 0] for head in model(images)]
            for offset, source_index in enumerate(selected):
                row = rows[source_index]
                predicted[(row["fontFileSHA256"], int(row["vocabularyIndex"]))] = [
                    p[offset] >= 0.5 for p in probabilities]

    entries = vocabulary["entries"]
    symbols = list(range(229))
    fonts_by_symbol = defaultdict(set)
    for font, label in predicted:
        fonts_by_symbol[label].add(font)
    edges = {}
    compared = 0
    for left, right in combinations(symbols, 2):
        common = sorted(fonts_by_symbol[left] & fonts_by_symbol[right])
        if not common:
            continue
        scores = [float(np.mean([pixel_iou(a, b) for a, b in zip(
            predicted[(font, left)], predicted[(font, right)])])) for font in common]
        compared += 1
        median = float(np.median(scores))
        passing = sum(score >= 0.5 for score in scores)
        if median >= 0.5 and passing >= (len(scores) + 1) // 2:
            edges[(left, right)] = {"medianConsensusMapIoU": median,
                                    "passingFontCount": passing, "observedFontCount": len(scores),
                                    "fontEvidenceSHA256": common}
    neighbors = {symbol: [] for symbol in symbols}
    for (left, right), evidence in sorted(edges.items()):
        neighbors[left].append({"symbolIndex": right, **evidence})
        neighbors[right].append({"symbolIndex": left, **evidence})
    subsets = [{"symbolIndex": symbol, "label": display_label(entries[symbol]),
                "kind": entries[symbol]["kind"],
                "neighbors": sorted(neighbors[symbol], key=lambda row: row["symbolIndex"])}
               for symbol in symbols]
    return {"schema": "firebird-fit-font-consensus-unet-subsets-v1",
            "targetDefinition": "per-symbol per-pixel ink-presence frequency map accumulated only from fit fonts, with pixels at or below the configured support threshold zeroed",
            "candidateMetric": "equal-weight mean of same-font IoU at the U-Net's native 64/32/16/8/4 prediction heads; no PPM",
            "candidateRule": "median predicted-map IoU >= 0.50 and at least half of common generation fonts >= 0.50",
            "candidateGenerationFontCount": len({rows[i]["fontFileSHA256"] for i in generation_indices}),
            "candidatePairsCompared": compared, "candidatePairCount": len(edges),
            "handwritingUsed": False, "outerTestOpened": False,
            "subsets": subsets}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=5)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--seed", type=int, default=20261108)
    parser.add_argument("--consensus-threshold", type=float, default=0.5)
    args = parser.parse_args()
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is required; CPU fallback is prohibited")
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite existing run: {args.output}")
    if args.epochs < 1 or args.batch_size < 4 or not 0 <= args.consensus_threshold < 1:
        raise ValueError("invalid epoch count, batch size, or consensus threshold")

    manifest_path = Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json")
    raw_path = Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.u8")
    shape_path = Path("runs/agent-control/cycle624-firebird-part-similarity-v1/contour-skeleton-corpus.u8")
    split_path = Path("runs/agent-control/cycle625-firebird-pair-overlap-v2/training-report.json")
    vocabulary_path = Path("runs/agent-control/cycle621-firebird-label-kinds.json")
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    rows = manifest["rows"]
    vocabulary = json.loads(vocabulary_path.read_text(encoding="utf-8"))
    split = json.loads(split_path.read_text(encoding="utf-8"))
    if len(vocabulary["entries"]) != 229 or len(rows) != manifest["renderedImageCount"]:
        raise ValueError("authoritative 229-symbol font corpus mismatch")
    if [int(entry["index"]) for entry in vocabulary["entries"]] != list(range(229)):
        raise ValueError("vocabulary does not use canonical stable ordering")
    if split["corpusManifestSHA256"] != hashlib.sha256(manifest_bytes).hexdigest():
        raise ValueError("font split does not belong to the current corpus manifest")
    expected = len(rows) * 64 * 64
    if raw_path.stat().st_size != expected or shape_path.stat().st_size != len(rows) * 2 * 64 * 64:
        raise ValueError("source glyph bank and shape bank do not match manifest dimensions")
    fit_fonts, valid_fonts, generation_fonts = map(set, (split["fitFontFiles"], split["validationFontFiles"], split["generationFontFiles"]))
    if (len(fit_fonts), len(valid_fonts), len(generation_fonts)) != (202, 10, 40):
        raise ValueError("expected fixed disjoint 202/10/40 font split")
    if fit_fonts & valid_fonts or fit_fonts & generation_fonts or valid_fonts & generation_fonts:
        raise ValueError("font leakage across fit, validation, and candidate-generation partitions")
    if fit_fonts | valid_fonts | generation_fonts != {row["fontFileSHA256"] for row in rows}:
        raise ValueError("font split does not cover the corpus")

    fit_indices = one_per_font_label(rows, fit_fonts)
    validation_indices = one_per_font_label(rows, valid_fonts)
    generation_indices = one_per_font_label(rows, generation_fonts)
    raw_bank = np.memmap(raw_path, mode="r", dtype=np.uint8, shape=(len(rows), 64, 64))
    shape_bank = np.memmap(shape_path, mode="r", dtype=np.uint8, shape=(len(rows), 2, 64, 64))
    targets, target_support = build_consensus_targets(raw_bank, rows, fit_indices, args.consensus_threshold)
    rendered_labels = sorted({int(row["vocabularyIndex"]) for row in rows})
    if len(rendered_labels) != 228 or not np.isfinite(targets).all():
        raise ValueError("font corpus must have 228 finite rendered-symbol consensus maps")
    if any(target_support[label] == 0 for label in rendered_labels):
        raise ValueError("a rendered symbol has no fit-font consensus evidence")

    train_set = GlyphConsensusDataset(shape_bank, rows, fit_indices, targets)
    train_labels = np.asarray([int(rows[i]["vocabularyIndex"]) for i in fit_indices], dtype=np.int64)
    label_counts = np.bincount(train_labels, minlength=229)
    weights = torch.as_tensor(1.0 / np.maximum(label_counts[train_labels], 1), dtype=torch.double)
    sampler = WeightedRandomSampler(weights, len(train_set), replacement=True,
                                     generator=torch.Generator().manual_seed(args.seed))
    train_loader = DataLoader(train_set, batch_size=args.batch_size, sampler=sampler,
                              num_workers=0, drop_last=True)
    valid_set = GlyphConsensusDataset(shape_bank, rows, validation_indices, targets)
    valid_loader = DataLoader(valid_set, batch_size=64, shuffle=False, num_workers=0)

    args.output.mkdir(parents=True)
    input_hashes = {str(path): sha256(path) for path in
                    (manifest_path, raw_path, shape_path, split_path, vocabulary_path)}
    consensus_path = args.output / "fit-consensus-maps.f32le"
    np.asarray(targets, dtype="<f4").tofile(consensus_path)
    status_path = args.output / "run-status.json"
    status = {"state": "running", "phase": "training", "epoch": 0, "batch": 0,
              "architecture": "PPM-free U-Net with native 64/32/16/8/4 deep-supervision heads",
              "trainingDevice": "mps", "seed": args.seed, "inputSHA256": input_hashes,
              "consensusThresholdFraction": args.consensus_threshold}
    write_json(status_path, status)
    device = torch.device("mps")
    torch.manual_seed(args.seed)
    model = FirebirdConsensusUNet().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-4, weight_decay=1e-4)
    history = []
    best_key = None
    best_state = None
    best_epoch = None
    for epoch in range(1, args.epochs + 1):
        model.train()
        total_loss = 0.0
        batches = 0
        for step, (images, target) in enumerate(train_loader, 1):
            images = images.to(device)
            target = target.to(device)
            logits = model(images)
            loss, level_losses = multiscale_bce(logits, target)
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            total_loss += float(loss.detach())
            batches += 1
            if step % 100 == 0:
                status.update({"phase": "training", "epoch": epoch, "batch": step,
                               "batchCount": len(train_loader), "fitLoss": total_loss / batches,
                               "lossByResolution64_32_16_8_4": level_losses})
                write_json(status_path, status)
                print(json.dumps({"epoch": epoch, "batch": step, "batchCount": len(train_loader),
                                  "fitLoss": total_loss / batches}, ensure_ascii=False), flush=True)
        validation = evaluate(model, valid_loader, rows, validation_indices, targets, device)
        pair_results = evaluate_known_pairs(validation["predictedConsensusMaps"], vocabulary)
        record = {"epoch": epoch, "fitLoss": total_loss / max(batches, 1),
                  "validation": {key: value for key, value in validation.items() if key != "predictedConsensusMaps"},
                  "knownPairDiagnostics": pair_results}
        history.append(record)
        write_json(args.output / "epoch-history.json", history)
        state = {key: value.detach().cpu().clone() for key, value in model.state_dict().items()}
        torch.save({"state_dict": state, "epoch": epoch,
                    "architecture": "FirebirdConsensusUNet native-resolution deep supervision"},
                   args.output / f"epoch-{epoch:02d}.pt")
        key = (record["validation"]["meanIoUAt0_5"], -record["validation"]["multiscaleBCE"])
        if best_key is None or key > best_key:
            best_key, best_state, best_epoch = key, state, epoch
        status.update({"phase": "epoch-validation-complete", "epoch": epoch,
                       "batch": len(train_loader), "validation": record["validation"],
                       "knownPairDiagnostics": pair_results})
        write_json(status_path, status)
        print(json.dumps(record, ensure_ascii=False), flush=True)

    if best_state is None:
        raise RuntimeError("no checkpoint passed validation")
    model.load_state_dict(best_state)
    torch.save({"state_dict": best_state, "selectedEpoch": best_epoch,
                "architecture": "FirebirdConsensusUNet native-resolution deep supervision"},
               args.output / "firebird-consensus-unet.pt")
    generation_predictions = evaluate(
        model,
        DataLoader(GlyphConsensusDataset(shape_bank, rows, generation_indices, targets),
                   batch_size=64, shuffle=False, num_workers=0),
        rows, generation_indices, targets, device)["predictedConsensusMaps"]
    subsets = generate_subsets(model, shape_bank, rows, generation_indices, vocabulary, device)
    subsets_path = args.output / "similarity-subsets.json"
    write_json(subsets_path, subsets)
    table_path = args.output / "similarity-subsets.md"
    write_subset_table(table_path, subsets)
    if len(subsets["subsets"]) != 229 or [row["symbolIndex"] for row in subsets["subsets"]] != list(range(229)):
        raise RuntimeError("candidate artifact must contain all canonical 229 vocabulary rows")
    for left, row in enumerate(subsets["subsets"]):
        neighbors = [item["symbolIndex"] for item in row["neighbors"]]
        if left in neighbors or neighbors != sorted(set(neighbors)):
            raise RuntimeError(f"invalid neighbor row {left}")
        for right in neighbors:
            if left not in [item["symbolIndex"] for item in subsets["subsets"][right]["neighbors"]]:
                raise RuntimeError(f"asymmetric subset edge {left}<->{right}")
    known_pairs = evaluate_known_pairs(generation_predictions, vocabulary)
    degree = [len(row["neighbors"]) for row in subsets["subsets"]]
    summary = {"schema": "firebird-fit-font-consensus-unet-run-v1",
               "architecture": "PPM-free U-Net; fit-font consensus-map supervision; native feature levels 64,32,16,8,4 with deep supervision",
               "trainingDevice": "mps", "fitFontCount": len(fit_fonts),
               "parameterCount": sum(parameter.numel() for parameter in model.parameters()),
               "validationFontCount": len(valid_fonts), "generationFontCount": len(generation_fonts),
               "fitRowsOnePerFontSymbol": len(fit_indices), "validationRowsOnePerFontSymbol": len(validation_indices),
               "generationRowsOnePerFontSymbol": len(generation_indices),
               "consensusThresholdFraction": args.consensus_threshold,
               "fitSupportBySymbol": {str(i): int(target_support[i]) for i in range(229)},
               "inputSHA256": input_hashes, "fitConsensusMapSHA256": sha256(consensus_path),
               "loss": "equal-weight BCE across full-resolution output and native U-Net encoder feature-level consensus-map heads",
               "validationMetric": "held-out-font consensus-map IoU and BCE against maps built from fit fonts only",
               "selectedEpoch": best_epoch, "epochHistory": history,
               "validationKnownPairDiagnostics": history[best_epoch-1]["knownPairDiagnostics"],
               "generationKnownPairDiagnostics": known_pairs,
               "candidatePairCount": subsets["candidatePairCount"],
               "candidateGraph": {"edges": subsets["candidatePairCount"],
                                  "medianDegree": float(np.median(degree)),
                                  "meanDegree": float(np.mean(degree)), "maxDegree": max(degree),
                                  "isolatedSymbols": sum(value == 0 for value in degree)},
               "handwritingUsed": False, "outerTestOpened": False,
               "candidateArtifactSHA256": sha256(subsets_path),
               "candidateTableSHA256": sha256(table_path),
               "semanticGoldAvailable": False}
    write_json(args.output / "training-report.json", summary)
    status.update({"state": "completed", "phase": "candidate-artifacts-validated",
                   "selectedEpoch": best_epoch, "candidatePairCount": subsets["candidatePairCount"],
                   "candidateArtifactSHA256": sha256(subsets_path)})
    write_json(status_path, status)
    print(json.dumps({"stage": "training-complete", "selectedEpoch": best_epoch,
                      "validationIoU": best_key[0], "candidatePairs": subsets["candidatePairCount"],
                      "artifact": str(subsets_path)}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
