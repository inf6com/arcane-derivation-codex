#!/usr/bin/env python3
"""Diagnostic only: can frozen spatial FormulaRasterV1 features separate first LaTeX tokens?"""
from __future__ import annotations
import argparse,json
from pathlib import Path
import torch
from torch import nn
from torch.utils.data import DataLoader
from train_raster_formula_model import InkMLRasterDataset,collate
from raster_formula_model import RasterFormulaModel

p=argparse.ArgumentParser(); p.add_argument('--checkpoint',type=Path,required=True); p.add_argument('--train-root',type=Path,required=True); p.add_argument('--tokenizer',type=Path,required=True); p.add_argument('--output',type=Path,required=True); p.add_argument('--epochs',type=int,default=200); a=p.parse_args()
if not torch.backends.mps.is_available(): raise RuntimeError('MPS is required')
data=InkMLRasterDataset(a.train_root,a.tokenizer,16,128); state=torch.load(a.checkpoint,map_location='mps',weights_only=True); model=RasterFormulaModel(state['vocab_size'],state['d_model']).to('mps'); model.load_state_dict(state['state_dict']); model.eval()
for x in model.encoder.parameters(): x.requires_grad=False
head=nn.Linear(state['d_model']*64,state['vocab_size']).to('mps'); opt=torch.optim.AdamW(head.parameters(),lr=1e-3); raster,target,_,names=next(iter(DataLoader(data,batch_size=16,collate_fn=collate)))
with torch.no_grad(): features=model.encoder(raster.to('mps')).flatten(1)
labels=target[:,1].to('mps'); history=[]
for epoch in range(1,a.epochs+1):
 logits=head(features); loss=nn.functional.cross_entropy(logits,labels); opt.zero_grad(); loss.backward(); opt.step(); history.append({'epoch':epoch,'exact':int(logits.argmax(-1).eq(labels).sum())})
report={'input':'frozen FormulaRasterV1 spatial encoder features only','target':'normalized LaTeX first token only','device':'mps','epochs':a.epochs,'finalExact':history[-1]['exact'],'history':history}
a.output.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8'); print(json.dumps({'finalExact':history[-1]['exact']}))
