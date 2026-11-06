#!/usr/bin/env python3
"""Create train-only FormulaRasterV1 symbol-instance teachers from direct annotations."""
from __future__ import annotations
import argparse, hashlib, json, math
from collections import defaultdict
from pathlib import Path
from formula_whole_input import load_formula_input, model_features
RASTER_SIZE=512
MARGIN=32.0

def instance(record, root):
 source=record['sourceSampleId']; indices=record['strokeIndices']; label=record['label']
 if not isinstance(indices,list) or not indices or len(indices)!=len(set(indices)): raise ValueError(f'{source}: invalid or duplicate strokeIndices')
 formula,_=load_formula_input(root/'train'/f'{source}.inkml'); traces=model_features(formula)
 if any(not isinstance(i,int) or i<0 or i>=len(traces) for i in indices): raise ValueError(f'{source}: stroke index out of range {indices}')
 points=[p for t in traces for p in t]; mnx=min(x for x,_ in points); mxx=max(x for x,_ in points); mny=min(y for _,y in points); mxy=max(y for _,y in points)
 if not all(map(math.isfinite,(mnx,mxx,mny,mxy))) or mxx<=mnx or mxy<=mny: raise ValueError(f'{source}: degenerate FormulaRasterV1 bounds')
 scale=min((RASTER_SIZE-2*MARGIN)/(mxx-mnx),(RASTER_SIZE-2*MARGIN)/(mxy-mny))
 selected=[p for i in indices for p in traces[i]]; xy=[(MARGIN+(x-mnx)*scale,MARGIN+(y-mny)*scale) for x,y in selected]
 if any(not(0<=x<RASTER_SIZE and 0<=y<RASTER_SIZE) for x,y in xy): raise ValueError(f'{source}: raster coordinate out of range')
 # The exact FormulaRasterV1 segment coverage is the instance mask target.
 mask=set()
 for index in indices:
  converted=[(MARGIN+(x-mnx)*scale,MARGIN+(y-mny)*scale) for x,y in traces[index]]
  for (ax,ay),(bx,by) in zip(converted,converted[1:]):
   for y in range(max(0,math.floor(min(ay,by)-3)),min(RASTER_SIZE-1,math.ceil(max(ay,by)+3))+1):
    for x in range(max(0,math.floor(min(ax,bx)-3)),min(RASTER_SIZE-1,math.ceil(max(ax,bx)+3))+1):
     dx,dy=bx-ax,by-ay; norm=dx*dx+dy*dy; t=0 if norm==0 else max(0,min(1,((x+.5-ax)*dx+(y+.5-ay)*dy)/norm))
     if math.hypot(x+.5-(ax+t*dx),y+.5-(ay+t*dy))<2.5: mask.add(y*RASTER_SIZE+x)
 if not mask: raise ValueError(f'{source}: empty instance raster mask')
 return {'sampleId':source,'instanceId':f'{source}:{"-".join(map(str,indices))}','strokeIndices':indices,'symbolToken':label,'bbox512':[min(x for x,_ in xy),min(y for _,y in xy),max(x for x,_ in xy),max(y for _,y in xy)],'maskPixels512':sorted(mask),'coordinateSpec':'FormulaRasterV1-512-margin32-isotropic'}
def main():
 p=argparse.ArgumentParser(); p.add_argument('--root',type=Path,required=True); p.add_argument('--output',type=Path,required=True); p.add_argument('--report',type=Path,required=True); a=p.parse_args()
 rows=[]; errors=[]; seen={}
 for line in (a.root/'symbols.jsonl').read_text().splitlines():
  r=json.loads(line)
  try:
   x=instance(r,a.root); key=(x['sampleId'],tuple(x['strokeIndices']))
   if key in seen and seen[key]!=x['symbolToken']: raise ValueError(f"{x['sampleId']}: conflicting duplicate label {seen[key]!r}/{x['symbolToken']!r}")
   if key not in seen: seen[key]=x['symbolToken']; rows.append(x)
  except Exception as e: errors.append({'sourceSampleId':r.get('sourceSampleId'),'reason':str(e)})
 a.output.write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in rows),encoding='utf-8')
 a.report.write_text(json.dumps({'records':len(rows),'sourceFormulaCount':len({x['sampleId'] for x in rows}),'errors':errors,'outputSHA256':hashlib.sha256(a.output.read_bytes()).hexdigest()},ensure_ascii=False,indent=2),encoding='utf-8')
 if errors: raise SystemExit(1)
if __name__=='__main__': main()
