"""Validate the public Core ML interfaces consumed by TexTellerExecutionManager."""

from pathlib import Path

import coremltools as ct


ROOT = Path(__file__).resolve().parents[1]
LAYERS = 12
HEADS = 16
HEAD_DIM = 64
CACHE = 1024
ENCODER_TOKENS = 785
ENCODER_HIDDEN = 768
VOCAB = 15000


def shape(description):
    return tuple(int(value) for value in description.type.multiArrayType.shape)


def require(mapping, name, expected):
    if name not in mapping:
        raise RuntimeError(f"missing feature: {name}")
    actual = shape(mapping[name])
    if actual != expected:
        raise RuntimeError(f"{name}: expected {expected}, got {actual}")


def validate(path: Path, recurrent: bool):
    spec = ct.models.MLModel(str(path)).get_spec()
    inputs = {item.name: item for item in spec.description.input}
    outputs = {item.name: item for item in spec.description.output}
    require(inputs, "input_ids", (1, 1))
    require(inputs, "encoder_hidden_states", (1, ENCODER_TOKENS, ENCODER_HIDDEN))
    require(inputs, "attention_mask", (1, CACHE + 1))
    require(inputs, "position_ids", (1, 1))
    for layer in range(LAYERS):
        for part in ("decoder_key", "decoder_value"):
            require(inputs, f"past_key_values_{layer}_{part}", (1, HEADS, CACHE, HEAD_DIM))
        if recurrent:
            for part in ("encoder_key", "encoder_value"):
                require(inputs, f"past_key_values_{layer}_{part}", (1, HEADS, ENCODER_TOKENS, HEAD_DIM))
        for part in ("decoder_key", "decoder_value"):
            require(outputs, f"present_{layer}_{part}", (1, HEADS, CACHE + 1, HEAD_DIM))
        for part in ("encoder_key", "encoder_value"):
            require(outputs, f"present_{layer}_{part}", (1, HEADS, ENCODER_TOKENS, HEAD_DIM))
    require(outputs, "logits", (1, 1, VOCAB))
    print(f"VALID {path.name}: inputs={len(inputs)} outputs={len(outputs)}")


if __name__ == "__main__":
    validate(ROOT / "Models/TexTellerDecoderInit.mlpackage", recurrent=False)
    validate(ROOT / "Models/TexTellerDecoderKV.mlpackage", recurrent=True)
