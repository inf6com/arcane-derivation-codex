#!/usr/bin/env python3
"""Teacher-forced diagnosis for the spatial FormulaRasterV1 decoder."""
from __future__ import annotations
import argparse, json, types
from pathlib import Path
import torch
from torch.utils.data import DataLoader
from train_raster_formula_model import InkMLRasterDataset, collate
from raster_formula_model import RasterFormulaModel

def main():
    p=argparse.ArgumentParser(); p.add_argument('--checkpoint',type=Path,required=True); p.add_argument('--train-root',type=Path,required=True); p.add_argument('--tokenizer',type=Path,required=True); p.add_argument('--output',type=Path,required=True); a=p.parse_args()
    if not torch.backends.mps.is_available(): raise RuntimeError('MPS is required')
    data=InkMLRasterDataset(a.train_root,a.tokenizer,16,128); state=torch.load(a.checkpoint,map_location='mps',weights_only=True)
    model=RasterFormulaModel(state['vocab_size'],state['d_model']).to('mps'); model.load_state_dict(state['state_dict']); model.eval(); captured=[]
    for layer in model.decoder.layers:
        original=layer.multihead_attn.forward
        def wrapped(self,*args,_original=original,**kwargs):
            kwargs['need_weights']=True; kwargs['average_attn_weights']=False
            result=_original(*args,**kwargs); captured.append(result[1].detach().cpu()); return result
        layer.multihead_attn.forward=types.MethodType(wrapped,layer.multihead_attn)
    raster,target,labels,names=next(iter(DataLoader(data,batch_size=16,shuffle=False,collate_fn=collate)))
    with torch.no_grad(): logits=model(raster.to('mps'),target[:,:-1].to('mps')).cpu()
    predicted=logits.argmax(-1); expected=target[:,1:]; valid=expected.ne(data.tokenizer.pad_id); correct=predicted.eq(expected)&valid
    rows=[]
    weights=captured[-1].mean(1) # final decoder layer, mean heads: batch,target,64 patches
    for i,name in enumerate(names):
        positions=torch.where(valid[i])[0]; mistakes=torch.where(~correct[i,positions])[0]
        first=int(positions[mistakes[0]]) if len(mistakes) else None
        patch=None if first is None else int(weights[i,first].argmax())
        rows.append({'file':name,'target':labels[i],'teacherTokenCount':int(valid[i].sum()),'teacherCorrectCount':int(correct[i].sum()),'firstErrorPosition':first,'expectedToken':None if first is None else data.tokenizer.tokens[int(expected[i,first])],'predictedToken':None if first is None else data.tokenizer.tokens[int(predicted[i,first])],'attentionPatch':None if patch is None else {'index':patch,'x':patch%8,'y':patch//8}})
    report={'checkpoint':str(a.checkpoint),'device':'mps','input':'FormulaRasterV1 512x512 only','teacherForcedTokenAccuracy':float(correct.sum()/valid.sum()),'sequenceExactCount':sum(r['firstErrorPosition'] is None for r in rows),'decoderAttention':'final cross-attention layer, mean of four heads, 8x8 patch argmax at first teacher-forced error','rows':rows}
    a.output.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8'); print(json.dumps({k:report[k] for k in ('teacherForcedTokenAccuracy','sequenceExactCount')},ensure_ascii=False))
if __name__=='__main__': main()
