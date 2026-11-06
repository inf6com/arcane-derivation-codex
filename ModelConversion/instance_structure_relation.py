#!/usr/bin/env python3
"""MPS-only relation supervision restricted to uniquely aligned AST instances."""
from __future__ import annotations
import json
from collections import defaultdict
from pathlib import Path
from typing import Any
import torch
from torch import Tensor,nn
from torch.nn import functional as F

RELATION_TYPES=("none","baseline","superscript","subscript","numerator","denominator","radicand","radical-index","matrix-row","matrix-cell","delimiter")
RELATION_INDEX={name:index for index,name in enumerate(RELATION_TYPES)}

def load_direct_auxiliary(path:Path)->list[dict[str,Any]]:
    rows=[json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
    for row in rows:
        if row.get("teacherLayer")!="ast-node-edge-auxiliary" or not isinstance(row.get("astNodeId"),int): raise ValueError("relation loss accepts only direct integer AST node teachers")
        if any(edge[2] not in RELATION_INDEX or edge[2]=="none" for edge in row.get("incidentRelations",[])): raise ValueError("unknown direct AST relation kind")
    return rows

def assert_formula_only_decoder_contract(path:Path)->list[dict[str,Any]]:
    rows=[json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
    if any(row.get("teacherLayer")!="formula-latex-structure-only" or "astNodeId" in row for row in rows): raise ValueError("formula-only teachers are reserved for the LaTeX decoder and cannot enter relation loss")
    return rows

def relation_targets(direct_rows:list[dict[str,Any]])->dict[str,dict[str,Tensor]]:
    """Build ordered same-formula candidate pairs only where both AST IDs are proven."""
    grouped=defaultdict(list)
    for row in direct_rows: grouped[(row["split"],row["sampleId"])].append(row)
    result={}
    for (split,sample_id),rows in grouped.items():
        node_to_index={row["astNodeId"]:index for index,row in enumerate(rows)}
        if len(node_to_index)!=len(rows): raise ValueError(f"{sample_id}: duplicate direct AST node ID")
        edge_labels=defaultdict(set)
        for row in rows:
            for source,target,kind,_ in row["incidentRelations"]:
                if source in node_to_index and target in node_to_index:
                    key=(node_to_index[source],node_to_index[target])
                    value=RELATION_INDEX[kind]
                    edge_labels[key].add(value)
        # A pair with two structural labels is not a one-class relation target.
        # Exclude it instead of selecting an arbitrary relation class.
        pairs=[(source,target) for source in range(len(rows)) for target in range(len(rows)) if source!=target and len(edge_labels.get((source,target),set()))<=1]
        result[f"{split}:{sample_id}"]={"pairIndex":torch.tensor(pairs,dtype=torch.long).reshape(-1,2),"target":torch.tensor([next(iter(edge_labels[pair])) if pair in edge_labels else 0 for pair in pairs],dtype=torch.long),"excludedAmbiguousPairs":sum(len(values)>1 for values in edge_labels.values())}
    return result

class InstanceRelationHead(nn.Module):
    """Classifies directed candidate pairs from InstanceSeparator embeddings."""
    def __init__(self,embedding_size:int=128):
        super().__init__(); self.classifier=nn.Sequential(nn.Linear(embedding_size*2,embedding_size),nn.GELU(),nn.Linear(embedding_size,len(RELATION_TYPES)))
    def forward(self,embeddings:Tensor,pair_index:Tensor)->Tensor:
        if embeddings.device.type!="mps": raise RuntimeError("InstanceRelationHead optimization requires MPS")
        if embeddings.ndim!=2 or embeddings.shape[1]!=128 or pair_index.ndim!=2 or pair_index.shape[1]!=2: raise ValueError("relation inputs require [N,128] embeddings and [P,2] indices")
        if pair_index.numel() and (torch.any(pair_index<0) or torch.any(pair_index>=embeddings.shape[0])): raise ValueError("relation pair index outside instance embedding range")
        return self.classifier(torch.cat((embeddings[pair_index[:,0]],embeddings[pair_index[:,1]]),dim=1))

def relation_loss(logits:Tensor,target:Tensor)->Tensor:
    if logits.ndim!=2 or logits.shape[1]!=len(RELATION_TYPES) or target.shape!=(logits.shape[0],) or target.dtype!=torch.long: raise ValueError("relation logits/target shape invariant failed")
    if torch.any(target<0) or torch.any(target>=len(RELATION_TYPES)): raise ValueError("relation target outside vocabulary")
    loss=F.cross_entropy(logits,target)
    if not torch.isfinite(loss): raise ValueError("relation loss is non-finite")
    return loss
