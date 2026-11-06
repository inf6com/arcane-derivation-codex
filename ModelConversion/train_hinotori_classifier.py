#!/usr/bin/env python3
"""Train the trajectory-only 229-class symbol classifier on direct teachers.

This is the strong-supervision phase.  It has no image input, formula decoder,
or structural output.  Every evaluation split is separated by source formula.
"""
from __future__ import annotations
import argparse, hashlib, json, math, random, xml.etree.ElementTree as ET
from pathlib import Path
import torch
from torch import nn
from torch.utils.data import DataLoader, Dataset

POINTS, MAX_STROKES = 128, 11
INK = {"ink": "http://www.w3.org/2003/InkML"}

def resample(points):
    if len(points) == 1: return [points[0]] * POINTS
    length = [0.0]
    for a,b in zip(points, points[1:]): length.append(length[-1] + math.dist(a,b))
    if length[-1] == 0: return [points[0]] * POINTS
    out=[]; j=1
    for i in range(POINTS):
        target=length[-1]*i/(POINTS-1)
        while j < len(length)-1 and length[j] < target: j += 1
        lo=max(0,j-1); span=length[j]-length[lo]; t=0 if span==0 else (target-length[lo])/span
        out.append((points[lo][0]+t*(points[j][0]-points[lo][0]), points[lo][1]+t*(points[j][1]-points[lo][1])))
    return out

def traces(path):
    root=ET.parse(path).getroot(); result=[]
    for node in root.findall("ink:trace", INK):
        values=[]
        for part in (node.text or "").strip().split(","):
            xy=part.split()
            if len(xy) < 2: raise ValueError(f"{path}: invalid trace point")
            point=(float(xy[0]),float(xy[1]))
            if not all(math.isfinite(v) for v in point): raise ValueError(f"{path}: non-finite point")
            values.append(point)
        if not values: raise ValueError(f"{path}: empty trace")
        result.append(values)
    return result

class DirectSymbols(Dataset):
    def __init__(self, root, teachers, valid):
        self.root=Path(root); self.rows=[]
        for line in Path(teachers).read_text(encoding="utf-8").splitlines():
            row=json.loads(line); bucket=hashlib.sha256(row["sourceSampleId"].encode()).digest()[0] < 51
            if bucket == valid: self.rows.append(row)
        if not self.rows: raise ValueError("empty source-separated split")
    def __len__(self): return len(self.rows)
    def __getitem__(self, i):
        row=self.rows[i]; source=traces(self.root / "train" / f'{row["sourceSampleId"]}.inkml')
        chosen=[source[n] for n in row["strokeIndices"]]
        if len(chosen)>MAX_STROKES: raise ValueError(f'{row["sourceSampleId"]}: too many strokes')
        flat=[p for stroke in chosen for p in stroke]; x0,x1=min(x for x,y in flat),max(x for x,y in flat); y0,y1=min(y for x,y in flat),max(y for x,y in flat); scale=max(x1-x0,y1-y0)
        # A dot is a valid one-point symbol.  Its shape has no scale, so its
        # only faithful normalized coordinate is the center of the unit box.
        tensor=torch.zeros(MAX_STROKES,POINTS,2); mask=torch.ones(MAX_STROKES,dtype=torch.bool)
        for j,stroke in enumerate(chosen):
            tensor[j]=torch.tensor([(0.5,0.5) if scale == 0 else ((x-x0)/scale+(scale-(x1-x0))/(2*scale),(y-y0)/scale+(scale-(y1-y0))/(2*scale)) for x,y in resample(stroke)])
            mask[j]=False
        return tensor,mask,int(row["classIndex"])

class Hinotori(nn.Module):
    def __init__(self):
        super().__init__(); self.point=nn.Sequential(nn.Linear(2,128),nn.GELU(),nn.Linear(128,128),nn.GELU()); self.stroke=nn.TransformerEncoder(nn.TransformerEncoderLayer(128,4,256,0.1,batch_first=True),2,enable_nested_tensor=False); self.head=nn.Linear(128,229)
    def forward(self,x,padding):
        encoded=self.point(x).mean(2); encoded=self.stroke(encoded,src_key_padding_mask=padding); valid=(~padding).unsqueeze(-1); return self.head((encoded*valid).sum(1)/valid.sum(1).clamp_min(1))

def main():
    p=argparse.ArgumentParser(); p.add_argument("--dataset-root",type=Path,required=True); p.add_argument("--teachers",type=Path,required=True); p.add_argument("--output",type=Path,required=True); p.add_argument("--epochs",type=int,default=20); p.add_argument("--batch-size",type=int,default=32); p.add_argument("--device",default="mps"); a=p.parse_args()
    if a.device!="mps" or not torch.backends.mps.is_available(): raise RuntimeError("MPS is required")
    train,valid=DirectSymbols(a.dataset_root/"mathwriting-2024",a.teachers,False),DirectSymbols(a.dataset_root/"mathwriting-2024",a.teachers,True)
    model=Hinotori().to(a.device); optimizer=torch.optim.AdamW(model.parameters(),lr=3e-4,weight_decay=1e-2); best=-1.; a.output.mkdir(parents=True,exist_ok=True)
    for epoch in range(a.epochs):
        model.train()
        for x,m,y in DataLoader(train,batch_size=a.batch_size,shuffle=True):
            logits=model(x.to(a.device),m.to(a.device)); loss=nn.functional.cross_entropy(logits,y.to(a.device)); optimizer.zero_grad(); loss.backward(); optimizer.step()
        model.eval(); correct=total=top3=0
        with torch.no_grad():
            for x,m,y in DataLoader(valid,batch_size=a.batch_size):
                logits=model(x.to(a.device),m.to(a.device)); y=y.to(a.device); correct+=(logits.argmax(1)==y).sum().item(); top3+=(logits.topk(3,1).indices==y[:,None]).any(1).sum().item(); total+=len(y)
        metrics={"epoch":epoch+1,"validCount":total,"top1":correct/total,"top3":top3/total}
        (a.output/"latest.json").write_text(json.dumps(metrics,indent=2),encoding="utf-8")
        if metrics["top1"]>best: best=metrics["top1"]; torch.save(model.state_dict(),a.output/"best.pt"); (a.output/"best.json").write_text(json.dumps(metrics,indent=2),encoding="utf-8")
if __name__=="__main__": main()
