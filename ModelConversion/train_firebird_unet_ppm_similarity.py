#!/usr/bin/env python3
"""Train a font-only U-Net + pyramid-pooling descriptor for symbol subsets."""
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


PYRAMID_LEVELS = (1, 2, 4)


class GlyphDataset(Dataset):
    def __init__(self, bank, rows, indices, synthetic_sources=()):
        self.items = [(bank, i, int(rows[i]["vocabularyIndex"]), 1.0) for i in indices]
        for synthetic_bank, synthetic_rows, value_scale in synthetic_sources:
            self.items.extend((synthetic_bank, int(row["imageIndex"]),
                               int(row["vocabularyIndex"]), value_scale) for row in synthetic_rows)
        self.labels = [label for _, _, label, _ in self.items]

    def __len__(self):
        return len(self.items)

    def __getitem__(self, index):
        bank, row, label, value_scale = self.items[index]
        image = np.array(bank[row], copy=True)
        if value_scale != 1.0:
            image = image.astype(np.float32) * value_scale
        return torch.from_numpy(image), label


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


class PyramidPooling(nn.Module):
    """Global and coarse context branches at the U-Net bottleneck."""
    def __init__(self, channels: int = 256, branch_channels: int = 64):
        super().__init__()
        self.branches = nn.ModuleList(
            nn.Sequential(nn.AdaptiveAvgPool2d((side, side)),
                          nn.Conv2d(channels, branch_channels, 1, bias=False),
                          nn.GroupNorm(8, branch_channels), nn.GELU())
            for side in PYRAMID_LEVELS
        )
        self.fuse = ConvBlock(channels + branch_channels * len(PYRAMID_LEVELS), channels)

    def forward(self, x):
        context = [F.interpolate(branch(x), size=x.shape[-2:], mode="bilinear", align_corners=False)
                   for branch in self.branches]
        return self.fuse(torch.cat((x, *context), dim=1))


class FirebirdUNetPPM(nn.Module):
    """Dense shape encoder-decoder; the exported descriptors are multiscale sets."""
    def __init__(self, descriptor_channels: int = 32):
        super().__init__()
        self.pool = nn.MaxPool2d(2)
        self.enc1 = ConvBlock(2, 32)
        self.enc2 = ConvBlock(32, 64)
        self.enc3 = ConvBlock(64, 128)
        self.enc4 = ConvBlock(128, 192)
        self.bottleneck = ConvBlock(192, 256)
        self.pyramid_pooling = PyramidPooling(256, 64)
        self.dec4 = ConvBlock(256 + 192, 192)
        self.dec3 = ConvBlock(192 + 128, 128)
        self.dec2 = ConvBlock(128 + 64, 64)
        self.dec1 = ConvBlock(64 + 32, 48)
        self.descriptor = nn.Conv2d(48, descriptor_channels, 1)
        self.reconstruction = nn.Conv2d(descriptor_channels, 2, 1)

    @staticmethod
    def upsample(x, skip):
        return F.interpolate(x, size=skip.shape[-2:], mode="bilinear", align_corners=False)

    def forward_with_reconstruction(self, image):
        e1 = self.enc1(image)
        e2 = self.enc2(self.pool(e1))
        e3 = self.enc3(self.pool(e2))
        e4 = self.enc4(self.pool(e3))
        x = self.pyramid_pooling(self.bottleneck(self.pool(e4)))
        x = self.dec4(torch.cat((self.upsample(x, e4), e4), dim=1))
        x = self.dec3(torch.cat((self.upsample(x, e3), e3), dim=1))
        x = self.dec2(torch.cat((self.upsample(x, e2), e2), dim=1))
        x = self.dec1(torch.cat((self.upsample(x, e1), e1), dim=1))
        descriptors = self.descriptor(x)
        return descriptors, self.reconstruction(descriptors)

    def forward(self, image):
        return self.forward_with_reconstruction(image)[0]


def reconstruction_loss(logits, target):
    foreground = (target > 0.05).sum(dim=(0, 2, 3), keepdim=True).clamp_min(1)
    background = (target <= 0.05).sum(dim=(0, 2, 3), keepdim=True).clamp_min(1)
    positive_weight = torch.sqrt(background.float() / foreground.float()).clamp(1.0, 25.0)
    bce = F.binary_cross_entropy_with_logits(logits, target, pos_weight=positive_weight)
    probability = logits.sigmoid()
    intersection = (probability * target).sum(dim=(0, 2, 3))
    denominator = probability.sum(dim=(0, 2, 3)) + target.sum(dim=(0, 2, 3))
    dice_loss = 1.0 - ((2.0 * intersection + 1.0) / (denominator + 1.0))
    return bce + dice_loss.mean(), {"weightedBCE": bce, "diceLoss": dice_loss.mean()}


def pyramid_sets(model, x):
    dense = model(x)
    tokens, masks = [], []
    for side in PYRAMID_LEVELS:
        pooled = F.adaptive_avg_pool2d(dense, (side, side)).permute(0, 2, 3, 1).flatten(1, 2)
        ink = F.adaptive_max_pool2d(x.amax(dim=1, keepdim=True), (side, side)).flatten(1) > .5
        tokens.append(pooled)
        masks.append(ink)
    return [(F.normalize(t, dim=-1), m) for t, m in zip(tokens, masks)]


def match_sets(a: np.ndarray, b: np.ndarray):
    if not len(a) or not len(b):
        return 0.0, 0
    scores = a @ b.T
    best_b_for_a = scores.argmax(axis=1)
    best_a_for_b = scores.argmax(axis=0)
    matched = sum(best_a_for_b[j] == i for i, j in enumerate(best_b_for_a))
    return matched / max(len(a), len(b)), matched


def pair_coverage(a_levels, b_levels):
    # The 1x1 PPM token describes global context, not a reusable shape part.
    # Compare 2x2 and 4x4 tokens by reciprocal best correspondence, without a
    # similarity cutoff calibrated on transformed copies of the same symbol.
    matched = left_count = right_count = 0
    level_scores = []
    for a, b in zip(a_levels[1:], b_levels[1:]):
        score, count = match_sets(a, b)
        matched += count
        left_count += len(a); right_count += len(b)
        level_scores.append(score)
    coverage = matched / max(left_count, right_count, 1)
    return float(coverage), level_scores


def validate_reconstruction(model, bank, indices, device):
    model.eval(); losses = []; channel_dice = []; channel_iou = []
    with torch.inference_mode():
        for start in range(0, len(indices), 32):
            selected = indices[start:start + 32]
            target = torch.from_numpy(np.array(bank[selected], copy=True)).to(device=device, dtype=torch.float32).div_(255.)
            _, logits = model.forward_with_reconstruction(target)
            loss, _ = reconstruction_loss(logits, target)
            pred = logits.sigmoid() >= .5
            truth = target >= .5
            for channel in range(target.shape[1]):
                p = pred[:, channel]; t = truth[:, channel]
                intersection = (p & t).sum(dim=(1, 2)).float()
                dice = (2 * intersection + 1) / (p.sum(dim=(1, 2)) + t.sum(dim=(1, 2)) + 1)
                iou = (intersection + 1) / ((p | t).sum(dim=(1, 2)) + 1)
                channel_dice.append(dice.cpu().numpy())
                channel_iou.append(iou.cpu().numpy())
            losses.append(float(loss))
    return {"heldOutReconstructionLoss": float(np.mean(losses)),
            "meanChannelDice": float(np.mean(np.concatenate(channel_dice))),
            "meanChannelIoU": float(np.mean(np.concatenate(channel_iou))),
            "samples": len(indices)}


def extract_sets(model, bank, indices, device, batch_size=64, value_scale=1.0):
    """Extract normalized descriptors and active-bin masks for selected corpus rows."""
    result = {}
    model.eval()
    with torch.inference_mode():
        for start in range(0, len(indices), batch_size):
            ids = indices[start:start + batch_size]
            x = torch.from_numpy(np.array(bank[ids], copy=True)).to(device=device, dtype=torch.float32)
            if value_scale != 1.0:
                x.mul_(value_scale)
            x.div_(255.)
            levels = pyramid_sets(model, x)
            for offset, image_index in enumerate(ids):
                result[int(image_index)] = [
                    F.normalize(tokens[offset, mask[offset]], dim=-1).cpu().numpy().astype(np.float32)
                    for tokens, mask in levels
                ]
    return result


def render_candidates(model, bank, rows, vocabulary, generation_indices, args, device):
    print(json.dumps({"stage": "candidate-feature-extraction", "fontCount": 40,
                      "glyphRows": len(generation_indices)}, ensure_ascii=False), flush=True)
    features = extract_sets(model, bank, generation_indices, device)
    by_font_symbol = {}
    for image_index in generation_indices:
        row = rows[image_index]
        by_font_symbol.setdefault((row["fontFileSHA256"], int(row["vocabularyIndex"])), features[image_index])

    entries = vocabulary["entries"]
    symbols = [int(entry["index"]) for entry in entries]
    by_scalar = {entry.get("unicodeScalar"): int(entry["index"]) for entry in entries}
    known_pairs = {
        tuple(sorted((by_scalar[left], by_scalar[right])))
        for left, right in (("U+0053", "U+0073"), ("U+0058", "U+0078"),
                            ("U+004D", "U+006D"), ("U+0056", "U+0076"),
                            ("U+005A", "U+0032"))
        if left in by_scalar and right in by_scalar
    }
    known_scores = {pair: [] for pair in known_pairs}
    edges = {}
    compared_pairs = 0
    fonts_by_symbol = defaultdict(set)
    for font, label in by_font_symbol:
        fonts_by_symbol[label].add(font)
    for left, right in combinations(symbols, 2):
        common_fonts = sorted(fonts_by_symbol[left] & fonts_by_symbol[right])
        if not common_fonts:
            continue
        selected_fonts = common_fonts
        scores = []; level_observations = []
        for font in selected_fonts:
            coverage, levels = pair_coverage(by_font_symbol[(font, left)], by_font_symbol[(font, right)])
            scores.append(coverage)
            level_observations.append(levels)
        compared_pairs += 1
        if compared_pairs % 5000 == 0:
            print(json.dumps({"stage": "candidate-pair-scoring", "pairsCompared": compared_pairs,
                              "candidatePairs": len(edges)}, ensure_ascii=False), flush=True)
        median = float(np.median(scores))
        pass_fraction = float(np.mean(np.asarray(scores) >= .5))
        pair_key = (left, right)
        if pair_key in known_scores:
            complete_observations = []
            for font in common_fonts:
                score, levels = pair_coverage(by_font_symbol[(font, left)], by_font_symbol[(font, right)])
                complete_observations.append({"fontSHA256": font,
                                              "fontSharedPartRatio": score,
                                              "ppm2x2ReciprocalCoverage": float(levels[0]),
                                              "ppm4x4ReciprocalCoverage": float(levels[1])})
            known_scores[pair_key] = complete_observations
        if median >= .5 and pass_fraction >= .5:
            edges[(left, right)] = {
                "medianSharedCoverage": median,
                "passingFontCount": int(np.sum(np.asarray(scores) >= .5)),
                "observedFontCount": len(scores),
                "passingFontFraction": pass_fraction,
                "fontEvidenceSHA256": selected_fonts,
            }

    # A-problem diagnostic: seven reserved synthetic double-struck-A views are
    # compared with the co-rendered plain A from their parent fit font.
    a_index = next(int(e["index"]) for e in entries if e.get("unicodeScalar") == "U+0041")
    mathbb_a_index = next(int(e["index"]) for e in entries if e.get("unicodeScalar") == "U+1D538")
    a_diagnostic = {"plainAIndex": a_index, "doubleStruckAIndex": mathbb_a_index,
                    "heldOutSyntheticViewCount": 0, "passingViewCount": 0,
                    "medianSharedCoverage": 0.0, "addedAsCandidate": False,
                    "independentFontStyleCount": 0}
    if args.reserved_mathbb_a:
        reserved_rows = args.reserved_mathbb_a
        a_features = extract_sets(model, args.reserved_bank, list(range(len(reserved_rows))), device,
                                  value_scale=255.0)
        plain_a_by_face = {(row["fontFileSHA256"], row["postScriptName"]): index
                           for index, row in enumerate(rows) if int(row["vocabularyIndex"]) == a_index}
        a_scores = []; parent_a_cache = {}
        for offset, row in enumerate(reserved_rows):
            parent = row.get("parentFontFileSHA256")
            face = row.get("parentPostScriptName")
            parent_a_index = plain_a_by_face.get((parent, face))
            if parent_a_index is None:
                raise ValueError(f"same-font plain A is missing for reserved double-struck-A view: {parent} / {face}")
            if parent_a_index not in parent_a_cache:
                parent_a_cache[parent_a_index] = extract_sets(model, bank, [parent_a_index], device)[parent_a_index]
            plain = parent_a_cache[parent_a_index]
            score, _ = pair_coverage(plain, a_features[offset])
            a_scores.append(score)
        a_diagnostic.update({"heldOutSyntheticViewCount": len(a_scores),
                             "passingViewCount": int(np.sum(np.asarray(a_scores) >= .5)),
                             "medianSharedCoverage": float(np.median(a_scores)) if a_scores else 0.0})
        if len(a_scores) == 7 and a_diagnostic["medianSharedCoverage"] >= .5 and a_diagnostic["passingViewCount"] >= 4:
            edges[tuple(sorted((a_index, mathbb_a_index)))] = {
                "medianSharedCoverage": a_diagnostic["medianSharedCoverage"],
                "passingFontCount": a_diagnostic["passingViewCount"], "observedFontCount": 7,
                "passingFontFraction": a_diagnostic["passingViewCount"] / 7,
                "fontEvidenceSHA256": [r.get("parentFontFileSHA256") for r in reserved_rows],
                "evidenceType": "same-parent-font held-out synthetic resolution views; not independent style validation",
            }
            a_diagnostic["addedAsCandidate"] = True

    neighbors = {symbol: [] for symbol in symbols}
    for (left, right), evidence in sorted(edges.items()):
        neighbors[left].append({"symbolIndex": right, **evidence})
        neighbors[right].append({"symbolIndex": left, **evidence})
    subsets = [{"symbolIndex": symbol, "label": entries[symbol]["label"],
                "kind": entries[symbol]["kind"], "neighbors": sorted(
                    neighbors[symbol], key=lambda item: item["symbolIndex"])} for symbol in symbols]
    generation_font_count = len({rows[i]["fontFileSHA256"] for i in generation_indices})
    known_diagnostics = []
    for (left, right), observations in sorted(known_scores.items()):
        if not observations:
            raise ValueError(f"no common generation-font observations for explicit pair {left}<->{right}")
        ratios = np.asarray([observation["fontSharedPartRatio"] for observation in observations])
        known_diagnostics.append({"leftSymbolIndex": left, "rightSymbolIndex": right,
                                 "leftSymbol": display_label(entries[left]),
                                 "rightSymbol": display_label(entries[right]),
                                 "observedFonts": len(observations),
                                 "medianSharedPartRatio": float(np.median(ratios)),
                                 "passingFontsAt50Percent": int(np.sum(ratios >= .5)),
                                 "ppm2x2Median": float(np.median([s["ppm2x2ReciprocalCoverage"] for s in observations])),
                                 "ppm4x4Median": float(np.median([s["ppm4x4ReciprocalCoverage"] for s in observations])),
                                 "perFont": observations,
                                 "candidateAccepted": (left, right) in edges})
    all_sets = {"schema": "firebird-unet-ppm-shared-parts-v2",
                "targetDefinition": "font-glyph shared shape-part candidates from U-Net descriptors; reciprocal best part correspondences, position-free across PPM 2x2 and 4x4 sets",
                "partMatchRule": "reciprocal nearest descriptor correspondence; no cutoff calibrated from transformed copies",
                "acceptanceRule":
                "shared reciprocal correspondences / larger part-set size >= 0.50 in at least half of observed fonts, with median >= 0.50",
                "candidateGenerationFontsUsed": generation_font_count,
                "candidatePairsCompared": compared_pairs, "candidatePairCount": len(edges),
                "explicitPositivePairDiagnostics": known_diagnostics,
                "handwritingUsed": False, "outerTestOpened": False,
                "aProblemDiagnostic": a_diagnostic, "subsets": subsets}
    return all_sets


def write_subset_markdown(path: Path, result, vocabulary):
    names = {int(entry["index"]): display_label(entry) for entry in vocabulary["entries"]}
    lines = ["# 火の鳥 U-Net + PPM 活字共通形状部分候補", "",
             "これは画像形状記述子から機械生成した候補です。人手の意味的正解ラベルではありません。", "",
             f"比較した記号対: {result['candidatePairsCompared']}",
             f"採択した記号対: {result['candidatePairCount']}",
             "判定: 2×2・4×4の形状記述子で相互最良対応した部分の共有率。", "",
             "| 記号 index | 記号 | 類似部分集合 |", "|---:|---|---|"]
    for row in result["subsets"]:
        label = display_label(vocabulary["entries"][row["symbolIndex"]]).replace("|", "\\|")
        members = "、".join(f"{item['symbolIndex']}: {names[item['symbolIndex']]}" for item in row["neighbors"]) or "なし"
        lines.append(f"| {row['symbolIndex']} | {label} | {members} |")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def display_label(entry):
    scalar = entry.get("unicodeScalar")
    if scalar:
        character = chr(int(scalar.removeprefix("U+"), 16))
        if entry.get("kind") == "unicode-combining":
            names = {"U+0307": "結合点（上）", "U+0302": "山形アクセント", "U+0305": "上線",
                     "U+0303": "チルダ", "U+0332": "下線", "U+20D7": "ベクトル矢印"}
            return names.get(scalar, f"結合記号 {character}")
        return character
    if entry["kind"] == "math-structure":
        return "分数構造"
    raise ValueError(f"no non-LaTeX display label for vocabulary index {entry['index']}")


def file_sha256(path: Path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=24)
    parser.add_argument("--seed", type=int, default=20261106)
    parser.add_argument("--resume-candidates", action="store_true",
                        help="resume candidate generation from completed epoch checkpoints in the output directory")
    args = parser.parse_args()
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is required; CPU fallback is prohibited")
    if args.output.exists() and not args.resume_candidates:
        raise FileExistsError(f"refusing to overwrite run: {args.output}")
    if args.resume_candidates and not args.output.is_dir():
        raise FileNotFoundError(f"candidate resume directory does not exist: {args.output}")
    if args.batch_size < 4 or args.epochs < 1:
        raise ValueError("invalid batch size or epoch count")

    manifest_path = Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json")
    bank_path = Path("runs/agent-control/cycle624-firebird-part-similarity-v1/contour-skeleton-corpus.u8")
    split_path = Path("runs/agent-control/cycle625-firebird-pair-overlap-v2/training-report.json")
    vocabulary_path = Path("runs/agent-control/cycle621-firebird-label-kinds.json")
    manifest_bytes = manifest_path.read_bytes(); manifest = json.loads(manifest_bytes)
    rows = manifest["rows"]; vocabulary = json.loads(vocabulary_path.read_text())
    split = json.loads(split_path.read_text())
    if len(vocabulary["entries"]) != 229 or len(rows) != manifest["renderedImageCount"]:
        raise ValueError("authoritative 229-symbol typeface corpus mismatch")
    if [int(entry["index"]) for entry in vocabulary["entries"]] != list(range(229)):
        raise ValueError("vocabulary rows are not in stable canonical index order")
    if split["corpusManifestSHA256"] != hashlib.sha256(manifest_bytes).hexdigest():
        raise ValueError("font split does not belong to the current glyph manifest")
    if bank_path.stat().st_size != len(rows) * 2 * 64 * 64:
        raise ValueError("contour/skeleton bank size mismatch")
    indices_by_scalar = {entry.get("unicodeScalar"): int(entry["index"]) for entry in vocabulary["entries"]}
    if "U+0041" not in indices_by_scalar or "U+1D538" not in indices_by_scalar:
        raise ValueError("A-problem symbols are absent from the vocabulary")
    fit_fonts, validation_fonts, generation_fonts = map(set, (split["fitFontFiles"], split["validationFontFiles"], split["generationFontFiles"]))
    if (len(fit_fonts), len(validation_fonts), len(generation_fonts)) != (202, 10, 40):
        raise ValueError("expected the fixed disjoint 202/10/40 font split")
    if fit_fonts & validation_fonts or fit_fonts & generation_fonts or validation_fonts & generation_fonts:
        raise ValueError("font leakage in fixed split")
    if fit_fonts | validation_fonts | generation_fonts != {r["fontFileSHA256"] for r in rows}:
        raise ValueError("fixed split does not cover all source fonts")

    fit_indices = [i for i, r in enumerate(rows) if r["fontFileSHA256"] in fit_fonts]
    def one_per_font_label(fontset):
        found = {}
        for i, row in enumerate(rows):
            if row["fontFileSHA256"] in fontset:
                found.setdefault((row["fontFileSHA256"], int(row["vocabularyIndex"])), i)
        return [found[key] for key in sorted(found)]
    validation_indices = one_per_font_label(validation_fonts)
    generation_indices = one_per_font_label(generation_fonts)
    if not validation_indices or not generation_indices:
        raise ValueError("font split produced an empty validation or generation partition")

    synthetic_sources = []; synthetic_info = {}; reserved_mathbb_a = []; reserved_bank = None
    for name, folder, bank_name, index_name in (
        ("cycle635", "cycle635-font-handwriting-gap-fill", "synthetic-font-shapes.u8", "synthetic-font-shapes.jsonl"),
        ("cycle637", "cycle637-synthetic-font-gap-fill-corrected", "synthetic-font-gap-variants.u8", "synthetic-font-gap-variants.jsonl"),
    ):
        directory = Path("runs/agent-control") / folder
        synthetic_manifest = json.loads((directory / "manifest.json").read_text())
        if synthetic_manifest["inputs"]["fontManifestSHA256"] != hashlib.sha256(manifest_bytes).hexdigest():
            raise ValueError(f"{name} synthetic images use a different glyph manifest")
        synthetic_rows = [json.loads(line) for line in (directory / index_name).read_text().splitlines() if line]
        synthetic_bank_path = directory / bank_name
        if synthetic_bank_path.stat().st_size != len(synthetic_rows) * 2 * 64 * 64:
            raise ValueError(f"{name} synthetic bank/index mismatch")
        for row in synthetic_rows:
            if row.get("parentFontFileSHA256") not in fit_fonts:
                raise ValueError(f"{name} synthetic view is not fit-only")
        synthetic_bank = np.memmap(synthetic_bank_path, mode="r", dtype=np.uint8,
                                   shape=(len(synthetic_rows), 2, 64, 64))
        value_min, value_max = int(synthetic_bank.min()), int(synthetic_bank.max())
        if (value_min, value_max) != (0, 1):
            raise ValueError(f"{name} synthetic image range changed; expected binary 0/1, got {value_min}..{value_max}")
        synthetic_value_scale = 255.0
        if name == "cycle637":
            mathbb_index = indices_by_scalar["U+1D538"]
            train_rows = [r for r in synthetic_rows if int(r["vocabularyIndex"]) != mathbb_index]
            reserved_mathbb_a = [r for r in synthetic_rows if int(r["vocabularyIndex"]) == mathbb_index]
            reserved_bank = synthetic_bank
        else:
            train_rows = synthetic_rows
        synthetic_sources.append((synthetic_bank, train_rows, synthetic_value_scale))
        synthetic_info[name] = {"artifactRows": len(synthetic_rows), "fitRows": len(train_rows),
                                "heldOutDoubleStruckARows": len(reserved_mathbb_a) if name == "cycle637" else 0,
                                "storedValueRange": [value_min, value_max],
                                "inputValueScaleBefore255Normalization": synthetic_value_scale,
                                "bankSHA256": file_sha256(synthetic_bank_path)}

    bank = np.memmap(bank_path, mode="r", dtype=np.uint8, shape=(len(rows), 2, 64, 64))
    if int(bank.min()) != 0 or int(bank.max()) != 255:
        raise ValueError("authoritative font corpus must use antialiased UInt8 values in range 0..255")
    dataset = GlyphDataset(bank, rows, fit_indices, synthetic_sources)
    labels = np.asarray(dataset.labels, dtype=np.int64)
    counts = np.bincount(labels, minlength=229)
    sampler = WeightedRandomSampler(torch.as_tensor(1 / np.maximum(counts[labels], 1), dtype=torch.double),
                                     len(dataset), replacement=True, generator=torch.Generator().manual_seed(args.seed))
    loader = DataLoader(dataset, batch_size=args.batch_size, sampler=sampler, num_workers=0, drop_last=True)
    args.output.mkdir(parents=True, exist_ok=True)
    input_hashes = {str(path): file_sha256(path) for path in
                    (manifest_path, bank_path, split_path, vocabulary_path)}
    status_path = args.output / "run-status.json"
    if args.resume_candidates:
        status = json.loads(status_path.read_text())
        history_path = args.output / "epoch-history.json"
        history = json.loads(history_path.read_text())
        if status.get("phase") not in {"epoch-validation-complete", "candidate-generation",
                                        "candidate-artifacts-validated", "completed"} or len(history) != args.epochs:
            raise ValueError("candidate resume requires all requested epochs to have completed validation")
        if status.get("inputSHA256") != input_hashes:
            raise ValueError("candidate resume input hashes differ from the trained run")
        best_record = max(history, key=lambda row: row["validation"]["meanChannelIoU"])
        selected_epoch = int(best_record["epoch"])
        best_score = float(best_record["validation"]["meanChannelIoU"])
        checkpoint_path = args.output / f"epoch-{selected_epoch:02d}.pt"
        best_state = torch.load(checkpoint_path, map_location="cpu", weights_only=True)["state_dict"]
        args.epochs = 0
    else:
        history = []; best_score = -1.; best_state = None; selected_epoch = None
        status = {"state": "running", "phase": "training", "epoch": 0, "batch": 0,
                  "epochsRequested": args.epochs, "architecture": "U-Net + PPM(1,2,4) shape reconstruction",
                  "trainingDevice": "mps", "seed": args.seed, "inputSHA256": input_hashes}
        write_json(status_path, status)
    device = torch.device("mps")
    torch.manual_seed(args.seed)
    model = FirebirdUNetPPM().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-4, weight_decay=1e-4)

    for epoch in range(1, args.epochs + 1):
        model.train(); total_loss = 0.; batches = 0
        for step, (dots, _) in enumerate(loader, 1):
            x = dots.to(device=device, dtype=torch.float32).div_(255.)
            _, logits = model.forward_with_reconstruction(x)
            loss, pieces = reconstruction_loss(logits, x)
            optimizer.zero_grad(set_to_none=True); loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0); optimizer.step()
            total_loss += float(loss.detach()); batches += 1
            if step % 100 == 0:
                progress = {"epoch": epoch, "batch": step, "batchCount": len(loader),
                                  "fitLoss": total_loss / batches,
                                  "weightedBCE": float(pieces["weightedBCE"].detach()),
                                  "diceLoss": float(pieces["diceLoss"].detach())}
                status.update({"phase": "training", **progress})
                write_json(status_path, status)
                print(json.dumps(progress, ensure_ascii=False), flush=True)
        validation = validate_reconstruction(model, bank, validation_indices, device)
        score = float(validation["meanChannelIoU"])
        record = {"epoch": epoch, "fitLoss": total_loss / max(batches, 1), "validation": validation}
        history.append(record); print(json.dumps(record, ensure_ascii=False), flush=True)
        write_json(args.output / "epoch-history.json", history)
        status.update({"phase": "epoch-validation-complete", "epoch": epoch,
                       "batch": len(loader), "validation": record})
        write_json(status_path, status)
        epoch_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
        torch.save({"state_dict": epoch_state, "epoch": epoch, "architecture": "U-Net + PPM(1,2,4)"},
                   args.output / f"epoch-{epoch:02d}.pt")
        if score > best_score:
            best_score = score; selected_epoch = epoch; best_state = epoch_state

    if best_state is None:
        raise RuntimeError("no U-Net checkpoint selected from held-out-font validation")
    if reserved_bank is None:
        raise RuntimeError("reserved cycle637 bank is missing; A-problem diagnostic cannot be run")
    status.update({"phase": "candidate-generation", "selectedEpoch": selected_epoch,
                   "bestHeldOutReconstructionIoU": best_score})
    write_json(status_path, status)
    model.load_state_dict(best_state); model.eval()
    args.reserved_mathbb_a = reserved_mathbb_a
    args.reserved_bank = reserved_bank
    subsets = render_candidates(model, bank, rows, vocabulary, generation_indices, args, device)
    subsets_path = args.output / "similarity-subsets.json"
    subsets_path.write_text(json.dumps(subsets, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    markdown_path = args.output / "similarity-subsets.md"
    write_subset_markdown(markdown_path, subsets, vocabulary)
    if len(subsets["subsets"]) != 229 or [r["symbolIndex"] for r in subsets["subsets"]] != list(range(229)):
        raise RuntimeError("candidate artifact does not contain exactly the canonical 229-symbol vocabulary")
    for left, row in enumerate(subsets["subsets"]):
        indices = [entry["symbolIndex"] for entry in row["neighbors"]]
        if indices != sorted(set(indices)) or left in indices:
            raise RuntimeError(f"invalid direct-neighbor list for symbol index {left}")
        for right in indices:
            reverse = [entry["symbolIndex"] for entry in subsets["subsets"][right]["neighbors"]]
            if left not in reverse:
                raise RuntimeError(f"asymmetric candidate edge {left}<->{right}")
    summary = {"schema": "firebird-unet-ppm-shared-parts-v2",
               "trainingDevice": "mps", "fitFontCount": 202,
               "validationFontCount": 10,
               "candidateGenerationFontCount": 40, "trainingGlyphRows": len(dataset),
               "trainingImageRowsByLabel": {str(i): int(count) for i, count in enumerate(counts) if count},
               "seed": args.seed, "batchSize": args.batch_size, "epochsRequested": args.epochs,
               "inputSHA256": input_hashes,
               "parameterCount": sum(parameter.numel() for parameter in model.parameters()),
               "syntheticTypesetViews": synthetic_info, "handwritingUsed": False,
               "architecture": "U-Net encoder-decoder with bottleneck PPM levels 1x1, 2x2, 4x4; no local-window ViT",
               "loss": "weighted binary cross-entropy plus Dice loss reconstructing contour and medial-skeleton channels; no geometric image transformations",
               "candidatePartMatching": "reciprocal best correspondence among normalized U-Net descriptors pooled at PPM 2x2 and 4x4; global 1x1 context excluded from reusable-part overlap; candidate requires at least 50% of the larger part set across fonts",
               "selectedEpoch": selected_epoch, "epochHistory": history,
               "validationMetric": "held-out-font contour/skeleton reconstruction IoU; this measures shape reconstruction, not semantic pair precision",
               "candidatePairCount": subsets["candidatePairCount"],
               "candidateArtifactSHA256": file_sha256(subsets_path),
               "candidateMarkdownSHA256": file_sha256(markdown_path),
               "outerTestOpened": False, "humanSemanticGold": False}
    write_json(args.output / "training-report.json", summary)
    torch.save({"state_dict": best_state, "selectedEpoch": selected_epoch,
                "architecture": "U-Net + PPM(1,2,4)"}, args.output / "firebird-unet-ppm.pt")
    status.update({"state": "completed", "phase": "candidate-artifacts-validated",
                   "selectedEpoch": selected_epoch, "candidatePairCount": subsets["candidatePairCount"],
                   "candidateArtifactSHA256": file_sha256(subsets_path)})
    write_json(status_path, status)
    print(json.dumps({"stage": "training-complete", "selectedEpoch": selected_epoch,
                      "heldOutReconstructionIoU": best_score,
                      "candidatePairCount": subsets["candidatePairCount"],
                      "candidateArtifact": str(subsets_path)}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
