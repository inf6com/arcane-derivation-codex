#!/usr/bin/env python3
"""Train the whole-formula sequence-to-sequence recognizer on real
MathWriting-2024 data.

This is the GPU-scale handoff script: it is written and unit-tested from a
CPU-only, 2-core cloud sandbox that has neither a GPU nor a local copy of
the full dataset, so it has only been run here against a tiny fixed-fixture
smoke test (see smoke_test_formula_whole_model.py), never against the real
229,864-example train split. Run it on a machine with the real dataset and
a GPU (or Apple Silicon MPS); do not report training-split or valid-split
numbers from anywhere else as measured.

Usage:
    python3 train_formula_whole_model.py \
        --dataset-root /Volumes/ORICO/Developer/inf6-training/dataset \
        --tokenizer formula-whole-label-tokenizer-20260927.json \
        --output-dir runs/formula-whole-v1 \
        --epochs 20 --batch-size 32 --device mps

`test` is never read by this script. Model selection must use `valid` only.
"""
from __future__ import annotations

import argparse
import json
import random
import time
from dataclasses import asdict, dataclass
from pathlib import Path

import torch
from torch import nn
from torch.nn import functional as F
from torch.utils.data import DataLoader, Dataset, Sampler

try:  # `python3 -m ModelConversion.train_formula_whole_model` from the repo root
    from ModelConversion.formula_whole_input import FormulaInputError, load_formula_input, model_features, trace_geometry_features
    from ModelConversion.formula_whole_model import (
        MAX_TRACES,
        FormulaTokenizer,
        FormulaWholeModel,
        TooManyTracesError,
        load_tokenizer,
        model_input_contract,
        prepare_traces,
        prepare_trace_geometry,
        require_checkpoint_input_contract,
        tokenize_structure,
        verify_execution_device,
    )
except ImportError:  # run directly from inside ModelConversion/
    from formula_whole_input import FormulaInputError, load_formula_input, model_features, trace_geometry_features
    from formula_whole_model import (
        MAX_TRACES,
        FormulaTokenizer,
        FormulaWholeModel,
        TooManyTracesError,
        load_tokenizer,
        model_input_contract,
        prepare_traces,
        prepare_trace_geometry,
        require_checkpoint_input_contract,
        tokenize_structure,
        verify_execution_device,
    )


class FormulaWholeDataset(Dataset):
    """Indexes InkML paths and parses exactly one example per access.

    The full train split is too large to materialize as tensors in memory.
    Invalid input is a hard error with its source path; it is never silently
    skipped or represented as a fake training example.
    """

    def __init__(self, split_root: Path, tokenizer: FormulaTokenizer, limit: int | None = None):
        self.tokenizer = tokenizer
        self.paths = sorted(p for p in split_root.iterdir() if p.name.endswith(".inkml"))
        if limit is not None:
            self.paths = self.paths[:limit]

    def __len__(self) -> int:
        return len(self.paths)

    def __getitem__(self, index: int):
        path = self.paths[index]
        try:
            formula, metadata = load_formula_input(path)
            traces = model_features(formula)
            trace_tensor = prepare_traces(traces)
            geometry_tensor = prepare_trace_geometry(list(trace_geometry_features(formula)))
            if trace_tensor.shape[0] != geometry_tensor.shape[0]:
                raise RuntimeError("trace and trace-geometry counts differ")
            tokens = torch.tensor(self.tokenizer.encode(metadata["normalizedLabel"]), dtype=torch.long)
        except (FormulaInputError, TooManyTracesError, ValueError) as error:
            raise RuntimeError(f"invalid whole-formula training input: {path}: {error}") from error
        return trace_tensor, geometry_tensor, tokens, metadata["normalizedLabel"]

    def non_matrix_latex_command_groups(self) -> list[bool]:
        """Classify only this dataset's labels for the train sampler."""
        groups: list[bool] = []
        for path in self.paths:
            try:
                _formula, metadata = load_formula_input(path)
            except (FormulaInputError, TooManyTracesError, ValueError) as error:
                raise RuntimeError(f"invalid whole-formula sampling input: {path}: {error}") from error
            label = metadata["normalizedLabel"]
            groups.append(has_non_matrix_latex_command(label))
        return groups


class LatexCommandWeightedSampler(Sampler[int]):
    """Deterministic replacement sampler for the single train-only candidate."""

    def __init__(self, groups: list[bool], multiplier: float, seed: int):
        if not groups:
            raise ValueError("cannot sample an empty train dataset")
        if multiplier <= 1.0:
            raise ValueError("weighted sampler requires a multiplier greater than 1")
        self.groups = groups
        self.num_samples = len(groups)
        self.weights = torch.tensor([multiplier if group else 1.0 for group in groups], dtype=torch.double)
        self.generator = torch.Generator(device="cpu")
        self.generator.manual_seed(seed)
        positive = sum(groups)
        negative = len(groups) - positive
        denominator = multiplier * positive + negative
        self.source_group_counts = {"nonMatrixLatexCommand": positive, "other": negative}
        self.expected_draw_group_rate = positive * multiplier / denominator if denominator else 0.0
        self.last_draw_group_counts: dict[str, int] | None = None

    def __iter__(self):
        indices = torch.multinomial(self.weights, self.num_samples, replacement=True, generator=self.generator).tolist()
        positive = sum(self.groups[index] for index in indices)
        self.last_draw_group_counts = {
            "nonMatrixLatexCommand": positive,
            "other": len(indices) - positive,
        }
        return iter(indices)

    def __len__(self) -> int:
        return self.num_samples


def non_matrix_command_token_counts(
    dataset: FormulaWholeDataset, tokenizer: FormulaTokenizer, length_conditional: bool = False
) -> dict[str, int]:
    """Count train target tokens for the loss-weight candidate only."""
    examples = 0
    command_tokens = 0
    target_tokens = 0
    for path in dataset.paths:
        try:
            _formula, metadata = load_formula_input(path)
        except (FormulaInputError, TooManyTracesError, ValueError) as error:
            raise RuntimeError(f"invalid whole-formula loss-weight input: {path}: {error}") from error
        label = metadata["normalizedLabel"]
        pieces = tokenize_structure(label)
        target_tokens += len(pieces) + 1
        command_tokens_for_label = (
            length_conditional_latex_command_tokens(label)
            if length_conditional
            else non_matrix_latex_command_tokens(label)
        )
        command_tokens += len(command_tokens_for_label)
        examples += int(bool(command_tokens_for_label))
    return {
        "examplesWithNonMatrixLatexCommand": examples,
        "nonMatrixLatexCommandTargetTokens": command_tokens,
        "targetTokens": target_tokens,
    }


def non_matrix_latex_command_tokens(label: str) -> list[str]:
    pieces = tokenize_structure(label)
    if "\\begin{matrix}" in label or "\\end{matrix}" in label:
        return []
    return [token for token in pieces if is_non_matrix_latex_command(token)]


def length_conditional_latex_command_tokens(label: str) -> list[str]:
    if len(label) <= 10:
        return []
    return non_matrix_latex_command_tokens(label)


def is_non_matrix_latex_command(token: str) -> bool:
    return token.startswith("\\") and token not in {"\\\\", "\\begin", "\\end"}


def weighted_training_loss(
    logits: torch.Tensor,
    target_output: torch.Tensor,
    labels: list[str],
    tokenizer: FormulaTokenizer,
    multiplier: float,
    label_smoothing: float,
    length_conditional: bool = False,
    script_digit_multiplier: float = 1.0,
) -> tuple[torch.Tensor, int, int]:
    """Apply one explicit train-only token weight and return audit counts."""
    per_token = syntax_masked_cross_entropy(logits, target_output, tokenizer.pad_id, label_smoothing)
    valid = target_output != tokenizer.pad_id
    weights = torch.ones_like(per_token)
    weighted_count = 0
    script_digit_ids = {tokenizer.token_to_id[token] for token in ("^", "_", *"0123456789")}
    for row, label in enumerate(labels):
        target_commands = set(
            length_conditional_latex_command_tokens(label)
            if length_conditional
            else non_matrix_latex_command_tokens(label)
        )
        for position in valid[row].nonzero(as_tuple=False).flatten().tolist():
            token_id = int(target_output[row, position].item())
            token = tokenizer.tokens[token_id]
            if script_digit_multiplier > 1.0 and token_id in script_digit_ids:
                weights[row, position] = script_digit_multiplier
                weighted_count += 1
            elif token in target_commands:
                weights[row, position] = multiplier
                weighted_count += 1
    loss = (per_token * weights * valid).sum() / valid.sum().clamp_min(1)
    invalid = valid & ~torch.isfinite(per_token)
    if invalid.any():
        positions = invalid.nonzero(as_tuple=False).tolist()
        details = [
            {"label": labels[row], "position": column, "token": tokenizer.tokens[int(target_output[row, column].item())]}
            for row, column in positions[:8]
        ]
        raise ValueError(f"non-finite syntax-masked token loss: {details}")
    return loss, weighted_count, int(valid.sum().item())


def syntax_masked_cross_entropy(logits: torch.Tensor, target: torch.Tensor, pad_id: int, label_smoothing: float) -> torch.Tensor:
    """Compute smoothing only over syntax-legal logits, never over -inf masks."""
    if logits.shape[:-1] != target.shape:
        raise ValueError(f"logit/target shape mismatch: {tuple(logits.shape)} vs {tuple(target.shape)}")
    valid = target != pad_id
    log_probabilities = torch.log_softmax(logits, dim=-1)
    selected = log_probabilities.gather(-1, target.unsqueeze(-1)).squeeze(-1)
    if (valid & ~torch.isfinite(selected)).any():
        raise ValueError("syntax mask excludes an observed target")
    # Padding positions can have a deliberately illegal target logit.  Do not
    # multiply its infinity by a later zero mask; establish zero loss first.
    nll = torch.where(valid, -selected, torch.zeros_like(selected))
    if label_smoothing == 0:
        return torch.where(valid, nll, torch.zeros_like(nll))
    legal = torch.isfinite(logits)
    legal_count = legal.sum(dim=-1).clamp_min(1)
    smooth = -(log_probabilities.masked_fill(~legal, 0).sum(dim=-1) / legal_count)
    loss = (1.0 - label_smoothing) * nll + label_smoothing * torch.where(valid, smooth, torch.zeros_like(smooth))
    return torch.where(valid, loss, torch.zeros_like(loss))


def collate(batch: list[tuple[torch.Tensor, torch.Tensor, torch.Tensor, str]]):
    traces_list, geometry_list, tokens_list, labels = zip(*batch)
    batch_size = len(batch)
    points_per_trace = traces_list[0].shape[1]
    max_traces = max(t.shape[0] for t in traces_list)
    max_len = max(t.shape[0] for t in tokens_list)

    traces_out = torch.zeros(batch_size, max_traces, points_per_trace, 2)
    geometry_out = torch.zeros(batch_size, max_traces, 9)
    trace_mask = torch.ones(batch_size, max_traces, dtype=torch.bool)
    tokens_out = torch.zeros(batch_size, max_len, dtype=torch.long)
    token_mask = torch.ones(batch_size, max_len, dtype=torch.bool)
    for i, (traces, geometry, tokens) in enumerate(zip(traces_list, geometry_list, tokens_list)):
        if traces.shape[0] != geometry.shape[0] or geometry.shape[1] != 9:
            raise ValueError("trace and geometry batch records are misaligned")
        traces_out[i, : traces.shape[0]] = traces
        geometry_out[i, : geometry.shape[0]] = geometry
        trace_mask[i, : traces.shape[0]] = False
        tokens_out[i, : tokens.shape[0]] = tokens
        token_mask[i, : tokens.shape[0]] = False
    return traces_out, geometry_out, trace_mask, tokens_out, token_mask, list(labels)


@dataclass
class TrainConfig:
    d_model: int = 128
    heads: int = 4
    dim_feedforward: int = 256
    dropout: float = 0.1
    batch_size: int = 32
    epochs: int = 20
    lr: float = 3e-4
    label_smoothing: float = 0.1
    latex_command_sampling_weight: float = 1.0
    latex_command_loss_weight: float = 1.0
    length_conditional_latex_command_loss_weight: float = 1.0
    script_digit_loss_weight: float = 1.0
    seed: int = 0
    train_limit: int | None = None
    valid_limit: int | None = None
    eval_every_steps: int = 500
    device: str = "cpu"


def run_validation(model: FormulaWholeModel, loader: DataLoader, tokenizer: FormulaTokenizer, criterion, device: str, max_decode_batches: int = 4) -> dict[str, float]:
    model.eval()
    total_loss = 0.0
    total_tokens = 0
    exact_matches = 0
    total_decoded = 0
    token_errors = script_total = script_errors = digit_total = digit_errors = 0
    script_ids = {tokenizer.token_to_id[token] for token in ("^", "_")}
    digit_ids = {tokenizer.token_to_id[token] for token in "0123456789"}
    with torch.no_grad():
        for batch_index, (traces, geometry, trace_mask, tokens, token_mask, labels) in enumerate(loader):
            traces, geometry, trace_mask = traces.to(device), geometry.to(device), trace_mask.to(device)
            tokens, token_mask = tokens.to(device), token_mask.to(device)
            target_input = tokens[:, :-1]
            target_output = tokens[:, 1:]
            target_input_mask = token_mask[:, :-1]
            logits = model.syntax_masked_forward(traces, geometry, trace_mask, target_input, target_input_mask, tokenizer)
            loss = syntax_masked_cross_entropy(logits, target_output, tokenizer.pad_id, criterion.label_smoothing)
            loss = loss[target_output != tokenizer.pad_id].mean()
            if not torch.isfinite(loss):
                raise FloatingPointError(f"non-finite validation loss at batch {batch_index}: {loss.item()}")
            non_pad = (target_output != tokenizer.pad_id).sum().item()
            total_loss += loss.item() * non_pad
            total_tokens += non_pad
            prediction = logits.argmax(dim=-1)
            non_pad_mask = target_output != tokenizer.pad_id
            token_errors += int((prediction.ne(target_output) & non_pad_mask).sum().item())
            script_mask = torch.zeros_like(target_output, dtype=torch.bool)
            digit_mask = torch.zeros_like(target_output, dtype=torch.bool)
            for token_id in script_ids:
                script_mask |= target_output == token_id
            for token_id in digit_ids:
                digit_mask |= target_output == token_id
            script_total += int(script_mask.sum().item())
            digit_total += int(digit_mask.sum().item())
            script_errors += int((prediction.ne(target_output) & script_mask).sum().item())
            digit_errors += int((prediction.ne(target_output) & digit_mask).sum().item())

            if batch_index < max_decode_batches:
                decoded = model.greedy_decode(traces, geometry, trace_mask, tokenizer, max_length=tokens.shape[1] + 4)
                for row, label in zip(decoded, labels):
                    predicted = tokenizer.decode(row)
                    exact_matches += int(predicted == label)
                    total_decoded += 1
    return {
        "lossPerToken": total_loss / max(total_tokens, 1),
        "exactMatch": exact_matches / max(total_decoded, 1),
        "exactMatchSampleSize": total_decoded,
        "teacherForcedTokenAccuracy": 1.0 - token_errors / max(total_tokens, 1),
        "scriptTokenErrorRate": script_errors / max(script_total, 1),
        "scriptTokenCount": script_total,
        "digitTokenErrorRate": digit_errors / max(digit_total, 1),
        "digitTokenCount": digit_total,
    }


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def save_checkpoint(model: FormulaWholeModel, checkpoint: Path, tokenizer: Path) -> None:
    """Persist a model only with the exact feature contract needed to load it."""
    torch.save(model.state_dict(), checkpoint)
    write_json(
        checkpoint.parent / "checkpoint-contract.json",
        {
            "checkpoint": checkpoint.name,
            "inputContract": model_input_contract(),
            "modelArchitecture": model.architecture,
            "tokenizer": str(tokenizer),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True, help="directory containing mathwriting-2024/")
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--d-model", type=int, default=128)
    parser.add_argument("--dropout", type=float, default=0.1)
    parser.add_argument("--device", type=str, default="mps", help="mps by default; CPU requires measured MPS unavailability or --cpu-comparison")
    parser.add_argument("--cpu-comparison", action="store_true", help="explicit CPU-only control run for a measured MPS/CPU comparison; never a production candidate")
    parser.add_argument("--train-limit", type=int, default=None, help="cap on train examples, for a bounded local test run")
    parser.add_argument("--valid-limit", type=int, default=None)
    parser.add_argument("--validation-split", choices=("train", "valid"), default="valid", help="split used for validation; train is diagnostic-only")
    parser.add_argument("--eval-every-steps", type=int, default=500)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--label-smoothing", type=float, default=0.1)
    parser.add_argument(
        "--latex-command-sampling-weight",
        type=float,
        default=1.0,
        help="train-only replacement-sampler multiplier for non-matrix LaTeX-command labels; 1 disables the candidate",
    )
    parser.add_argument(
        "--latex-command-loss-weight",
        type=float,
        default=1.0,
        help="train-only target-token loss multiplier for non-matrix LaTeX commands; 1 disables the candidate",
    )
    parser.add_argument(
        "--length-conditional-latex-command-loss-weight",
        type=float,
        default=1.0,
        help="train-only target-token loss multiplier for non-matrix LaTeX commands in labels longer than 10 characters; 1 disables the candidate",
    )
    parser.add_argument(
        "--script-digit-loss-weight",
        type=float,
        default=1.0,
        help="train-only token-ID loss multiplier for ^, _, and digits; 1 disables the candidate",
    )
    parser.add_argument("--resume-checkpoint", type=Path, default=None, help="load a compatible FormulaWholeModel state dict before continuing")
    parser.add_argument("--encoder-checkpoint", type=Path, default=None, help="strictly initialize model.encoder from a real symbol-pretraining state dict")
    args = parser.parse_args()

    config = TrainConfig(
        d_model=args.d_model,
        dropout=args.dropout,
        batch_size=args.batch_size,
        epochs=args.epochs,
        lr=args.lr,
        train_limit=args.train_limit,
        valid_limit=args.valid_limit,
        eval_every_steps=args.eval_every_steps,
        seed=args.seed,
        device=args.device,
        label_smoothing=args.label_smoothing,
        latex_command_sampling_weight=args.latex_command_sampling_weight,
        latex_command_loss_weight=args.latex_command_loss_weight,
        length_conditional_latex_command_loss_weight=args.length_conditional_latex_command_loss_weight,
        script_digit_loss_weight=args.script_digit_loss_weight,
    )
    random.seed(config.seed)
    torch.manual_seed(config.seed)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    started_at = time.time()
    manifest_path = args.output_dir / "run-manifest.json"
    manifest = {
        "status": "RUNNING",
        "startedAtUnix": started_at,
        "datasetRoot": str(args.dataset_root),
        "tokenizer": str(args.tokenizer),
        "resumeCheckpoint": str(args.resume_checkpoint) if args.resume_checkpoint is not None else None,
        "encoderCheckpoint": str(args.encoder_checkpoint) if args.encoder_checkpoint is not None else None,
        "config": asdict(config),
        "datasetMode": "on-demand path-index; no tensor pre-materialization",
        "inputContract": model_input_contract(),
        "splits": {"train": "mathwriting-2024/train", "validation": f"mathwriting-2024/{args.validation_split}", "test": "not opened"},
    }
    write_json(manifest_path, manifest)

    try:
        manifest["executionDeviceEvidence"] = verify_execution_device(config.device, cpu_comparison=args.cpu_comparison)
        manifest["executionRole"] = "cpu-comparison-control" if args.cpu_comparison else "production-candidate"
        write_json(manifest_path, manifest)
        tokenizer = load_tokenizer(args.tokenizer)
        dataset_root = args.dataset_root / "mathwriting-2024"

        print("indexing train split paths (InkML tensors are parsed on demand)...")
        train_dataset = FormulaWholeDataset(dataset_root / "train", tokenizer, limit=config.train_limit)
        print("indexing valid split paths...")
        valid_dataset = FormulaWholeDataset(dataset_root / args.validation_split, tokenizer, limit=config.valid_limit)
        # `test` is intentionally never opened by this script.

        manifest["trainPathCount"] = len(train_dataset)
        manifest["validPathCount"] = len(valid_dataset)
        write_json(manifest_path, manifest)
        print(f"train: {len(train_dataset)} indexed paths")
        print(f"valid: {len(valid_dataset)} indexed paths")

        sampling_manifest: dict[str, object] = {
            "mode": "uniform_shuffle",
            "multiplier": 1.0,
            "sourceGroupCounts": None,
            "expectedDrawGroupRate": None,
            "epochs": [],
        }
        train_sampler: LatexCommandWeightedSampler | None = None
        if config.latex_command_sampling_weight > 1.0:
            train_groups = train_dataset.non_matrix_latex_command_groups()
            train_sampler = LatexCommandWeightedSampler(train_groups, config.latex_command_sampling_weight, config.seed)
            sampling_manifest.update(
                {
                    "mode": "replacement_weighted",
                    "multiplier": config.latex_command_sampling_weight,
                    "sourceGroupCounts": train_sampler.source_group_counts,
                    "expectedDrawGroupRate": train_sampler.expected_draw_group_rate,
                }
            )
        elif config.latex_command_sampling_weight < 1.0:
            raise ValueError("--latex-command-sampling-weight must be at least 1.0")
        if config.latex_command_loss_weight < 1.0:
            raise ValueError("--latex-command-loss-weight must be at least 1.0")
        if config.length_conditional_latex_command_loss_weight < 1.0:
            raise ValueError("--length-conditional-latex-command-loss-weight must be at least 1.0")
        if config.script_digit_loss_weight < 1.0:
            raise ValueError("--script-digit-loss-weight must be at least 1.0")
        enabled_candidates = sum(
            value > 1.0
            for value in (
                config.latex_command_sampling_weight,
                config.latex_command_loss_weight,
                config.length_conditional_latex_command_loss_weight,
                config.script_digit_loss_weight,
            )
        )
        if enabled_candidates > 1:
            raise ValueError("sampler and loss-weight candidates cannot be enabled together")
        loss_weight_manifest: dict[str, object] = {
            "mode": "uniform_token_loss",
            "multiplier": 1.0,
            "sourceCounts": None,
            "epochs": [],
        }
        if config.latex_command_loss_weight > 1.0:
            loss_weight_manifest.update(
                {
                    "mode": "non_matrix_latex_command_token_loss",
                    "multiplier": config.latex_command_loss_weight,
                    "sourceCounts": non_matrix_command_token_counts(train_dataset, tokenizer),
                }
            )
        if config.length_conditional_latex_command_loss_weight > 1.0:
            loss_weight_manifest.update(
                {
                    "mode": "length_conditional_non_matrix_latex_command_token_loss",
                    "multiplier": config.length_conditional_latex_command_loss_weight,
                    "labelLengthPredicate": "len(normalizedLabel) > 10",
                    "sourceCounts": non_matrix_command_token_counts(train_dataset, tokenizer, length_conditional=True),
                }
            )
        if config.script_digit_loss_weight > 1.0:
            script_digit_tokens = ("^", "_", *"0123456789")
            loss_weight_manifest.update(
                {
                    "mode": "script_digit_token_id_loss",
                    "multiplier": config.script_digit_loss_weight,
                    "tokenIDs": {token: tokenizer.token_to_id[token] for token in script_digit_tokens},
                }
            )
        manifest["trainSampling"] = sampling_manifest
        manifest["trainLossWeighting"] = loss_weight_manifest
        write_json(manifest_path, manifest)
        train_loader = DataLoader(
            train_dataset,
            batch_size=config.batch_size,
            shuffle=train_sampler is None,
            sampler=train_sampler,
            collate_fn=collate,
            num_workers=0,
        )
        valid_loader = DataLoader(valid_dataset, batch_size=config.batch_size, shuffle=False, collate_fn=collate, num_workers=0)

        device = args.device
        model = FormulaWholeModel(
            vocab_size=tokenizer.vocab_size, d_model=config.d_model, heads=config.heads, dim_feedforward=config.dim_feedforward, dropout=config.dropout
        ).to(device)
        if args.resume_checkpoint is not None and args.encoder_checkpoint is not None:
            raise ValueError("--resume-checkpoint and --encoder-checkpoint cannot be combined")
        if args.resume_checkpoint is not None:
            require_checkpoint_input_contract(args.resume_checkpoint)
            state = torch.load(args.resume_checkpoint, map_location=device, weights_only=True)
            model.load_state_dict(state)
            print(f"resumed checkpoint: {args.resume_checkpoint}")
        if args.encoder_checkpoint is not None:
            encoder_state = torch.load(args.encoder_checkpoint, map_location=device, weights_only=True)
            if not isinstance(encoder_state, dict):
                raise ValueError(f"encoder checkpoint is not a state dict: {args.encoder_checkpoint}")
            expected = model.encoder.state_dict()
            missing = sorted(set(expected) - set(encoder_state))
            unexpected = sorted(set(encoder_state) - set(expected))
            shape_mismatch = [key for key in sorted(set(expected) & set(encoder_state)) if expected[key].shape != encoder_state[key].shape]
            if missing or unexpected or shape_mismatch:
                raise ValueError(f"encoder checkpoint incompatible: missing={missing}, unexpected={unexpected}, shapeMismatch={shape_mismatch}")
            model.encoder.load_state_dict(encoder_state, strict=True)
            manifest["encoderInitialization"] = {"kind": "symbol-pretrained", "checkpoint": str(args.encoder_checkpoint), "transfer": "strict pass"}
        else:
            manifest["encoderInitialization"] = {"kind": "random" if args.resume_checkpoint is None else "resume"}
        write_json(manifest_path, manifest)
        optimizer = torch.optim.AdamW(model.parameters(), lr=config.lr)
        criterion = nn.CrossEntropyLoss(ignore_index=tokenizer.pad_id, label_smoothing=config.label_smoothing)

        history: list[dict[str, float]] = []
        best_valid_loss = float("inf")
        step = 0
        last_train_loss = float("nan")

        for epoch in range(config.epochs):
            model.train()
            epoch_command_tokens = 0
            epoch_target_tokens = 0
            for traces, geometry, trace_mask, tokens, token_mask, labels in train_loader:
                traces, geometry, trace_mask = traces.to(device), geometry.to(device), trace_mask.to(device)
                tokens, token_mask = tokens.to(device), token_mask.to(device)
                target_input = tokens[:, :-1]
                target_output = tokens[:, 1:]
                target_input_mask = token_mask[:, :-1]

                optimizer.zero_grad()
                logits = model.syntax_masked_forward(traces, geometry, trace_mask, target_input, target_input_mask, tokenizer)
                selected_logits = logits.gather(-1, target_output.unsqueeze(-1)).squeeze(-1)
                invalid_targets = (target_output != tokenizer.pad_id) & ~torch.isfinite(selected_logits)
                if invalid_targets.any():
                    positions = invalid_targets.nonzero(as_tuple=False).tolist()
                    details = [
                        {"label": labels[row], "position": column, "token": tokenizer.tokens[int(target_output[row, column].item())]}
                        for row, column in positions[:8]
                    ]
                    raise ValueError(f"syntax mask excludes observed train targets: {details}")
                active_loss_weight = (
                    config.length_conditional_latex_command_loss_weight
                    if config.length_conditional_latex_command_loss_weight > 1.0
                    else config.latex_command_loss_weight
                )
                loss, command_count, target_count = weighted_training_loss(
                    logits,
                    target_output,
                    labels,
                    tokenizer,
                    active_loss_weight,
                    config.label_smoothing,
                    length_conditional=config.length_conditional_latex_command_loss_weight > 1.0,
                    script_digit_multiplier=config.script_digit_loss_weight,
                )
                epoch_command_tokens += command_count
                epoch_target_tokens += target_count
                if not torch.isfinite(loss):
                    raise FloatingPointError(f"non-finite training loss at step {step + 1}: {loss.item()}")
                loss.backward()
                optimizer.step()
                step += 1
                last_train_loss = loss.item()

                if step % config.eval_every_steps == 0:
                    valid_metrics = run_validation(model, valid_loader, tokenizer, criterion, device)
                    record = {"step": step, "epoch": epoch, "trainLoss": last_train_loss, **valid_metrics}
                    history.append(record)
                    manifest["lastStep"] = step
                    manifest["latestMetrics"] = record
                    write_json(manifest_path, manifest)
                    print(json.dumps(record))
                    if valid_metrics["lossPerToken"] < best_valid_loss:
                        best_valid_loss = valid_metrics["lossPerToken"]
                        save_checkpoint(model, args.output_dir / "best.pt", args.tokenizer)

            valid_metrics = run_validation(model, valid_loader, tokenizer, criterion, device)
            if train_sampler is not None:
                sampling_manifest["epochs"].append(
                    {
                        "epoch": epoch,
                        "drawGroupCounts": train_sampler.last_draw_group_counts,
                        "drawGroupRate": (train_sampler.last_draw_group_counts or {}).get("nonMatrixLatexCommand", 0)
                        / max(len(train_dataset), 1),
                    }
                )
                manifest["trainSampling"] = sampling_manifest
                write_json(manifest_path, manifest)
            if config.latex_command_loss_weight > 1.0 or config.length_conditional_latex_command_loss_weight > 1.0 or config.script_digit_loss_weight > 1.0:
                loss_weight_manifest["epochs"].append(
                    {
                        "epoch": epoch,
                        "weightedTargetTokenCount": epoch_command_tokens,
                        "targetTokenCount": epoch_target_tokens,
                        "weightedTargetTokenRate": epoch_command_tokens / max(epoch_target_tokens, 1),
                    }
                )
                manifest["trainLossWeighting"] = loss_weight_manifest
                write_json(manifest_path, manifest)
            record = {"step": step, "epoch": epoch, "trainLoss": last_train_loss, **valid_metrics, "epochEnd": True}
            history.append(record)
            print(json.dumps(record))
            if valid_metrics["lossPerToken"] < best_valid_loss:
                best_valid_loss = valid_metrics["lossPerToken"]
                save_checkpoint(model, args.output_dir / "best.pt", args.tokenizer)

        report = {
            "config": asdict(config),
            "datasetMode": "on-demand path-index; no tensor pre-materialization",
            "trainUsable": len(train_dataset),
            "trainSkipped": [],
            "validUsable": len(valid_dataset),
            "validSkipped": [],
            "bestValidLossPerToken": best_valid_loss,
            "history": history,
            "elapsedSeconds": time.time() - started_at,
            "note": "test split was never opened by this script; run a separate one-time test evaluation only after model selection is finalized on valid.",
        }
        report_path = args.output_dir / "training-report.json"
        write_json(report_path, report)
        manifest.update({"status": "COMPLETED", "completedAtUnix": time.time(), "trainingReport": str(report_path), "checkpoint": str(args.output_dir / "best.pt")})
        write_json(manifest_path, manifest)
        print(f"wrote {report_path}")
        return 0
    except (Exception, KeyboardInterrupt) as error:
        status = "CANCELLED" if isinstance(error, KeyboardInterrupt) else "FAILED"
        manifest.update({"status": status, "failedAtUnix": time.time(), "failure": str(error) or status})
        write_json(manifest_path, manifest)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
