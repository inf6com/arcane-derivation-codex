# Structure relation teacher JSONL schema

This schema is train-only supervision for the instance separator, 229-class symbol
classifier, and relation/structure model. It does not supply model predictions,
rules, or a fallback serialiser.

Each JSONL record represents one formula and has this stable identity:

```json
{
  "sampleId": "MathWriting source sample ID",
  "latex": "losslessly reconstructed normalized LaTeX",
  "nodes": [
    {
      "nodeId": "stable within sampleId",
      "token": "observed visual token or structural operator",
      "parentNodeId": "nodeId or null for root",
      "parentRelation": "relation kind to parent",
      "structurePosition": 0
    }
  ],
  "relations": [
    {"parentNodeId": "…", "childNodeId": "…", "kind": "…", "structurePosition": 0}
  ]
}
```

`nodeId` is deterministic from preorder traversal within `sampleId`; it is never a
display index or a spatial-grid cell. The emitted `root` node is the syntax scope
of the formula. `structurePosition` is the zero-based order
among siblings with the same parent and relation. For an annotated formula, a
separate join by `sampleId` associates `symbols.jsonl` records; its
`strokeIndices` are the direct instance-separation target and its `label` is the
229-class target. The structural JSONL never invents a stroke group for an
unannotated formula.

Allowed relation kinds are `baseline`, `superscript`, `subscript`, `numerator`,
`denominator`, `radicand`, `radical-index`, `matrix-row`, `matrix-cell`, and
`delimiter`. A `delimiter` edge attaches a literal delimiter to its parsed syntax
scope; it does not fabricate a symmetric pair for legitimate asymmetric interval
or bra/ket notation. Every node except the root has exactly one parent relation.
A parser
generation is inadmissible when reconstruction differs from `latex`, an input
label fails, a relation kind is outside this set, or a node identifier is not
unique. The current v3 artifact is lossless for all train labels but its emitted
edge representation has not yet supplied every relation kind; it is therefore an
audit input, not yet a relation-model training target.
