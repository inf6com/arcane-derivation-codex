#!/usr/bin/env python3
"""Generate the deterministic non-autoregressive handwriting vocabulary."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


SPECIAL_TOKENS = ["<PAD>", "<SOS>", "<EOS>"]


def collect_tokens(root: Path) -> set[str]:
    tokens: set[str] = set()

    atom_path = root / "atom-candidate-manifest-20260916.jsonl"
    with atom_path.open(encoding="utf-8") as stream:
        for line in stream:
            row = json.loads(line)
            label = row.get("glyphLabel")
            if isinstance(label, str) and label:
                tokens.add(label)

    structure_paths = [
        root / "fully-aligned-structure-input-manifest-20260916.jsonl",
        root / "internal-structure-teacher-manifest-20260916.jsonl",
    ]
    for path in structure_paths:
        with path.open(encoding="utf-8") as stream:
            for line in stream:
                row = json.loads(line)
                for token in row.get("tokens", []):
                    value = token.get("token") if isinstance(token, dict) else token
                    if isinstance(value, str) and value:
                        tokens.add(value)

    return tokens


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--training-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    tokens = sorted(collect_tokens(args.training_root))
    vocabulary = {
        "version": "handwritten-nonautoregressive-v1",
        "specialTokens": SPECIAL_TOKENS,
        "tokens": SPECIAL_TOKENS + tokens,
        "sourceManifests": [
            "atom-candidate-manifest-20260916.jsonl",
            "fully-aligned-structure-input-manifest-20260916.jsonl",
            "internal-structure-teacher-manifest-20260916.jsonl",
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(vocabulary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps({"tokenCount": len(vocabulary["tokens"]), "output": str(args.output)}))


if __name__ == "__main__":
    main()
