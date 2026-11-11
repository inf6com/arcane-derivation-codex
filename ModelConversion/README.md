# Core ML model conversion

`TexTellerEncoder.mlpackage`, `TexTellerDecoderInit.mlpackage`, and
`TexTellerDecoderKV.mlpackage` are converted from the complete local
TexTeller VisionEncoderDecoder checkpoint. The source checkpoint, tokenizer,
configuration, converter environment, and conversion script remain separate
from the app bundle.

The decoder is split because the Transformer has two different runtime
states:

- `TexTellerDecoderInit.mlpackage` computes cross-attention K/V from the
  encoder output on the first token. It accepts self-attention K/V only and
  returns self K/V with 1025 slots plus cross K/V with 785 encoder slots.
- `TexTellerDecoderKV.mlpackage` accepts both self and cross K/V and reuses
  the cross-attention state for every later token.

Both models are batch-one, one-token models. Their logits shape is
`[1, 1, 15000]`; self-cache inputs are `[1, 16, 1024, 64]`, self-cache
outputs are `[1, 16, 1025, 64]`, and encoder-cache tensors are
`[1, 16, 785, 64]`. `TexTellerExecutionManager.swift` owns the state machine,
EOS handling, position IDs, attention masks, and 1024-slot continuation
windows. The Core ML models do not silently truncate a longer expression.

Conversion requires the complete local checkpoint, tokenizer/configuration,
and the pinned Python environment. `convert_texteller_decoder_kv.py` changes
only the converter-incompatible batch/head arithmetic and the explicit
initial-versus-recurrent cache interface; trained weights and attention
operations are retained. The script fails before saving if the logits or
cache shapes differ from the contract.

`validate_texteller_models.py` checks both saved packages against the same
interface consumed by the Swift execution manager. A package that fails this
check is not an acceptable app resource.
