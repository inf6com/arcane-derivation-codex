#!/usr/bin/env python3
"""Build font-heldout 229-label subsets by learned contour/skeleton matching."""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch
from torch.nn import functional as F

from train_firebird_part_similarity import DenseShapeDescriptor, affine_views, select_points


def calibrate_threshold(model, shape, rows, calibration_fonts, device):
    candidates=[r for r in rows if r['fontFileSHA256'] in calibration_fonts]
    # Bound calibration work while retaining font and label diversity.
    by_label=defaultdict(list)
    for r in candidates: by_label[r['vocabularyIndex']].append(r)
    selected=[]
    for label in sorted(by_label):
        values=sorted(by_label[label],key=lambda r:(r['fontFileSHA256'],r['imageIndex']))
        selected.extend(values[:8])
    selected=selected[:2048]
    positives=[]; negatives=[]
    with torch.inference_mode():
        for start in range(0,len(selected),64):
            batch=selected[start:start+64]
            x=torch.from_numpy(np.array([shape[r['imageIndex']] for r in batch],copy=True)).to(device=device,dtype=torch.float32).div_(255.)
            va,vb,grids=affine_views(x)
            da=model(va); db=model(vb)
            da=F.normalize(F.grid_sample(da,grids[0],mode='bilinear',padding_mode='zeros',align_corners=False),dim=1)
            db=F.normalize(F.grid_sample(db,grids[1],mode='bilinear',padding_mode='zeros',align_corners=False),dim=1)
            ids,valid=select_points(x[:,1:2],32)
            n,dim,h,w=da.shape
            da=da.permute(0,2,3,1).reshape(n,h*w,dim)
            db=db.permute(0,2,3,1).reshape(n,h*w,dim)
            a=F.normalize(torch.gather(da,1,ids[...,None].expand(-1,-1,dim)),dim=-1)
            b=F.normalize(torch.gather(db,1,ids[...,None].expand(-1,-1,dim)),dim=-1)
            sim=torch.bmm(a,b.transpose(1,2)); diag=sim.diagonal(dim1=1,dim2=2)
            positives.extend(diag[valid].cpu().tolist())
            off=~torch.eye(sim.shape[1],device=device,dtype=torch.bool).unsqueeze(0)
            off=off & valid[:,:,None] & valid[:,None,:]
            negatives.extend(sim[off].cpu().tolist())
    pos=np.asarray(positives,dtype=np.float32); neg=np.asarray(negatives,dtype=np.float32)
    if not len(pos) or not len(neg): raise ValueError('No heldout contour/skeleton correspondence calibration pairs.')
    thresholds=np.unique(np.quantile(np.concatenate((pos,neg)),np.linspace(0,1,501)))
    best=None
    for t in thresholds:
        tpr=float(np.mean(pos>=t)); fpr=float(np.mean(neg>=t)); score=(tpr + 1-fpr)/2
        if best is None or score>best[0]: best=(score,float(t),tpr,fpr)
    return {'threshold':best[1],'balancedAccuracy':best[0],'trueMatchRecall':best[2],
            'differentSiteFalseMatchRate':best[3],'positiveCount':len(pos),'negativeCount':len(neg),
            'positiveCosineP05':float(np.quantile(pos,.05)),'negativeCosineP99':float(np.quantile(neg,.99))}


def args_parse():
    p=argparse.ArgumentParser()
    p.add_argument('--manifest',type=Path,default=Path('runs/agent-control/cycle622-firebird-mac-font-glyphs.json'))
    p.add_argument('--run',type=Path,required=True)
    p.add_argument('--max-fonts-per-pair',type=int,default=3)
    p.add_argument('--output-name',default='similarity-subsets.json')
    return p.parse_args()


def main():
    args=args_parse()
    if not torch.backends.mps.is_available(): raise RuntimeError('MPS unavailable; refusing implicit CPU inference.')
    report=json.loads((args.run/'training-report.json').read_text())
    manifest_bytes=args.manifest.read_bytes(); manifest=json.loads(manifest_bytes)
    held=set(report['heldoutFontFiles']); rows=manifest['rows']
    if report['corpusManifestSHA256'] != __import__('hashlib').sha256(manifest_bytes).hexdigest():
        raise ValueError('Training and inference corpus manifests differ.')
    shape_path=args.run/'contour-skeleton-corpus.u8'
    if not shape_path.is_file() or shape_path.stat().st_size != len(rows)*2*64*64:
        raise ValueError('Contour/skeleton corpus is missing or has an invalid byte size.')
    shape=np.memmap(shape_path,mode='r',dtype=np.uint8,shape=(len(rows),2,64,64))
    device=torch.device('mps')
    model=DenseShapeDescriptor().to(device)
    state=torch.load(args.run/'firebird-part-descriptor.pt',map_location='cpu',weights_only=True)
    model.load_state_dict(state['state_dict'],strict=True); model.eval()
    label_indices=sorted({r['vocabularyIndex'] for r in rows})
    labels={r['vocabularyIndex']:r['label'] for r in rows}
    display_labels={}
    for r in rows:
        display_labels[r['vocabularyIndex']]=chr(int(r['unicodeScalar'][2:],16))
    split_order=sorted(held,key=lambda h:__import__('hashlib').sha256(('part-calibration:'+h).encode()).digest())
    calibration_fonts=set(split_order[:len(split_order)//2])
    # Use the entire authoritative typeset corpus except threshold-calibration
    # fonts. This is subset construction, not an independent benchmark; using
    # heldout-only samples here can make rare glyphs falsely appear absent.
    all_fonts={r['fontFileSHA256'] for r in rows}
    subset_fonts=all_fonts-calibration_fonts
    calibration=calibrate_threshold(model,shape,rows,calibration_fonts,device)
    cosine_threshold=calibration['threshold']
    instances=defaultdict(list)
    for r in rows:
        if r['fontFileSHA256'] in subset_fonts:
            instances[r['vocabularyIndex']].append(r)
    for idx in instances:
        unique={r['fontFileSHA256']:r for r in instances[idx]}
        instances[idx]=[unique[k] for k in sorted(unique)]
    selected=[r for idx in sorted(instances) for r in instances[idx]]
    feature_by_image={}
    with torch.inference_mode():
        for start in range(0,len(selected),64):
            batch=selected[start:start+64]
            x=torch.from_numpy(np.array([shape[r['imageIndex']] for r in batch],copy=True)).to(device=device,dtype=torch.float32).div_(255.)
            desc=model(x); sk=x[:,1] > 0.5
            for local,r in enumerate(batch):
                coords=torch.nonzero(sk[local],as_tuple=False)
                if coords.shape[0] < 4: continue
                if coords.shape[0] > 256:
                    positions=torch.linspace(0,coords.shape[0]-1,256,device=device).round().long()
                    coords=coords[positions]
                vals=desc[local,:,coords[:,0],coords[:,1]].T
                feature_by_image[r['imageIndex']]=(vals.cpu().numpy(),coords.cpu().numpy(),r)

    # Calibrate a local-part match threshold from withheld fonts only. Positives
    # are known corresponding pixels under controlled scale/translation views;
    # negatives are different skeleton sites in the same glyph image.
    label_samples=defaultdict(list)
    for r in selected:
        if r['imageIndex'] in feature_by_image:
            label_samples[r['vocabularyIndex']].append(feature_by_image[r['imageIndex']])

    evidence={}; edges=[]
    ids=sorted(label_indices)
    for p,a in enumerate(ids):
        for b in ids[p+1:]:
            pair=[]
            samples_a={row['fontFileSHA256']:(features,coords,row)
                       for features,coords,row in label_samples.get(a,[])}
            samples_b={row['fontFileSHA256']:(features,coords,row)
                       for features,coords,row in label_samples.get(b,[])}
            # Compare two symbols rendered by the same source font. Cross-font
            # matching confounds glyph-part similarity with typeface design.
            common_fonts=sorted(samples_a.keys() & samples_b.keys())
            if args.max_fonts_per_pair > 0:
                common_fonts=common_fonts[:args.max_fonts_per_pair]
            for font_hash in common_fonts:
                fa,_,ra=samples_a[font_hash]
                fb,_,rb=samples_b[font_hash]
                sim=fa @ fb.T
                # Enforce a symmetric one-to-one correspondence. Independent
                # nearest-neighbor coverage lets one short line explain many
                # unrelated branches and creates oversized false subsets.
                order=np.argsort(sim,axis=None)[::-1]
                used_a=np.zeros(sim.shape[0],dtype=bool)
                used_b=np.zeros(sim.shape[1],dtype=bool)
                count=0
                for flat_index in order:
                    i,j=np.unravel_index(flat_index,sim.shape)
                    if sim[i,j] < cosine_threshold:
                        break
                    if not used_a[i] and not used_b[j]:
                        used_a[i]=True; used_b[j]=True; count+=1
                cov_a=count/max(sim.shape[0],1)
                cov_b=count/max(sim.shape[1],1)
                count_a=count_b=count
                pair.append({'font':font_hash,
                             'matchedSkeletonSitesA':count_a,'matchedSkeletonSitesB':count_b,
                             'sitesA':int(sim.shape[0]),'sitesB':int(sim.shape[1]),
                             'coverageA':cov_a,'coverageB':cov_b,
                             'sharedCoverageSymmetric':float(min(cov_a,cov_b))})
            if pair:
                scores=sorted(x['sharedCoverageSymmetric'] for x in pair)
                median=float(np.median(scores)); passing=sum(x>=0.5 for x in scores)
                evidence[f'{a}:{b}']={'labelA':labels[a],'labelB':labels[b],'sharedFontCount':len(pair),
                                      'medianSharedCoverage':median,'fontPairsAtLeastHalfCoverage':passing,
                                      'fontPairEvidence':pair}
                if median >= 0.5 and passing >= min(2,len(pair)):
                    edges.append((median,a,b))

    # Similarity is not assumed transitive. Emit one overlapping neighborhood
    # for each vocabulary item so every accepted direct pair remains visible.
    neighbors={idx:set() for idx in range(229)}
    for _,a,b in edges:
        neighbors[a].add(b); neighbors[b].add(a)
    subsets=[]
    for focus in range(229):
        member_ids=[focus,*sorted(neighbors[focus])]
        members=[]
        for idx in member_ids:
            if idx in labels: members.append({'index':idx,'label':labels[idx],'display':display_labels[idx]})
            else: members.append({'index':idx,'label':'分数構造'})
        subsets.append({'focusIndex':focus,'focus':labels.get(focus,'分数構造'),
                        'members':members,
                        'directPairEvidence':[evidence[f'{min(focus,other)}:{max(focus,other)}']
                                              for other in sorted(neighbors[focus])]})
    output={'schema':'firebird-typeset-contour-skeleton-subsets-v2',
            'source':'Mac typeset font glyph images only','checkpoint':str(args.run/'firebird-part-descriptor.pt'),
            'fontSplit':'threshold calibration uses heldout source fonts; subset generation uses all corpus source fonts outside calibration; pair comparisons use the same font on both symbols',
            'heldoutFontFiles':len(held),'thresholdCalibrationFontFiles':len(calibration_fonts),
            'subsetGenerationFontFiles':len(subset_fonts),'subsetGlyphImagesSelected':len(selected),
            'descriptorValidation':report['heldoutFontCorrespondenceValidation'],
            'separateFontThresholdCalibration':calibration,
            'cosineMatchThreshold':cosine_threshold,
            'pairRule':'Within each shared source font outside threshold calibration, skeleton sites are paired by descending descriptor cosine similarity, with each site used at most once and pairs below the heldout-calibrated threshold rejected. Matched-site coverage is divided by each glyph skeleton size; the smaller directional coverage is the symmetric shared fraction. A pair is linked when median same-font coverage is at least 0.50 and at least two fonts pass (or all available when only one).',
            'subsetSemantics':'Overlapping direct-neighbor subsets. Similarity is not assumed transitive; every member other than the focus has a measured direct pair edge.',
            'outerTestOpened':False,'pairEdgeCount':len(edges),'subsetCount':len(subsets),
            'multiSymbolSubsetCount':sum(len(x['members'])>1 for x in subsets),'singleSymbolSubsetCount':sum(len(x['members'])==1 for x in subsets),
            'subsets':subsets,'allPairEvidence':list(evidence.values()),
            'limitations':['Subset construction includes fonts used for self-supervised descriptor fitting; it is not an independent benchmark.','Font instances are vector outlines rasterized by CoreText, not pen strokes.','This is an experimental part-shape partition; human semantic labels for parts are not present.','Coverage is measured over skeleton sites, not ink area.']}
    out=args.run/args.output_name
    out.write_text(json.dumps(output,ensure_ascii=False,indent=2)+'\n')
    table=['# 活字の輪郭・骨格から作成した類似部分集合','',
           f"重なりを許す直接近傍集合: 229記号、複数記号集合: {output['multiSymbolSubsetCount']}、類似相手なし: {output['singleSymbolSubsetCount']}。",'',
           '| 番号 | 中心記号 | 類似部分集合 |', '|---:|---|---|']
    for number,subset in enumerate(subsets,1):
        visible='、'.join(m.get('display',m['label']) for m in subset['members'])
        focus=next((m.get('display',m['label']) for m in subset['members'] if m['index']==subset['focusIndex']),subset['focus'])
        table.append(f'| {number} | {focus} | {visible} |')
    md_name=Path(args.output_name).with_suffix('.md').name
    (args.run/md_name).write_text('\n'.join(table)+'\n')
    print(json.dumps({k:v for k,v in output.items() if k not in ['subsets','allPairEvidence']},ensure_ascii=False))


if __name__=='__main__': main()
