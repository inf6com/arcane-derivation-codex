#!/usr/bin/env python3
"""One real MPS update: FormulaRasterV1 LaTeX loss plus train-only symbol auxiliary loss."""
from __future__ import annotations
import argparse,json,math
from pathlib import Path
import torch
from torch import nn
from formula_whole_input import load_formula_input,model_features
from formula_whole_model import load_tokenizer
from raster_formula_model import RasterFormulaModel,raster_tensor,RASTER_SIZE,MARGIN

def main():
 p=argparse.ArgumentParser(); p.add_argument('--root',type=Path,required=True); p.add_argument('--tokenizer',type=Path,required=True); p.add_argument('--output',type=Path,required=True); a=p.parse_args()
 if not torch.backends.mps.is_available(): raise RuntimeError('MPS is required')
 records=[json.loads(x) for x in (a.root/'symbols.jsonl').read_text().splitlines()]
 labels=sorted({x['label'] for x in records});
 if len(labels)!=229: raise ValueError(f'expected 229 observed symbol classes, got {len(labels)}')
 by_source={}
 for r in records: by_source.setdefault(r['sourceSampleId'],[]).append(r)
 selected=list(by_source)[:16]; tokenizer=load_tokenizer(a.tokenizer); formulas=[]; targets=[]; aux=[]
 for source in selected:
  formula,meta=load_formula_input(a.root/'train'/f'{source}.inkml'); features=model_features(formula); formulas.append(formula); targets.append(torch.tensor(tokenizer.encode(meta['normalizedLabel']),dtype=torch.long))
  allpts=[p for t in features for p in t]; mnx=maxx=min(x for x,_ in allpts); mny=maxy=min(y for _,y in allpts); maxx=max(x for x,_ in allpts); maxy=max(y for _,y in allpts); scale=min((RASTER_SIZE-2*MARGIN)/(maxx-mnx),(RASTER_SIZE-2*MARGIN)/(maxy-mny))
  for r in by_source[source]:
   pts=[p for i in r['strokeIndices'] for p in features[i]]; xs=[MARGIN+(x-mnx)*scale for x,_ in pts]; ys=[MARGIN+(y-mny)*scale for _,y in pts]
   aux.append((selected.index(source),max(0,min(7,int(min(xs)//64))),max(0,min(7,int(max(xs)//64))),max(0,min(7,int(min(ys)//64))),max(0,min(7,int(max(ys)//64))),labels.index(r['label'])))
 width=max(x.numel() for x in targets); padded=torch.full((16,width),tokenizer.pad_id,dtype=torch.long)
 for i,x in enumerate(targets): padded[i,:x.numel()]=x
 device='mps'; model=RasterFormulaModel(tokenizer.vocab_size).to(device); head=nn.Linear(192,229).to(device); opt=torch.optim.AdamW([*model.parameters(),*head.parameters()],lr=3e-4)
 raster=torch.stack([raster_tensor(x) for x in formulas]).to(device); encoded=model.encoder(raster); pooled=torch.stack([encoded[b,:,y0:y1+1,x0:x1+1].mean((1,2)) for b,x0,x1,y0,y1,_ in aux]); aux_target=torch.tensor([c for *_,c in aux],device=device)
 logits=model(raster,padded[:,:-1].to(device)); main=torch.nn.functional.cross_entropy(logits.flatten(0,1),padded[:,1:].to(device).flatten(),ignore_index=tokenizer.pad_id); symbol=torch.nn.functional.cross_entropy(head(pooled),aux_target); loss=main+0.2*symbol; opt.zero_grad(); loss.backward()
 report={'device':'mps','formulaBatch':16,'symbolRecords':len(aux),'symbolClassCount':len(labels),'mainLatexLoss':float(main),'symbolAuxiliaryLoss':float(symbol),'totalLoss':float(loss),'finite':bool(torch.isfinite(loss)),'latexHeadGradientNonzero':bool(model.output.weight.grad.abs().sum()>0),'symbolHeadGradientNonzero':bool(head.weight.grad.abs().sum()>0),'encoderGradientNonzero':bool(next(model.encoder.parameters()).grad.abs().sum()>0)}
 if not all(report[x] for x in ('finite','latexHeadGradientNonzero','symbolHeadGradientNonzero','encoderGradientNonzero')): raise RuntimeError(report)
 opt.step(); a.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)); print(json.dumps(report,ensure_ascii=False))
if __name__=='__main__': main()
