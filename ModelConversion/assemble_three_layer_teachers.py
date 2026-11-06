#!/usr/bin/env python3
"""Assemble proven instance, AST-auxiliary, and formula-only teacher layers."""
from __future__ import annotations
import argparse,json
from collections import Counter,defaultdict
from pathlib import Path

def rows(path): return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
def write(path,values): path.write_text("".join(json.dumps(value,ensure_ascii=False)+"\n" for value in values),encoding="utf-8")

def split_by_instance_files(train_path,validation_path):
    train={row["instanceId"]:row["sampleId"] for row in rows(train_path)}; validation={row["instanceId"]:row["sampleId"] for row in rows(validation_path)}
    if set(train)&set(validation): raise ValueError("instance split overlap")
    formula_train=set(train.values()); formula_validation=set(validation.values())
    if formula_train&formula_validation: raise ValueError("formula split overlap")
    return {**{key:"train" for key in train},**{key:"validation" for key in validation}}

def assemble(instances,alignment,structures,split):
    instance_by_id={row["instanceId"]:row for row in instances}; alignment_by_id={row["instanceId"]:row for row in alignment}
    if set(instance_by_id)!=set(alignment_by_id) or set(instance_by_id)!=set(split): raise ValueError("instance, alignment, and split identity sets must match exactly")
    structure_by_id={row["sampleId"]:row for row in structures}
    all_instances=[]; ast_aux=[]; formula_assignments=[]
    for instance_id,instance in instance_by_id.items():
        sample_id=instance["sampleId"]; match=alignment_by_id[instance_id]; partition=split[instance_id]
        if sample_id!=match["sampleId"] or sample_id not in structure_by_id: raise ValueError(f"{instance_id}: source identity mismatch")
        all_instances.append({**instance,"split":partition,"teacherLayer":"instance-mask-bbox-class"})
        if match["outcome"]=="direct":
            node_id=match.get("astNodeId")
            if not isinstance(node_id,int): raise ValueError(f"{instance_id}: direct AST row has no integer node ID")
            relations=[edge for edge in structure_by_id[sample_id]["relations"] if node_id in edge[:2]]
            ast_aux.append({"sampleId":sample_id,"instanceId":instance_id,"split":partition,"astNodeId":node_id,"incidentRelations":relations,"teacherLayer":"ast-node-edge-auxiliary"})
        else:
            if match.get("astNodeId") is not None: raise ValueError(f"{instance_id}: non-direct row must not hold AST node ID")
            formula_assignments.append({"sampleId":sample_id,"instanceId":instance_id,"split":partition,"outcome":match["outcome"],"reason":match["reason"],"teacherLayer":"formula-latex-structure-only"})
    fallback_formula_ids={row["sampleId"] for row in formula_assignments}
    formula_structures=[{**structure_by_id[sample_id],"split":next(row["split"] for row in formula_assignments if row["sampleId"]==sample_id),"teacherLayer":"formula-latex-structure-only"} for sample_id in sorted(fallback_formula_ids)]
    return all_instances,ast_aux,formula_assignments,formula_structures

def validate(all_instances,ast_aux,assignments,structures):
    if len(all_instances)!=6423: raise ValueError("all instance layer must retain exactly 6,423 teachers")
    if any(not isinstance(row["astNodeId"],int) for row in ast_aux): raise ValueError("AST auxiliary may not encode null node IDs")
    if any("astNodeId" in row for row in assignments): raise ValueError("formula-only assignments must omit astNodeId, never coerce it")
    by_formula=defaultdict(set)
    for row in all_instances: by_formula[row["sampleId"]].add(row["split"])
    if len(by_formula)!=3426 or any(len(parts)!=1 for parts in by_formula.values()): raise ValueError("formula split isolation failed")
    if {row["sampleId"] for row in structures}!={row["sampleId"] for row in assignments}: raise ValueError("formula structure teacher coverage mismatch")

def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--instances",type=Path,required=True); parser.add_argument("--alignment",type=Path,required=True); parser.add_argument("--structures",type=Path,required=True); parser.add_argument("--train",type=Path,required=True); parser.add_argument("--validation",type=Path,required=True); parser.add_argument("--out",type=Path,required=True); args=parser.parse_args()
    args.out.mkdir(parents=True,exist_ok=True); split=split_by_instance_files(args.train,args.validation); result=assemble(rows(args.instances),rows(args.alignment),rows(args.structures),split); validate(*result)
    names=("all-instance-teachers.jsonl","direct-ast-aux-teachers.jsonl","formula-only-assignments.jsonl","formula-only-structure-teachers.jsonl")
    for name,values in zip(names,result): write(args.out/name,values)
    report={"layerCounts":{"instanceMaskBBoxClass":len(result[0]),"directAstNodeEdge":len(result[1]),"formulaOnlyAssignments":len(result[2]),"formulaOnlyStructures":len(result[3])},"splitCounts":{layer:dict(Counter(row["split"] for row in values)) for layer,values in zip(("instance","astAux","formulaAssignments","formulaStructures"),result)},"formulaCount":3426,"nullAstNodeIdInAuxiliary":sum(row.get("astNodeId") is None for row in result[1]),"formulaOnlyRowsWithAstNodeId":sum("astNodeId" in row for row in result[2])}
    (args.out/"report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
if __name__=="__main__": main()
