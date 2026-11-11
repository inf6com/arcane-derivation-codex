# Hinotori Retrieval Core ML Contract v1

> **Deployment status 2026-11-03:** The rejected Hinotori Core ML packages, their anchor-bank resources, vocabulary resource, and Xcode bundle references have been removed. This document is the converter/validation contract only; it does not assert that a model is currently bundled or usable. Handwritten recognition through this executor fails explicitly until a replacement model and its matching resources pass evaluation and are deliberately integrated.

`HinotoriRetrievalModel` is exported as two Core ML programs.  They retain
the checkpoint's trajectory encoder, GRU parameters, affinity projection,
cosine normalization, temperature, and class-wise log-sum-exp retrieval.  No
229-way classifier head or alternate recognizer is introduced.

## Inputs and outputs

All model tensors are `float32`.

`HinotoriAffinity.mlpackage` accepts one formula:

| Name | Shape | Meaning |
| --- | --- | --- |
| `tracePoints` | `[1, F, 32, 2]` | Canonicalized, resampled formula traces |
| `traceValid` | `[1, F]` | Exact `0` or `1` validity mask |
| `affinityLogits` | `[F, F]` | Same-symbol pair logit matrix |
| `strokeEmbeddings` | `[F, 128]` | Encoder embeddings for diagnostics and parity verification |

`HinotoriRetrieval.mlpackage` ranks one already-decoded symbol group:

| Name | Shape | Meaning |
| --- | --- | --- |
| `queryPoints` | `[1, S, 32, 2]` | One canonical symbol-group trajectory tensor |
| `queryStrokeValid` | `[1, S]` | Exact `0` or `1` mask; at least one `1` is required |
| `anchorPoints` | `[A, S, 32, 2]` | Exported direct-anchor trajectories |
| `anchorStrokeValid` | `[A, S]` | Exported direct-anchor mask |
| `classLogits` | `[1, 229]` | Retrieval logits for all Hinotori classes |
| `queryEmbedding` | `[1, 128]` | Query encoder result for parity verification |
| `anchorEmbeddings` | `[A, 128]` | Anchor encoder results for parity verification |

`A`, `S`, and `F` are artifact constants.  The converter derives `A` and `S`
from the verified training direct-anchor set.  `F` is fixed at **80** for the
product contract.  This is not an arbitrary padding value: the 208,579 fully
mapped train weak-teacher formulas were measured from their source InkML on
2026-10-21 JST; their maximum trace count was 80 (p50 12, p95 23, p99 29,
and zero formulas exceeded 80).  The app and converter must use this same
value.  Any input with more than 80 traces is rejected rather than cropped,
split, or routed to a different recognizer.

The converter writes the direct-anchor bank as `HinotoriAnchorPoints.f32le`,
`HinotoriAnchorStrokeValid.f32le`, and `HinotoriAnchorClasses.i64le`, plus the
vocabulary JSON and manifest. The manifest records the checkpoint hash,
SHA-256 for each anchor array and vocabulary, exact shapes and dtypes, and the
anchor class mapping. It does not write an NPZ archive.

## Required iOS sequence

1. Reject an input outside the published coordinate and canonicalization
   contract, or with more than `F` traces.
2. Invoke `HinotoriAffinity`.
3. For valid traces only, connect `i` and `j` when
   `affinityLogits[i,j] > 0`; take connected components exactly as
   `decode_groups` does.  This is deterministic postprocessing, not an
   alternate model.
4. Canonicalize every component exactly as `canonical_group_tensor` does.
   Reject a component with more than `S` strokes.
5. Invoke `HinotoriRetrieval` using the unmodified anchor bank bundled with
   the manifest.  The largest `classLogits` value is the class candidate.

No default class, cropped excess trace, substituted anchor bank, or legacy
recognizer is permitted.

## Conversion and verification

変換には、現在の `HinotoriRetrievalModel` と `hinotori-retrieval-v1` 契約で学習・保存されたチェックポイント、`hinotori-v1` 語彙、同じ契約で作成した直接アンカー集合を指定します。変換スクリプトは契約不一致を拒否します。過去の別スキーマのチェックポイントを読み替えて変換してはいけません。入力パスは検証済み学習成果物のmanifestから指定してください。

The converter defaults to `--compute-precision float32`. `float16` is an
explicit experimental conversion mode for ANE dispatch. Input and output
feature tensors remain float32 in either mode; only the converted program's
internal compute precision changes. A float16 package is not eligible for the
application bundle until numerical parity and the same held-out symbol
evaluation pass, followed by an on-device compute-plan and inference check.

Run `validate_hinotori_retrieval_coreml.py` on the generated directory before
adoption.  It rejects a changed non-finite affinity mask, a different Top-1
class, or a maximum absolute difference above `1e-5`.

## ANE innovation acceptance gate

Actual Apple Neural Engine inference on a supported physical iPad is a
necessary acceptance condition before Hinotori is described as an innovative
edge-computing model. It is not, by itself, evidence of algorithmic novelty or
recognition superiority. Those claims require separate, same-data comparisons.

Record the device and OS, model/checkpoint and vocabulary hashes, Core ML
compute plan, operation placement, CPU/GPU fallback or unsupported operations,
parity against the fixed PyTorch checkpoint, exact isolated-symbol Top-1/Top-5,
latency, peak memory, and energy. The learned recognition graph must have
measured ANE execution; setting `.cpuAndNeuralEngine`, compiling a package, or
running in Simulator does not satisfy this gate. Training on Mac MPS and
inference on iPad ANE are separate requirements. No ANE pass is currently
claimed; the rejected packages noted above remain excluded until a replacement
passes this gate and the app's end-to-end acceptance requirements.
