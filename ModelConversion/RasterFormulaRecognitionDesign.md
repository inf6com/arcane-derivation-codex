# FormulaRasterV1 whole-formula recognizer

## Contract

| Item | Fixed value |
| --- | --- |
| Input | one `FormulaRasterV1` PGM: `P5`, 512 x 512, 8-bit grayscale (15-byte header plus 262,144 pixels) |
| Input source | complete InkML expression only; no symbol split, cells, point sequence, trace embedding, or candidate classifier |
| Target | the source record's `normalizedLabel`, losslessly tokenized by the existing structure tokenizer |
| Split | MathWriting `train` for fitting and `valid` for gate evaluation; the `test` tree is not opened |
| Model | convolutional raster encoder retaining an 8 x 8 spatial patch sequence, cross-attention autoregressive Transformer LaTeX decoder |
| Device | `mps` is required for training; CPU/CUDA are rejected rather than silently substituted |
| Gate metrics | valid normalized-LaTeX exact match, character edit distance, and conversion by the product's `LaTeXMathMLConverter` |

The renderer converts coordinates through IEEE-754 binary32 before applying the same 32-pixel margin, segment coverage, and byte rounding as `FormulaRasterV1.swift`. Any mismatch in PGM bytes is an error; there is no alternate preprocessing path.

## Parameters and first measured run

The initial smoke run is deliberately bounded to `train=256`, `valid=64`, one epoch, `d_model=192`, and `max_tokens=128`. It is a real MPS training/evaluation run, not an adoption result. The trainer writes architecture, exact parameter count, split roots/counts, checkpoint, generated labels, and all gate metrics to its output directory. A checkpoint is never connected to Core ML or UI unless a subsequent full train/valid gate meets the product acceptance criteria.

The decoder cross-attends only to the 64 spatial raster patches and prior target tokens. It does not read InkML points, per-symbol labels, grid positions, legacy recognizer scores, or a second recognition model. The earlier global-pooled GRU failed the required train16 direct-convergence gate (0/16 after 100 epochs) and is not an execution path for this architecture.
