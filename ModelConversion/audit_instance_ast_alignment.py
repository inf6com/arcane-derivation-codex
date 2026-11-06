#!/usr/bin/env python3
"""Audit direct symbol-instance to LaTeX AST node eligibility without guessing IDs."""
from __future__ import annotations
import argparse,json
from collections import Counter,defaultdict
from pathlib import Path

# Every rule is explicit.  Composite source labels deliberately remain
# unsupported because an atomic handwritten instance is not a single AST node.
NORMALIZATION={"identity":{"kind":"direct","description":"source symbolToken equals AST node token"},"mathbbComposite":{"kind":"unsupported","description":"source \\mathbb{X} expands to AST \\mathbb plus X and cannot receive one node ID"}}

def normalized(token:str)->tuple[str,str]:
    if token.startswith("\\mathbb{") and token.endswith("}") and len(token)==9: return "mathbbComposite",token
    return "identity",token

def structure_index(path:Path)->dict[str,list[dict]]:
    result={}
    for line in path.read_text(encoding="utf-8").splitlines():
        row=json.loads(line); sample_id=row["sampleId"]
        if sample_id in result: raise ValueError(f"duplicate AST sampleId {sample_id}")
        nodes=row.get("nodes")
        if not isinstance(nodes,list) or any(not isinstance(node.get("nodeId"),int) or not isinstance(node.get("token"),str) for node in nodes): raise ValueError(f"{sample_id}: invalid AST nodes")
        result[sample_id]=nodes
    return result

def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--instances",type=Path,required=True); parser.add_argument("--structure",type=Path,required=True); parser.add_argument("--rows",type=Path,required=True); parser.add_argument("--report",type=Path,required=True); args=parser.parse_args()
    ast=structure_index(args.structure); instances=defaultdict(list)
    for line in args.instances.read_text(encoding="utf-8").splitlines():
        row=json.loads(line); instances[row["sampleId"]].append(row)
    alignment=[]; status=Counter(); source_only=Counter(); node_only=Counter(); formula_status=Counter(); duplicate_causes=Counter()
    for sample_id,rows in instances.items():
        nodes=ast.get(sample_id)
        if nodes is None: raise ValueError(f"{sample_id}: missing AST source")
        source=Counter(row["symbolToken"] for row in rows); ast_tokens=Counter(node["token"] for node in nodes)
        source_only.update(source-ast_tokens); node_only.update(ast_tokens-source)
        direct_count=ambiguous_count=unmatched_count=0
        for row in rows:
            rule,token=normalized(row["symbolToken"])
            candidates=[node["nodeId"] for node in nodes if node["token"]==token]
            if rule!="identity": outcome="unmatched"; reason=rule; unmatched_count+=1
            elif not candidates: outcome="unmatched"; reason="noMatchingAstToken"; unmatched_count+=1
            elif source[token]==1 and len(candidates)==1: outcome="direct"; reason="uniqueSourceAndAstToken"; direct_count+=1
            else:
                outcome="ambiguous"; reason="repeatedSourceOrAstToken"; ambiguous_count+=1
                duplicate_causes[f"sourceOccurrences={source[token]},astOccurrences={len(candidates)}"]+=1
            # candidateNodeIds are evidence only. astNodeId is emitted only when unique.
            alignment.append({"sampleId":sample_id,"instanceId":row["instanceId"],"symbolToken":row["symbolToken"],"normalizationRule":rule,"outcome":outcome,"reason":reason,"candidateNodeIds":candidates,"astNodeId":candidates[0] if outcome=="direct" else None})
            status[outcome]+=1
        formula_status["directOnly" if ambiguous_count==unmatched_count==0 else "hasAmbiguous" if ambiguous_count and not unmatched_count else "hasUnmatched" if unmatched_count and not ambiguous_count else "hasAmbiguousAndUnmatched"]+=1
    args.rows.write_text("".join(json.dumps(row,ensure_ascii=False)+"\n" for row in alignment),encoding="utf-8")
    report={"normalization":NORMALIZATION,"formulaCount":len(instances),"instanceCount":len(alignment),"outcomes":dict(status),"formulaOutcomes":dict(formula_status),"directNodeEdgeEligibleInstances":status["direct"],"directNodeEdgeEligibleFormulaCount":formula_status["directOnly"],"topSourceTokenDifferences":source_only.most_common(30),"topAstOnlyTokens":node_only.most_common(30),"duplicateCauses":duplicate_causes.most_common(30),"rule":"strokeIndices are temporal input order and are never used as visual AST order; repeated source or AST tokens remain ambiguous"}
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
if __name__=="__main__": main()
