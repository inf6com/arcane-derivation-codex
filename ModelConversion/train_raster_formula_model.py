#!/usr/bin/env python3
"""Train and evaluate the FormulaRasterV1-only direct image-to-LaTeX model."""
from __future__ import annotations
import argparse, json, subprocess
from pathlib import Path
import torch
from torch.nn import functional as F
from torch.utils.data import DataLoader, Dataset
from formula_whole_input import load_formula_input
from formula_whole_model import load_tokenizer
from raster_formula_model import RasterFormulaModel, raster_tensor

class InkMLRasterDataset(Dataset):
    def __init__(self, root: Path, tokenizer_path: Path, limit: int, max_tokens: int):
        self.tokenizer = load_tokenizer(tokenizer_path)
        files = sorted(root.glob("*.inkml"))
        if not files: raise ValueError(f"no InkML files in {root}")
        if limit <= 0: raise ValueError("limit must be positive")
        self.files = files[:limit]
        self.max_tokens = max_tokens
    def __len__(self): return len(self.files)
    def __getitem__(self, index):
        formula, metadata = load_formula_input(self.files[index])
        encoded = self.tokenizer.encode(metadata["normalizedLabel"])
        if len(encoded) > self.max_tokens: raise ValueError(f"target exceeds max_tokens: {self.files[index]}")
        return raster_tensor(formula), torch.tensor(encoded, dtype=torch.long), metadata["normalizedLabel"], self.files[index].name

def collate(items):
    rasters, sequences, labels, names = zip(*items)
    width = max(value.numel() for value in sequences)
    pad = sequences[0].new_full((len(sequences), width), 0)
    for i, value in enumerate(sequences): pad[i, :value.numel()] = value
    return torch.stack(rasters), pad, list(labels), list(names)

def edit_distance(left: str, right: str) -> int:
    row = list(range(len(right) + 1))
    for i, char in enumerate(left, 1):
        next_row = [i]
        for j, other in enumerate(right, 1): next_row.append(min(next_row[-1] + 1, row[j] + 1, row[j - 1] + (char != other)))
        row = next_row
    return row[-1]

def mathml_results(binary: Path, labels: list[str]) -> list[bool]:
    run = subprocess.run([str(binary)], input=("\n".join(labels)).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    values = json.loads(run.stdout)
    if len(values) != len(labels): raise ValueError("MathML validator returned wrong result count")
    return [value["ok"] is True for value in values]

def decode(model, raster, tokenizer, max_tokens):
    tokens = torch.full((raster.shape[0], 1), tokenizer.bos_id, dtype=torch.long, device=raster.device)
    ended = torch.zeros(raster.shape[0], dtype=torch.bool, device=raster.device)
    for _ in range(max_tokens - 1):
        next_token = model(raster, tokens)[:, -1].argmax(-1)
        tokens = torch.cat((tokens, next_token[:, None]), 1)
        ended |= next_token.eq(tokenizer.eos_id)
        if bool(ended.all()): break
    return [tokenizer.decode(row.tolist()) for row in tokens]

def evaluate(model, dataset, batch_size, device, validator, max_tokens):
    model.eval(); predictions=[]; targets=[]; names=[]
    with torch.no_grad():
        for raster, _, labels, batch_names in DataLoader(dataset, batch_size=batch_size, shuffle=False, collate_fn=collate):
            predictions += decode(model, raster.to(device), dataset.tokenizer, max_tokens); targets += labels; names += batch_names
    converted = mathml_results(validator, predictions)
    exact = sum(x == y for x, y in zip(predictions, targets)); edits = [edit_distance(x, y) for x, y in zip(predictions, targets)]
    eos = sum(len(prediction) < max_tokens - 1 for prediction in predictions)
    return {"latexExactMatch": exact / len(targets), "latexExactCount": exact, "characterEditDistanceMean": sum(edits) / len(edits), "mathMLConversionRate": sum(converted) / len(converted), "mathMLConversionCount": sum(converted), "eosOutputCount": eos}, [{"file": n, "target": t, "prediction": q, "mathMLConvertible": c} for n,t,q,c in zip(names,targets,predictions,converted)]

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--train-root", type=Path, required=True); p.add_argument("--valid-root", type=Path, required=True)
    p.add_argument("--tokenizer", type=Path, required=True); p.add_argument("--mathml-validator", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True); p.add_argument("--train-limit", type=int, default=256); p.add_argument("--valid-limit", type=int, default=64)
    p.add_argument("--epochs", type=int, default=1); p.add_argument("--batch-size", type=int, default=4); p.add_argument("--d-model", type=int, default=192); p.add_argument("--max-tokens", type=int, default=128)
    p.add_argument("--diagnostic-train16", action="store_true", help="measure direct train16 convergence every epoch; not a valid gate")
    a = p.parse_args()
    if not torch.backends.mps.is_available(): raise RuntimeError("MPS is required; refusing CPU/CUDA substitution")
    if not a.mathml_validator.is_file(): raise FileNotFoundError(a.mathml_validator)
    device = torch.device("mps")
    train = InkMLRasterDataset(a.train_root, a.tokenizer, a.train_limit, a.max_tokens); valid = InkMLRasterDataset(a.valid_root, a.tokenizer, a.valid_limit, a.max_tokens)
    model = RasterFormulaModel(train.tokenizer.vocab_size, a.d_model).to(device); optimizer = torch.optim.AdamW(model.parameters(), lr=3e-4)
    if a.diagnostic_train16 and a.train_limit != 16: raise ValueError("--diagnostic-train16 requires --train-limit 16 exactly")
    epoch_metrics=[]
    for epoch in range(1, a.epochs + 1):
        model.train()
        for raster, target, _, _ in DataLoader(train, batch_size=a.batch_size, shuffle=True, collate_fn=collate):
            raster, target = raster.to(device), target.to(device); logits = model(raster, target[:, :-1]); loss = F.cross_entropy(logits.reshape(-1, logits.shape[-1]), target[:, 1:].reshape(-1), ignore_index=train.tokenizer.pad_id)
            if not torch.isfinite(loss): raise RuntimeError("non-finite raster training loss")
            optimizer.zero_grad(); loss.backward(); optimizer.step()
        if a.diagnostic_train16:
            metrics, _ = evaluate(model, train, a.batch_size, device, a.mathml_validator, a.max_tokens)
            epoch_metrics.append({"epoch": epoch, **metrics})
    metrics, predictions = evaluate(model, valid, a.batch_size, device, a.mathml_validator, a.max_tokens)
    a.output.mkdir(parents=True, exist_ok=True); torch.save({"state_dict": model.state_dict(), "d_model": a.d_model, "vocab_size": train.tokenizer.vocab_size}, a.output / "checkpoint.pt")
    report = {"architecture": "FormulaRasterV1 512x512 PGM -> Conv encoder -> 8x8 spatial patch sequence -> 2-layer cross-attention Transformer normalized-LaTeX decoder", "parameterCount": sum(x.numel() for x in model.parameters()), "optimizer": "AdamW lr=0.0003", "device": "mps", "split": {"trainRoot": str(a.train_root), "validRoot": str(a.valid_root), "trainCount": len(train), "validCount": len(valid), "testOpened": False}, "metrics": metrics, "train16Diagnostic": epoch_metrics if a.diagnostic_train16 else None, "predictions": predictions}
    (a.output / "evaluation.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report["metrics"], ensure_ascii=False))
if __name__ == "__main__": main()
