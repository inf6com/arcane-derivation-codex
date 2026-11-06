"""Formula-level weak supervision input for the Hinotori retrieval model."""
from __future__ import annotations

import json
import hashlib
from pathlib import Path

import torch
from torch import Tensor
from torch.utils.data import Dataset

from hinotori_inkml import read_inkml_traces


MEMBERSHIP_SUBSET_CONTRACT = "hinotori-latex-membership-subsets-v1"


def _canonical_json_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


class WeakFormulaDataset(Dataset[dict[str, object]]):
    """Load formulas whose final LaTeX fully maps to the 229-symbol vocabulary.

    Rows with unsupported lexical units are never silently converted to a
    different target.  They remain excluded until the vocabulary mapping is
    explicitly extended and regenerated.
    """

    def __init__(self, teachers_path: Path, mathwriting_root: Path, vocabulary_path: Path, source_split_path: Path, split: str):
        if split not in {"train", "valid"}:
            raise ValueError("split must be train or valid")
        labels = json.loads(vocabulary_path.read_text(encoding="utf-8")).get("labels")
        if not isinstance(labels, list) or len(labels) != 229 or len(set(labels)) != 229:
            raise ValueError("vocabulary must have exactly 229 unique labels")
        self.index = {label: index for index, label in enumerate(labels)}
        source_split = json.loads(source_split_path.read_text(encoding="utf-8")).get("sourceSplit")
        if not isinstance(source_split, dict) or any(value not in {"train", "valid"} for value in source_split.values()):
            raise ValueError("source split must map direct-anchor sources to train or valid")
        all_rows = [json.loads(line) for line in teachers_path.read_text(encoding="utf-8").splitlines() if line]
        self.excluded_unsupported = sum(bool(row.get("unsupportedTokens")) for row in all_rows)
        self.excluded_heldout = sum(
            row.get("sourceSampleId") in source_split and source_split[row["sourceSampleId"]] == "valid"
            for row in all_rows
            if isinstance(row.get("sourceSampleId"), str)
        )
        self.rows = [
            row for row in all_rows
            if not row.get("unsupportedTokens")
            and (row.get("sourceSampleId") not in source_split or source_split[row["sourceSampleId"]] == "train")
        ]
        if not self.rows:
            raise ValueError("weak formula set has no fully mapped rows")
        self.inkml_dir = mathwriting_root / split
        if not self.inkml_dir.is_dir():
            raise ValueError(f"missing MathWriting {split} directory: {self.inkml_dir}")
        self._balanced_indices, self.sampling_metadata = self._build_balanced_indices()

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> dict[str, object]:
        row = self.rows[index]
        source = row.get("sourceSampleId")
        symbols = row.get("visualSymbols")
        if not isinstance(source, str) or not isinstance(symbols, list) or not symbols or any(not isinstance(symbol, str) or symbol not in self.index for symbol in symbols):
            raise ValueError(f"invalid weak teacher at index {index}")
        path = self.inkml_dir / f"{source}.inkml"
        if not path.is_file():
            raise ValueError(f"weak teacher InkML is missing: {path}")
        traces = read_inkml_traces(path)
        target_counts = torch.zeros(229, dtype=torch.float32)
        for symbol in symbols:
            target_counts[self.index[symbol]] += 1
        return {"traces": [traces[trace_id] for trace_id in sorted(traces)], "targetCounts": target_counts, "sourceSampleId": source}

    def balanced_indices(self) -> list[int]:
        """Return one deterministic, no-replacement pass interleaving observed classes.

        A formula may contain several symbols, so it belongs to every one of its
        observed-class queues.  The scheduler takes at most one still-unseen
        formula from each class on a round, then repeats.  This gives rare
        classes an early opportunity without pretending that a formula has a
        single symbol label or duplicating it within a pass.
        """
        return list(self._balanced_indices)

    def class_stage_indices(self) -> dict[int, list[int]]:
        """Return canonical weak-teacher subsets for all 229 class stages.

        Each populated list contains exactly the formulas whose final-LaTeX
        visual-symbol multiset contains that class.  A formula legitimately
        occurs in several lists when its formula contains several symbols;
        that is the required evidence for each of those class stages, not an
        invented stroke-to-token annotation.
        """
        buckets: dict[int, list[int]] = {index: [] for index in range(229)}
        for row_index, row in enumerate(self.rows):
            symbols = row.get("visualSymbols")
            source = row.get("sourceSampleId")
            if not isinstance(symbols, list) or not isinstance(source, str):
                raise ValueError(f"weak teacher {row_index} has invalid symbols or source")
            for symbol in set(symbols):
                class_index = self.index.get(symbol)
                if class_index is None:
                    raise ValueError(f"weak teacher {row_index} contains out-of-vocabulary symbol {symbol}")
                buckets[class_index].append(row_index)
        for indices in buckets.values():
            indices.sort(key=lambda index: (tuple(sorted(set(self.rows[index]["visualSymbols"]))), self.rows[index]["sourceSampleId"]))
        return buckets

    def materialized_class_stage_indices(self, subsets_path: Path) -> tuple[dict[int, list[int]], dict[str, object]]:
        """Load and prove the generated LaTeX-membership subsets for this train split.

        The artifact is the authoritative selection input for a class-balanced
        update.  It is accepted only when every manifest entry, file hash,
        vocabulary label, and post-source-split membership agrees with the
        weak teachers loaded by this dataset.  This preserves the distinction
        between formula-level LaTeX membership and direct stroke labels.
        """
        manifest_path = subsets_path / "manifest.json"
        if not manifest_path.is_file():
            raise ValueError(f"membership subset manifest is missing: {manifest_path}")
        manifest_bytes = manifest_path.read_bytes()
        try:
            manifest = json.loads(manifest_bytes)
        except json.JSONDecodeError as error:
            raise ValueError(f"membership subset manifest is invalid JSON: {manifest_path}") from error
        if not isinstance(manifest, dict) or manifest.get("contract") != MEMBERSHIP_SUBSET_CONTRACT:
            raise ValueError("membership subset manifest has an incompatible contract")
        labels = [label for label, _ in sorted(self.index.items(), key=lambda item: item[1])]
        if manifest.get("vocabularySHA256") != hashlib.sha256(_canonical_json_bytes(labels)).hexdigest():
            raise ValueError("membership subset vocabulary does not match weak teacher vocabulary")
        subset_rows = manifest.get("subsets")
        if not isinstance(subset_rows, list) or len(subset_rows) != 229:
            raise ValueError("membership subset manifest must contain exactly 229 subsets")

        row_by_source: dict[str, int] = {}
        for row_index, row in enumerate(self.rows):
            source = row.get("sourceSampleId")
            if not isinstance(source, str) or source in row_by_source:
                raise ValueError("weak teacher rows must have unique sourceSampleId values")
            row_by_source[source] = row_index

        loaded: dict[int, list[int]] = {}
        source_split_excluded = 0
        for expected_index, subset in enumerate(subset_rows):
            if not isinstance(subset, dict):
                raise ValueError(f"membership subset {expected_index} is invalid")
            class_index = subset.get("classIndex")
            label = subset.get("label")
            filename = subset.get("file")
            expected_hash = subset.get("memberSHA256")
            expected_count = subset.get("memberFormulaCount")
            if class_index != expected_index or label != labels[expected_index] or not isinstance(filename, str) or not isinstance(expected_hash, str) or not isinstance(expected_count, int):
                raise ValueError(f"membership subset {expected_index} metadata does not match the vocabulary")
            member_path = subsets_path / filename
            if not member_path.is_file():
                raise ValueError(f"membership subset file is missing: {member_path}")
            payload = member_path.read_bytes()
            if hashlib.sha256(payload).hexdigest() != expected_hash:
                raise ValueError(f"membership subset file hash does not match manifest: {member_path}")
            try:
                document = json.loads(payload)
            except json.JSONDecodeError as error:
                raise ValueError(f"membership subset file is invalid JSON: {member_path}") from error
            members = document.get("members") if isinstance(document, dict) else None
            if not isinstance(document, dict) or document.get("contract") != MEMBERSHIP_SUBSET_CONTRACT or document.get("classIndex") != class_index or document.get("label") != label or document.get("memberFormulaCount") != expected_count or not isinstance(members, list) or len(members) != expected_count:
                raise ValueError(f"membership subset file does not match manifest: {member_path}")
            indices: list[int] = []
            seen_sources: set[str] = set()
            for member in members:
                if not isinstance(member, dict) or member.get("split") not in {"train", "valid"} or not isinstance(member.get("sourceSampleId"), str):
                    raise ValueError(f"membership subset has invalid member: {member_path}")
                if member["split"] != "train":
                    continue
                source = member["sourceSampleId"]
                if source in seen_sources:
                    raise ValueError(f"membership subset has duplicate train source: {member_path}")
                seen_sources.add(source)
                row_index = row_by_source.get(source)
                if row_index is None:
                    source_split_excluded += 1
                    continue
                indices.append(row_index)
            loaded[class_index] = sorted(indices, key=lambda index: (tuple(sorted(set(self.rows[index]["visualSymbols"]))), self.rows[index]["sourceSampleId"]))

        expected = self.class_stage_indices()
        if loaded != expected:
            raise ValueError("membership subsets do not exactly match the post-source-split weak teachers")
        metadata: dict[str, object] = {
            "contract": MEMBERSHIP_SUBSET_CONTRACT,
            "manifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
            "trainFormulaCount": len(self.rows),
            "sourceSplitExcludedMembershipCount": source_split_excluded,
            "missingClassIndices": [class_index for class_index, indices in loaded.items() if not indices],
        }
        return loaded, metadata

    def class_conditioned_schedule(self, subsets_path: Path) -> tuple[Tensor, dict[str, object]]:
        """Return one no-replacement pass over every ``(class, W_c)`` pair.

        Row ``[c, row, visit]`` means that the complete weak formula at
        ``row`` is selected from ``W_c`` on its ``visit``-th class turn.  A
        multi-symbol formula consequently appears once for every LaTeX class
        it contains.  Empty weak classes receive one direct-only row with
        ``row == -1``; no weak formula is invented for them.
        """
        memberships, membership_metadata = self.materialized_class_stage_indices(subsets_path)
        weak_pair_count = sum(len(indices) for indices in memberships.values())
        direct_only_classes = [class_index for class_index, indices in memberships.items() if not indices]
        schedule = torch.empty((weak_pair_count + len(direct_only_classes), 3), dtype=torch.int64)
        cursor = 0
        visit = 0
        while cursor < len(schedule):
            for class_index in range(229):
                indices = memberships[class_index]
                if visit < len(indices):
                    schedule[cursor] = torch.tensor([class_index, indices[visit], visit], dtype=torch.int64)
                    cursor += 1
                elif visit == 0 and not indices:
                    # A class without W_c still receives its direct-supervised
                    # update in the first 229-class round.  Delaying it until
                    # after every weak pair would make its sole supervision
                    # effectively absent for almost the entire pass.
                    schedule[cursor] = torch.tensor([class_index, -1, 0], dtype=torch.int64)
                    cursor += 1
            visit += 1
        encoded = schedule.numpy().tobytes()
        metadata: dict[str, object] = {
            "contract": "hinotori-class-conditioned-membership-pass-v1",
            "pairCount": int(schedule.shape[0]),
            "weakPairCount": weak_pair_count,
            "directOnlyClassIndices": direct_only_classes,
            "orderSHA256": hashlib.sha256(encoded).hexdigest(),
            "membershipSubsets": membership_metadata,
        }
        return schedule, metadata

    def class_stage_complement_indices(self) -> dict[int, list[int]]:
        """Return the weak-teacher complement for every class stage.

        The complement contains formulas whose final-LaTeX visual-symbol
        multiset has zero count for the class.  It is formula-level negative
        evidence only: it never invents a stroke-level negative annotation.
        """
        present = self.class_stage_indices()
        all_indices = set(range(len(self.rows)))
        return {
            class_index: sorted(
                all_indices - set(indices),
                key=lambda index: (tuple(sorted(set(self.rows[index]["visualSymbols"]))), self.rows[index]["sourceSampleId"]),
            )
            for class_index, indices in present.items()
        }

    def _build_balanced_indices(self) -> tuple[list[int], dict[str, object]]:
        buckets: dict[int, list[int]] = {index: [] for index in range(229)}
        signatures: list[tuple[tuple[str, ...], str]] = []
        for row_index, row in enumerate(self.rows):
            symbols = row.get("visualSymbols")
            source = row.get("sourceSampleId")
            if not isinstance(symbols, list) or not isinstance(source, str):
                raise ValueError(f"weak teacher {row_index} has invalid symbols or source")
            signature = tuple(sorted(set(symbols)))
            if not signature:
                raise ValueError(f"weak teacher {row_index} has no visual symbols")
            signatures.append((signature, source))
            for symbol in signature:
                if symbol not in self.index:
                    raise ValueError(f"weak teacher {row_index} contains out-of-vocabulary symbol {symbol}")
                buckets[self.index[symbol]].append(row_index)
        for indices in buckets.values():
            indices.sort(key=lambda index: signatures[index])
        observed = [class_index for class_index, indices in buckets.items() if indices]
        missing = [class_index for class_index, indices in buckets.items() if not indices]
        cursor = {class_index: 0 for class_index in observed}
        unseen = set(range(len(self.rows)))
        order: list[int] = []
        while unseen:
            progress = False
            for class_index in observed:
                indices = buckets[class_index]
                while cursor[class_index] < len(indices) and indices[cursor[class_index]] not in unseen:
                    cursor[class_index] += 1
                if cursor[class_index] == len(indices):
                    continue
                row_index = indices[cursor[class_index]]
                cursor[class_index] += 1
                unseen.remove(row_index)
                order.append(row_index)
                progress = True
            if not progress:
                # Every remaining row must be reachable from an observed class.
                # Reaching this branch would mean the class queues violate that
                # invariant, not a condition that can be safely skipped.
                raise RuntimeError("weak class-balanced schedule cannot reach every formula")
        encoded = ",".join(str(index) for index in order).encode("ascii")
        metadata: dict[str, object] = {
            "contract": "hinotori-weak-class-interleaved-v1",
            "observedClassCount": len(observed),
            "missingClassIndices": missing,
            "formulaCount": len(order),
            "orderSHA256": hashlib.sha256(encoded).hexdigest(),
        }
        return order, metadata


def collate_weak_formulas(samples: list[dict[str, object]]) -> dict[str, object]:
    """Keep raw stroke trajectories and target multisets without invented groups."""
    if not samples:
        raise ValueError("cannot collate an empty weak formula batch")
    if not all(isinstance(sample.get("traces"), list) and sample["traces"] for sample in samples):
        raise ValueError("every weak sample needs nonempty traces")
    counts = [sample.get("targetCounts") for sample in samples]
    if not all(isinstance(count, Tensor) and tuple(count.shape) == (229,) and count.sum() > 0 for count in counts):
        raise ValueError("every weak sample needs nonempty [229] targetCounts")
    return {"traces": [sample["traces"] for sample in samples], "targetCounts": torch.stack(counts), "sourceSampleIds": [sample["sourceSampleId"] for sample in samples]}
