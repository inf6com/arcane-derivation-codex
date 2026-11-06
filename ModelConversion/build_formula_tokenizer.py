#!/usr/bin/env python3
"""Build a lossless character tokenizer for whole-formula normalizedLabel data.

The tokenizer is deliberately derived from the complete extracted dataset. It
does not split glyphs, infer symbols, or replace unknown characters. A label is
encoded as Unicode code points between explicit BOS/EOS markers, and decoding
must reproduce the source string exactly.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


SPECIAL_TOKENS = ["<pad>", "<bos>", "<eos>", "<unk>"]


def read_rows(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with path.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            if not isinstance(row, dict) or not isinstance(row.get("normalizedLabel"), str):
                raise ValueError(f"line {line_number} has no normalizedLabel string")
            rows.append(row)
    return rows


def build(rows: list[dict[str, str]]) -> dict[str, object]:
    if not rows:
        raise ValueError("no label rows")
    train_chars = sorted({character for row in rows if row.get("split") == "train" for character in row["normalizedLabel"]})
    if not train_chars:
        raise ValueError("train split contains no label characters")
    vocabulary = SPECIAL_TOKENS + train_chars
    token_to_id = {token: index for index, token in enumerate(vocabulary)}
    train_character_set = set(train_chars)
    split_stats: dict[str, dict[str, int]] = {}
    for row in rows:
        split = row.get("split", "")
        label = row["normalizedLabel"]
        unknown = sorted(set(label) - train_character_set)
        if unknown:
            raise ValueError(f"{split}/{row.get('sampleId', '?')} has train-vocabulary OOV characters: {unknown!r}")
        encoded = [token_to_id["<bos>"]] + [token_to_id[character] for character in label] + [token_to_id["<eos>"]]
        decoded = "".join(vocabulary[token_id] for token_id in encoded[1:-1])
        if decoded != label:
            raise AssertionError(f"lossy tokenizer round-trip for {row.get('sampleId', '?')}")
        stats = split_stats.setdefault(split, {"rows": 0, "maxLabelCodePoints": 0, "maxSequenceTokens": 0})
        stats["rows"] += 1
        stats["maxLabelCodePoints"] = max(stats["maxLabelCodePoints"], len(label))
        stats["maxSequenceTokens"] = max(stats["maxSequenceTokens"], len(encoded))
    return {
        "format": "inf6-formula-whole-label-tokenizer-v1",
        "tokenization": "Unicode-code-point characters with explicit BOS/EOS; no unknown substitution",
        "specialTokens": SPECIAL_TOKENS,
        "tokens": vocabulary,
        "tokenToID": token_to_id,
        "characterFrequency": dict(sorted(Counter(character for row in rows if row.get("split") == "train" for character in row["normalizedLabel"]).items())),
        "splitStats": split_stats,
        "oovPolicy": "error",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = build(read_rows(args.labels))
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"rows": sum(int(stats["rows"]) for stats in result["splitStats"].values()), "tokenCount": len(result["tokens"]), "output": str(args.output)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
