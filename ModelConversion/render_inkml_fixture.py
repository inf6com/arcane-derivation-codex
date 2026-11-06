#!/usr/bin/env python3
"""Render one real InkML formula under an explicit, non-training fixture contract."""
from __future__ import annotations
import argparse, hashlib, json, math
from pathlib import Path
from ModelConversion.formula_whole_input import load_formula_input, model_features

def main():
 p=argparse.ArgumentParser(); p.add_argument('--inkml',type=Path,required=True); p.add_argument('--png',type=Path,required=True); p.add_argument('--spec',type=Path,required=True); a=p.parse_args()
 formula,meta=load_formula_input(a.inkml); traces=model_features(formula); pts=[q for t in traces for q in t]; xs=[q[0] for q in pts]; ys=[q[1] for q in pts]
 if not pts or max(xs)==min(xs) or max(ys)==min(ys): raise ValueError('InkML bounds cannot define a render transform')
 size=512; margin=32; scale=min((size-2*margin)/(max(xs)-min(xs)),(size-2*margin)/(max(ys)-min(ys)))
 pixels=bytearray([255])*(size*size); radius=2.0
 def paint(ax,ay,bx,by):
  lo_x=max(0,int(math.floor(min(ax,bx)-radius-1))); hi_x=min(size-1,int(math.ceil(max(ax,bx)+radius+1)))
  lo_y=max(0,int(math.floor(min(ay,by)-radius-1))); hi_y=min(size-1,int(math.ceil(max(ay,by)+radius+1))); dx=bx-ax; dy=by-ay; den=dx*dx+dy*dy
  for py in range(lo_y,hi_y+1):
   for px in range(lo_x,hi_x+1):
    u=0 if den==0 else max(0,min(1,((px+.5-ax)*dx+(py+.5-ay)*dy)/den)); dist=math.hypot(px+.5-(ax+u*dx),py+.5-(ay+u*dy)); coverage=max(0,min(1,radius+.5-dist)); pixels[py*size+px]=min(pixels[py*size+px],round(255*(1-coverage)))
 for trace in traces:
  transformed=[(margin+(x-min(xs))*scale,margin+(y-min(ys))*scale) for x,y in trace]
  for left,right in zip(transformed,transformed[1:]): paint(*left,*right)
 a.png.parent.mkdir(parents=True,exist_ok=True); a.png.write_bytes(f'P5\n{size} {size}\n255\n'.encode()+pixels)
 a.spec.parent.mkdir(parents=True,exist_ok=True); a.spec.write_text(json.dumps({'sourceInkML':str(a.inkml),'normalizedLabel':meta['normalizedLabel'],'resolutionPx':[size,size],'format':'8-bit binary PGM P5','coordinateTransform':'isotropic source bounds to 32px margin; y preserved','strokeWidthPx':4,'antiAlias':'per-pixel line-segment distance, linear 0.5px coverage ramp','background':255,'aspectRatio':'preserved with centered bounds','inferenceParity':'UNVERIFIED: PencilKit rasterization contract is not established','sha256':hashlib.sha256(a.png.read_bytes()).hexdigest()},indent=2),encoding='utf-8')
if __name__=='__main__': main()
