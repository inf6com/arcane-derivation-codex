#!/usr/bin/env python3
"""MPS-only learned symbol-instance separation over FormulaRasterV1 teachers."""
from __future__ import annotations
import argparse, json
from dataclasses import dataclass
from pathlib import Path
from typing import Any
import torch
from torch import Tensor, nn
from torch.nn import functional as F
from torch.utils.data import Dataset
from formula_whole_input import load_formula_input
from raster_formula_model import RASTER_SIZE, raster_tensor

MASK_STRIDE=4
MASK_SIZE=RASTER_SIZE//MASK_STRIDE
EXPECTED_CLASS_COUNT=229
COORDINATE_SPEC="FormulaRasterV1-512-margin32-isotropic"

@dataclass(frozen=True)
class SymbolVocabulary:
    tokens: tuple[str,...]
    def __post_init__(self):
        if len(self.tokens)!=EXPECTED_CLASS_COUNT or len(set(self.tokens))!=len(self.tokens): raise ValueError(f"symbol vocabulary must contain {EXPECTED_CLASS_COUNT} unique tokens")
    def index(self, token: str) -> int:
        try: return self.tokens.index(token)
        except ValueError as error: raise ValueError(f"symbol token absent from training vocabulary: {token!r}") from error

def load_symbol_vocabulary(teachers: Path) -> SymbolVocabulary:
    """Read the complete train-only vocabulary, never a split subset."""
    return SymbolVocabulary(tuple(sorted({json.loads(line)["symbolToken"] for line in teachers.read_text(encoding="utf-8").splitlines() if line})))

def load_structure_ids(teachers: Path) -> set[str]:
    ids=set()
    for line in teachers.read_text(encoding="utf-8").splitlines():
        sample_id=json.loads(line).get("sampleId")
        if not isinstance(sample_id,str) or not sample_id or sample_id in ids: raise ValueError("structure teachers require unique non-empty sampleId values")
        ids.add(sample_id)
    return ids

def _mask(mask_pixels: list[int]) -> Tensor:
    if not mask_pixels or len(mask_pixels)!=len(set(mask_pixels)) or any(not isinstance(p,int) or p<0 or p>=RASTER_SIZE*RASTER_SIZE for p in mask_pixels): raise ValueError("instance mask must contain unique FormulaRasterV1 pixels")
    result=torch.zeros((1,RASTER_SIZE,RASTER_SIZE),dtype=torch.float32); result.view(-1)[torch.tensor(mask_pixels,dtype=torch.long)]=1.; return result

def _bbox(bbox: list[float]) -> Tensor:
    if len(bbox)!=4 or any(not isinstance(v,(int,float)) for v in bbox): raise ValueError("bbox512 must be four numeric coordinates")
    x0,y0,x1,y1=map(float,bbox)
    # A one-point or zero-length handwritten trace has a valid raster mask but
    # a degenerate source bounding box; preserve that direct annotation.
    if not (0<=x0<=x1<=RASTER_SIZE and 0<=y0<=y1<=RASTER_SIZE): raise ValueError(f"invalid bbox512: {bbox!r}")
    return torch.tensor((x0,y0,x1,y1),dtype=torch.float32).div(RASTER_SIZE)

class InstanceTeacherDataset(Dataset[dict[str,Any]]):
    """Train-only instances. AST connection is evidence by sampleId, never guessed node alignment."""
    def __init__(self, teachers: Path, mathwriting_root: Path, structure_teachers: Path, vocabulary: SymbolVocabulary):
        self.rows=[json.loads(line) for line in teachers.read_text(encoding="utf-8").splitlines() if line]
        if not self.rows: raise ValueError("instance teacher input is empty")
        self.root=mathwriting_root; self.structure_ids=load_structure_ids(structure_teachers); self.vocabulary=vocabulary
        for row in self.rows: self._validate(row)
    def _validate(self,row:dict[str,Any]):
        sample_id=row.get("sampleId"); instance_id=row.get("instanceId")
        if not isinstance(sample_id,str) or not sample_id: raise ValueError("instance teacher has no sampleId")
        if not isinstance(instance_id,str) or not instance_id.startswith(sample_id+":"): raise ValueError(f"{sample_id}: instanceId is not source-stable")
        if row.get("coordinateSpec")!=COORDINATE_SPEC: raise ValueError(f"{sample_id}: incompatible coordinate spec")
        if sample_id not in self.structure_ids: raise ValueError(f"{sample_id}: no AST source connection")
        self.vocabulary.index(row.get("symbolToken")); _mask(row.get("maskPixels512")); _bbox(row.get("bbox512"))
    def __len__(self): return len(self.rows)
    def __getitem__(self,index):
        row=self.rows[index]; sample_id=row["sampleId"]; formula,meta=load_formula_input(self.root/"train"/f"{sample_id}.inkml")
        if meta["sampleId"]!=sample_id: raise ValueError(f"{sample_id}: InkML identity mismatch")
        return {"raster":raster_tensor(formula),"mask512":_mask(row["maskPixels512"]),"bbox":_bbox(row["bbox512"]),"classIndex":torch.tensor(self.vocabulary.index(row["symbolToken"]),dtype=torch.long),"sampleId":sample_id,"instanceId":row["instanceId"],"astConnectionId":sample_id}

def assert_batch_contract(batch:dict[str,Any]):
    raster,mask,bbox,classes=batch["raster"],batch["mask"],batch["bbox"],batch["classIndex"]
    if raster.ndim!=4 or raster.shape[1:]!=(1,RASTER_SIZE,RASTER_SIZE): raise ValueError(f"raster must be [B,1,{RASTER_SIZE},{RASTER_SIZE}], got {tuple(raster.shape)}")
    if mask.shape!=(raster.shape[0],1,MASK_SIZE,MASK_SIZE): raise ValueError(f"mask must be [B,1,{MASK_SIZE},{MASK_SIZE}]")
    if bbox.shape!=(raster.shape[0],4) or not torch.all((bbox>=0)&(bbox<=1)): raise ValueError("bbox must be normalized [B,4]")
    if classes.shape!=(raster.shape[0],) or classes.dtype!=torch.long or torch.any(classes<0) or torch.any(classes>=EXPECTED_CLASS_COUNT): raise ValueError("classIndex must be in fixed vocabulary")
    for sample_id,instance_id,ast_id in zip(batch["sampleIds"],batch["instanceIds"],batch["astConnectionIds"]):
        if ast_id!=sample_id or not instance_id.startswith(sample_id+":"): raise ValueError("instance/AST evidence identity invariant failed")

def collate_instances(items:list[dict[str,Any]]) -> dict[str,Any]:
    if not items: raise ValueError("cannot collate an empty instance batch")
    masks=torch.stack([item["mask512"] for item in items])
    batch={"raster":torch.stack([item["raster"] for item in items]),"mask":F.max_pool2d(masks,MASK_STRIDE,MASK_STRIDE),"bbox":torch.stack([item["bbox"] for item in items]),"classIndex":torch.stack([item["classIndex"] for item in items]),"sampleIds":[item["sampleId"] for item in items],"instanceIds":[item["instanceId"] for item in items],"astConnectionIds":[item["astConnectionId"] for item in items]}
    assert_batch_contract(batch); return batch

class InstanceSeparator(nn.Module):
    def __init__(self,classes:int=EXPECTED_CLASS_COUNT):
        super().__init__()
        if classes!=EXPECTED_CLASS_COUNT: raise ValueError(f"InstanceSeparator requires {EXPECTED_CLASS_COUNT} classes")
        self.features=nn.Sequential(nn.Conv2d(1,64,5,2,2),nn.GELU(),nn.Conv2d(64,128,3,2,1),nn.GELU()); self.mask=nn.Conv2d(128,1,1); self.bbox=nn.Linear(128,4); self.classifier=nn.Linear(128,classes)
    def forward(self,raster:Tensor)->dict[str,Tensor]:
        if raster.device.type!="mps": raise RuntimeError("InstanceSeparator optimization requires MPS")
        if raster.ndim!=4 or raster.shape[1:]!=(1,RASTER_SIZE,RASTER_SIZE): raise ValueError(f"raster must be [B,1,{RASTER_SIZE},{RASTER_SIZE}]")
        features=self.features(raster); pooled=features.mean((2,3)); return {"embedding":pooled,"maskLogits":self.mask(features),"bbox":self.bbox(pooled).sigmoid(),"classLogits":self.classifier(pooled)}

def instance_loss(outputs:dict[str,Tensor],batch:dict[str,Any])->dict[str,Tensor]:
    assert_batch_contract(batch)
    if outputs["maskLogits"].shape!=batch["mask"].shape: raise ValueError("mask logits do not match max-pooled mask target")
    if outputs["bbox"].shape!=batch["bbox"].shape or outputs["classLogits"].shape!=(batch["raster"].shape[0],EXPECTED_CLASS_COUNT): raise ValueError("InstanceSeparator output shape invariant failed")
    mask=F.binary_cross_entropy_with_logits(outputs["maskLogits"],batch["mask"]); bbox=F.smooth_l1_loss(outputs["bbox"],batch["bbox"]); symbol=F.cross_entropy(outputs["classLogits"],batch["classIndex"]); total=mask+bbox+symbol
    if not torch.isfinite(total): raise ValueError("instance loss is non-finite")
    return {"total":total,"mask":mask,"bbox":bbox,"class":symbol}

def mps_one_batch(dataset:InstanceTeacherDataset,batch_size:int)->dict[str,float]:
    if not torch.backends.mps.is_available(): raise RuntimeError("MPS is unavailable; raw Metal visibility must be restored before optimization")
    if not 0<batch_size<=len(dataset): raise ValueError("batch_size must select a non-empty in-range batch")
    batch=collate_instances([dataset[i] for i in range(batch_size)]); device=torch.device("mps"); model=InstanceSeparator().to(device); optimizer=torch.optim.AdamW(model.parameters(),lr=3e-4)
    device_batch={**batch,"mask":batch["mask"].to(device),"bbox":batch["bbox"].to(device),"classIndex":batch["classIndex"].to(device)}; losses=instance_loss(model(batch["raster"].to(device)),device_batch); optimizer.zero_grad(set_to_none=True); losses["total"].backward(); optimizer.step(); return {name:float(value.detach().cpu()) for name,value in losses.items()}

def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--teachers",type=Path,required=True); parser.add_argument("--vocabulary-teachers",type=Path,required=True); parser.add_argument("--mathwriting-root",type=Path,required=True); parser.add_argument("--structure-teachers",type=Path,required=True); parser.add_argument("--batch-size",type=int,default=1); args=parser.parse_args()
    dataset=InstanceTeacherDataset(args.teachers,args.mathwriting_root,args.structure_teachers,load_symbol_vocabulary(args.vocabulary_teachers)); print(json.dumps(mps_one_batch(dataset,args.batch_size),sort_keys=True))
if __name__=="__main__": main()
