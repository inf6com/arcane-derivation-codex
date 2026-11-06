#!/usr/bin/env python3
"""Build and audit a lossless LaTeX structure-aware tokenizer.

Control words such as ``\\frac`` and ``\\begin{matrix}`` are atomic tokens;
ordinary characters remain atomic characters.  The tokenizer never substitutes
unknown input.  Train/valid/test vocabulary coverage and exact round trips are
reported before the JSON artifact is written.
"""
from __future__ import annotations

import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

TOKEN_RE = re.compile(r"\\[A-Za-z]+|\\\\|\\.|.", re.DOTALL)
SPECIAL = ["<pad>", "<bos>", "<eos>", "<unk>"]


def tokenize(label: str) -> list[str]:
    tokens = TOKEN_RE.findall(label)
    if "".join(tokens) != label:
        raise ValueError("structure tokenizer failed lossless coverage")
    return tokens


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    by_split: dict[str, list[dict[str, str]]] = defaultdict(list)
    for line in args.labels.open(encoding="utf-8"):
        row = json.loads(line)
        label = row.get("normalizedLabel")
        if not isinstance(label, str) or not label:
            raise ValueError(f"empty or invalid normalizedLabel: {row}")
        by_split[row["split"]].append({"sampleId": row["sampleId"], "label": label})

    train_tokens = Counter(token for row in by_split["train"] for token in tokenize(row["label"]))
    tokens = SPECIAL + sorted(train_tokens)
    token_to_id = {token: index for index, token in enumerate(tokens)}
    coverage: dict[str, dict[str, int]] = {}
    round_trip: dict[str, int] = {}
    for split, rows in by_split.items():
        unknown = 0
        round_trip_failures = 0
        for row in rows:
            pieces = tokenize(row["label"])
            unknown += sum(piece not in token_to_id for piece in pieces)
            round_trip_failures += int("".join(pieces) != row["label"])
        coverage[split] = {"samples": len(rows), "unknownTokens": unknown}
        round_trip[split] = round_trip_failures

    if any(value["unknownTokens"] for value in coverage.values()) or any(round_trip.values()):
        raise ValueError(f"tokenizer audit failed: coverage={coverage}, roundTrip={round_trip}")

    payload = {
        "format": "inf6-formula-whole-structure-tokenizer-v1",
        "tokenization": "LaTeX control words and escaped characters are atomic; remaining Unicode code points are atomic",
        "specialTokens": SPECIAL,
        "tokens": tokens,
        "tokenToID": token_to_id,
        "trainFrequency": dict(sorted(train_tokens.items())),
        "coverage": coverage,
        "roundTripFailures": round_trip,
    }
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"vocabSize": len(tokens), "coverage": coverage, "roundTripFailures": round_trip}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
