#!/usr/bin/env python3
"""Train the source-grouped MPS stroke-geometry classifier for 229 symbols."""
from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path

import torch
from torch import Tensor, nn
from torch.utils.data import DataLoader

from hinotori_direct_dataset import DirectAnchorDataset, collate_direct_anchors
from hinotori_raster_classifier import CLASS_COUNT
from hinotori_stroke_geometry_classifier import HinotoriStrokeGeometryClassifier


def augment_trajectories(points: Tensor, stroke_padding: Tensor, point_padding: Tensor) -> Tensor:
    if points.ndim != 4 or points.shape[-1] != 2 or stroke_padding.shape != points.shape[:2] or point_padding.shape != points.shape[:3]:
        raise ValueError("trajectory batch shapes do not match [batch,stroke,point,2]")
    batch = points.shape[0]
    angle = (torch.rand(batch, dtype=points.dtype) * 2.0 - 1.0) * 0.08
    scale = 0.90 + torch.rand(batch, dtype=points.dtype) * 0.20
    translate = torch.rand((batch, 2), dtype=points.dtype) * 0.12 - 0.06
    cosine, sine = torch.cos(angle) * scale, torch.sin(angle) * scale
    x, y = points[..., 0], points[..., 1]
    result = torch.stack((cosine[:, None, None] * x - sine[:, None, None] * y,
                          sine[:, None, None] * x + cosine[:, None, None] * y), dim=-1)
    result = result + translate[:, None, None, :]
    invalid = stroke_padding[:, :, None] | point_padding
    return result.masked_fill(invalid.unsqueeze(-1), 0.0)


def evaluate(model: HinotoriStrokeGeometryClassifier, loader: DataLoader, device: torch.device) -> dict[str, object]:
    model.eval()
    confusion = torch.zeros((CLASS_COUNT, CLASS_COUNT), dtype=torch.int64)
    total = top1 = top5 = 0
    with torch.inference_mode():
        for batch in loader:
            points = batch["points"].to(device)
            stroke_padding = batch["strokePadding"].to(device)
            point_padding = batch["pointPadding"].to(device)
            labels = batch["classIndices"].to(device)
            logits, _ = model(points, stroke_padding, point_padding)
            top = logits.topk(5, dim=1).indices
            top1 += int((top[:, 0] == labels).sum())
            top5 += int((top == labels[:, None]).any(1).sum())
            total += labels.numel()
            flat = labels.cpu() * CLASS_COUNT + logits.argmax(1).cpu()
            confusion += torch.bincount(flat, minlength=CLASS_COUNT**2).reshape(CLASS_COUNT, CLASS_COUNT)
    if total == 0:
        raise ValueError("validation partition is empty")
    support = confusion.sum(1)
    observed = support > 0
    recall = confusion.diag()[observed].double() / support[observed]
    return {"sampleCount": total, "top1": top1 / total, "top5": top5 / total,
            "macroRecallSupportedClasses": float(recall.mean()),
            "supportedClassCount": int(observed.sum()), "classSupport": support.tolist(),
            "confusionMatrix": confusion.tolist()}


def source_fingerprint(dataset: DirectAnchorDataset) -> str:
    sources = sorted({str(row["sourceSampleId"]) for row in dataset.rows})
    return hashlib.sha256("\n".join(sources).encode()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--class-weight-power", type=float, default=0.5)
    parser.add_argument("--seed", type=int, default=20261110)
    args = parser.parse_args()
    if args.epochs < 1 or args.batch_size < 1 or args.learning_rate <= 0 or not 0 <= args.class_weight_power <= 1:
        raise ValueError("invalid epochs, batch size, learning rate, or class-weight exponent")
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required; no CPU training fallback is allowed")
    random.seed(args.seed); torch.manual_seed(args.seed)
    if hasattr(torch.mps, "manual_seed"): torch.mps.manual_seed(args.seed)
    device = torch.device("mps")
    train = DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, 128, "train")
    valid = DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, 128, "valid")
    vocabulary_bytes = args.vocabulary.read_bytes()
    vocab_doc = json.loads(vocabulary_bytes)
    vocabulary = vocab_doc.get("labels") if isinstance(vocab_doc, dict) else None
    if not isinstance(vocabulary, list) or len(vocabulary) != CLASS_COUNT or len(set(vocabulary)) != CLASS_COUNT:
        raise ValueError("vocabulary must contain 229 unique labels")
    for row in train.rows + valid.rows:
        if row.get("classIndex") not in range(CLASS_COUNT) or vocabulary[row["classIndex"]] != row.get("label"):
            raise ValueError(f"teacher class mapping mismatch for {row.get('sourceSampleId')}")
    train_sources = {str(r["sourceSampleId"]) for r in train.rows}
    valid_sources = {str(r["sourceSampleId"]) for r in valid.rows}
    if train_sources & valid_sources:
        raise ValueError("source-level leakage between train and inner validation")
    counts = torch.bincount(torch.tensor([int(r["classIndex"]) for r in train.rows]), minlength=CLASS_COUNT)
    if (counts == 0).any(): raise ValueError("fit train does not cover all 229 classes")
    weights = counts.float().pow(-args.class_weight_power); weights = weights / weights.mean(); weights = weights.to(device)
    generator = torch.Generator().manual_seed(args.seed)
    train_loader = DataLoader(train, batch_size=args.batch_size, shuffle=True, collate_fn=collate_direct_anchors, generator=generator)
    valid_loader = DataLoader(valid, batch_size=args.batch_size, shuffle=False, collate_fn=collate_direct_anchors)
    model = HinotoriStrokeGeometryClassifier().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-2)
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = {"architecture":"HinotoriStrokeGeometryClassifier", "task":"isolated_symbol_exact_classification",
        "input":{"kind":"source-coordinate-point-and-undirected-segment-sets","pointCountPerStroke":128,"coordinateChannels":2,
                 "strokeOrderEncoding":False,"withinStrokeDirectionEncoding":False,
                 "strokePermutationAggregation":"symmetric mean and max","withinStrokePointAggregation":"symmetric mean and max",
                 "segmentDirection":"canonical undirected segment vector; stroke reversal invariant"},
        "trainAugmentation":{"kind":"per-group affine","rotationRadiansMaxAbs":0.08,"scaleRange":[0.9,1.1],"translationRangePerAxis":[-0.06,0.06],"flips":False},
        "classWeightPower":args.class_weight_power,"trainClassCounts":counts.tolist(),"device":str(device),"seed":args.seed,
        "trainExamples":len(train),"validExamples":len(valid),"trainSourceFingerprint":source_fingerprint(train),
        "validSourceFingerprint":source_fingerprint(valid),"vocabularySHA256":hashlib.sha256(vocabulary_bytes).hexdigest(),
        "validRole":"checkpoint selection only; not final test"}
    (args.output/"run.json").write_text(json.dumps(metadata,ensure_ascii=False,indent=2),encoding="utf-8")
    best1=best5=-1.0; epoch1=epoch5=0
    with (args.output/"metrics.jsonl").open("x",encoding="utf-8") as history:
        for epoch in range(1,args.epochs+1):
            model.train(); loss_sum=0.0; samples=0
            for batch in train_loader:
                points=augment_trajectories(batch["points"],batch["strokePadding"],batch["pointPadding"]).to(device)
                stroke_padding=batch["strokePadding"].to(device); point_padding=batch["pointPadding"].to(device)
                labels=batch["classIndices"].to(device)
                logits,_=model(points,stroke_padding,point_padding)
                loss=nn.functional.cross_entropy(logits,labels,weight=weights)
                optimizer.zero_grad(set_to_none=True); loss.backward(); optimizer.step()
                loss_sum += float(loss.detach())*labels.numel(); samples += labels.numel()
            score=evaluate(model,valid_loader,device)
            record={"epoch":epoch,"trainCrossEntropy":loss_sum/samples,**score}
            history.write(json.dumps(record,ensure_ascii=False)+"\n"); history.flush()
            checkpoint={"model":model.state_dict(),"epoch":epoch,"run":metadata,"metrics":record}
            torch.save(checkpoint,args.output/"latest.pt")
            if score["top1"]>best1:
                best1=float(score["top1"]);epoch1=epoch;torch.save(checkpoint,args.output/"best.pt")
            if score["top5"]>best5:
                best5=float(score["top5"]);epoch5=epoch;torch.save(checkpoint,args.output/"best-top5.pt")
            print(json.dumps({"epoch":epoch,"trainCrossEntropy":record["trainCrossEntropy"],"top1":score["top1"],"top5":score["top5"],"macroRecall":score["macroRecallSupportedClasses"]}),flush=True)
    summary={"bestTop1Epoch":epoch1,"bestTop1":best1,"bestTop5Epoch":epoch5,"bestTop5":best5,
        "bestCheckpoint":"best.pt","bestTop5Checkpoint":"best-top5.pt",**metadata}
    (args.output/"summary.json").write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding="utf-8")


if __name__=="__main__": main()
