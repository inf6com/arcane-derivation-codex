#!/usr/bin/env python3
"""Non-autoregressive learned-query decoder over whole FormulaInput traces."""
from __future__ import annotations
import argparse, json
from pathlib import Path
import torch
from torch import nn
from torch.utils.data import DataLoader
from ModelConversion.formula_whole_model import TraceEncoder, MAX_LABEL_TOKENS, load_tokenizer, verify_execution_device
from ModelConversion.train_formula_whole_model import FormulaWholeDataset, collate

class SlotDecoder(nn.Module):
    def __init__(self, vocab: int):
        super().__init__()
        self.encoder=TraceEncoder(d_model=256, dropout=0)
        self.queries=nn.Parameter(torch.randn(1,MAX_LABEL_TOKENS,256)*.02)
        layer=nn.TransformerDecoderLayer(256,4,256,0,batch_first=True)
        self.decoder=nn.TransformerDecoder(layer,2)
        self.out=nn.Linear(256,vocab)
    def forward(self,x,mask):
        memory,memory_mask=self.encoder(x,mask)
        return self.out(self.decoder(self.queries.expand(x.shape[0],-1,-1),memory,memory_key_padding_mask=memory_mask))

def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('--dataset-root',type=Path,required=True); p.add_argument('--tokenizer',type=Path,required=True); p.add_argument('--output',type=Path,required=True); p.add_argument('--device',default='mps'); a=p.parse_args()
    device=verify_execution_device(a.device); tok=load_tokenizer(a.tokenizer); data=FormulaWholeDataset(a.dataset_root/'mathwriting-2024/train',tok,limit=16); loader=DataLoader(data,batch_size=8,shuffle=True,collate_fn=collate)
    model=SlotDecoder(tok.vocab_size).to(a.device); opt=torch.optim.AdamW(model.parameters(),lr=3e-4)
    for _ in range(100):
      for x,m,t,tm,_ in loader:
        x,m,t=x.to(a.device),m.to(a.device),t.to(a.device); target=torch.full((t.shape[0],MAX_LABEL_TOKENS),tok.pad_id,device=a.device); target[:,:t.shape[1]]=t
        opt.zero_grad(); logits=model(x,m); loss=nn.functional.cross_entropy(logits.reshape(-1,tok.vocab_size),target.reshape(-1),ignore_index=tok.pad_id); loss.backward(); opt.step()
    exact=valid=eos=0
    with torch.inference_mode():
      for x,m,t,tm,labels in DataLoader(data,batch_size=8,shuffle=False,collate_fn=collate):
        pred=model(x.to(a.device),m.to(a.device)).argmax(-1).tolist()
        for row,label in zip(pred,labels):
          text=tok.decode(row); exact+=text==label; eos+=tok.eos_id in row; valid+=text.count('{')==text.count('}')
    a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps({'status':'COMPLETED','deviceEvidence':device,'model':'non-autoregressive learned query cross-attention slot decoder','split':'train16 only; test not opened','loss':loss.item(),'exact':f'{exact}/16','eosRate':eos/16,'structuralValidityRate':valid/16},indent=2))
if __name__=='__main__': main()
