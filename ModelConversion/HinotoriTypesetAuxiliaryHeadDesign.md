# Hinotori auxiliary typeset-symbol head

Product-level ensemble roles and probability fusion are specified in [HinotoriEnsembleDesign.md](../Design/HinotoriEnsembleDesign.md).

## Purpose

Provide a typeset-glyph visual branch for Hinotori's 229-class isolated-symbol
recognizer. The branch receives the same normalized 64×64 raster as the
handwriting classifier and emits raw logits for 222 labels with verified
standalone glyphs. It runs alongside handwriting recognition and contributes
to the calibrated Hinotori candidate ensemble; it never routes or filters the
input before the handwriting branch runs.

## Training contract

- Source: the existing Mac-font raster corpus, with glyph-to-vocabulary labels
  verified by the corpus manifest. Structural tokens without standalone glyphs
  are omitted, never fabricated.
- Initialization: the selected Fold-07 stroke-set checkpoint supplies a frozen
  raster branch (`raster_features` + `raster_projection`). The supplemental
  linear head reads this 128-dimensional image-only representation in parallel with the
  original handwritten path, which continues to use raster and stroke
  trajectories. Only the supplemental output layer is trained; every Fold-07
  parameter, including its 229-class handwritten head, remains unchanged.
- Font split: source font-file hashes, not glyph images or resolution variants,
  define the partition. The typeset head trains only on fit-font hashes and is
  measured on disjoint validation-font hashes.
- Handwriting check: Fold-07 inner-validation sources are scored before and
  after adding the supplemental head's candidates. The primary head's logits
  and Top-1/Top-5 must remain byte-for-byte unchanged. Outer-test data is not
  opened for this development experiment.
- Combination: preserve each branch's raw output. Calibrate each branch with a
  temperature, convert to probabilities, map the 222 supported typeset labels
  into the shared 229-label vocabulary, and mix probabilities with a
  validation-selected convex weight. Never add uncalibrated logits.

## Acceptance and saved artifacts

The experiment writes the head checkpoint, ordered supported-label mapping,
font-hash split, metrics, and hashes under a new run directory. It is useful
only if it adds held-out handwritten candidate coverage without changing the
primary classifier, and its held-out-font metrics demonstrate that the head
learned beyond memorizing font files. A failure remains a measured negative
result; it does not replace or modify Fold-07.

Typeset glyphs are not treated as handwritten training examples. Their output
is a calibrated second visual signal; it does not replace the handwriting
classifier, and neither branch auto-confirms a symbol.

## Measured development result (2026-11-05)

- MPS execution was measured on Apple M4; the Fold-07 StrokeSet checkpoint was
  frozen and only the 222-label auxiliary linear head was trained.
- Fit/validation were separated by font-file hash: 202 fit files (54,014 glyphs)
  and 10 held-out files (3,234 glyphs). Seven structural labels without verified
  standalone glyphs were excluded.
- Held-out-font Top-1/Top-5 were 87.11%/99.66%. These scores measure typeset
  glyph classification and do not estimate handwriting recognition.
- On the 450-example Fold-07 inner-valid handwriting split, primary exact
  Top-1/Top-5 remained 58.67%/92.44%. Taking the union of primary Top-5 and
  auxiliary Top-5 yielded Top-10 candidate coverage of 95.33%, recovering 13
  additional examples. Primary logits were bitwise equal across independent
  pre/post scoring passes.
- This is candidate coverage, not corrected Top-1 accuracy. It is the saved
  development evidence used to expose the separately sourced candidates in the
  app; it is not a claim of corrected handwriting accuracy. The outer test split
  remains unopened.
- Full metrics, checkpoints, font split, and hashes are stored under
  `runs/hinotori-typeset-auxiliary-head-strokeset-verified-20261105/`.

## Application connection

- `HinotoriTypesetAuxiliaryHead.mlpackage` is bundled beside the Fold-07 model,
  its manifest, and its ordered supported-label vocabulary.
- For each segmented symbol group, the app rasterizes the same original strokes
  through `HinotoriStrokeSetInput.buildRasterOnly`, converts the resulting
  64×64 raster to the Core ML float16 interface, and reads all 222 raw typeset
  logits. The handwriting branch supplies its original 229 classifier logits
  for calibration; its prototype cosine similarities remain separate and are
  never converted into classifier logits.
- `HinotoriSymbolCandidateEnsemble` checks its calibration file against both
  branch checkpoint hashes, vocabulary hash, supported class indices, and the
  Fold7 logit scale. It temperature-scales the logits, softmaxes each branch,
  assigns zero typeset probability to the seven unsupported structural labels,
  and mixes the two distributions with weights 0.745/0.255. The resulting
  single Top-5 is then passed to the coordinate-independent visual-subset
  expansion and, separately, the position-sensitive classifier.
- The 87 prototype-cosine similar-symbol subsets form a post-ensemble
  candidate-expansion index, not a third classifier branch. For a selected
  ensemble Top-5 class, matching subsets are retrieved and their other members are ordered by
  that input's Fold7 prototype cosine. This expansion never changes the fused
  probability or ensemble Top-5. Raw typeset Top-5 and original Fold7 Top-5
  remain separately attributed evidence. Candidates remain provisional until
  user confirmation.
- The package requests `.cpuAndNeuralEngine`; this is a compute-unit preference,
  not evidence that the ANE executed the graph. Device dispatch remains to be
  verified on iPad.
- App wiring and resource registration are implemented in
  `HinotoriTypesetAuxiliaryCoreMLClassifier.swift`,
  `TexTellerFormulaRecognition.swift`, the renamed
  `HinotoriVisualSimilaritySubsets.json`, and the Xcode project. Build and
  device-level interaction still require direct verification.

## Product model identity and calibration evidence

The product model is **Hinotori isolated-symbol ensemble**. Its probability
fusion has two branches: the **handwritten shape classifier** and the
**typeset glyph classifier**. The **87 prototype-cosine similar-symbol
subsets** form a downstream candidate-expansion index, not an ensemble branch.
The separate 124 visual subsets are confusion-derived candidate evidence;
ViT names their catalog-generation method, not a product classifier branch.
Fold numbers remain checkpoint provenance only.

The current calibration artifact is
`Models/Hinotori/Ensemble/HinotoriCandidateEnsemble.json`. It was fitted on 450
Fold-07 inner-validation examples from 157 source IDs. On that development set,
the recorded Fold7 result is 64.44% Top-1 / 88.22% Top-5 and the calibrated
mixture is 65.33% / 89.33%. This is the same inner-validation split used during
development and is not an independent test result. The outer test was not
opened. These measurements justify wiring and debugging the ensemble, not a
claim of generalization or model acceptance; a source-disjoint final
evaluation remains required.
