"""Convert the real TexTeller decoder to a one-token Core ML step model.

The exported interface keeps the decoder's 12-layer self/cross-attention KV
cache explicit. Self-attention uses a fixed 1024-slot input window and a
1025-slot output (the old window plus the new token). The Swift execution
manager supplies an attention mask, retains the valid prefix, and rolls the
window only after it is full.
"""

from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as F
from transformers import VisionEncoderDecoderModel
from transformers.models.trocr.modeling_trocr import TrOCRAttention, TrOCRDecoder


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / ".model-cache/hub/models--OleehyO--TexTeller/snapshots/7b96df06b9d81cdb129c3bef68b7250bc3e2b0ea"
OUTPUT = ROOT / "Models/TexTellerDecoderKV.mlpackage"
INIT_OUTPUT = ROOT / "Models/TexTellerDecoderInit.mlpackage"
LAYERS = 12
HEADS = 16
HEAD_DIM = 64
ENCODER_TOKENS = 785
CACHE_TOKENS = 1024


class FixedBatchTrOCRAttention(TrOCRAttention):
    """TrOCR attention with batch/head products represented as constants.

    Core ML conversion cannot lower the upstream implementation's
    ``int(batch_size * num_heads)`` when batch size is a traced tensor.  The
    app's recognizer deliberately accepts batch size one, so this preserves
    the trained operations while removing only that converter-incompatible
    shape arithmetic.
    """

    def forward(self, hidden_states, key_value_states=None, past_key_value=None,
                attention_mask=None, layer_head_mask=None,
                output_attentions=False):
        is_cross_attention = key_value_states is not None
        _, tgt_len, embed_dim = hidden_states.size()
        query_states = self.q_proj(hidden_states) * self.scaling

        if is_cross_attention and past_key_value is not None and past_key_value[0] is not None:
            key_states, value_states = past_key_value
        elif is_cross_attention:
            key_states = self._shape(self.k_proj(key_value_states), -1, 1)
            value_states = self._shape(self.v_proj(key_value_states), -1, 1)
        elif past_key_value is not None:
            key_states = self._shape(self.k_proj(hidden_states), -1, 1)
            value_states = self._shape(self.v_proj(hidden_states), -1, 1)
            key_states = torch.cat([past_key_value[0], key_states], dim=2)
            value_states = torch.cat([past_key_value[1], value_states], dim=2)
        else:
            key_states = self._shape(self.k_proj(hidden_states), -1, 1)
            value_states = self._shape(self.v_proj(hidden_states), -1, 1)

        if self.is_decoder:
            past_key_value = (key_states, value_states)

        query_states = self._shape(query_states, tgt_len, 1).view(HEADS, -1, HEAD_DIM)
        key_states = key_states.view(HEADS, -1, HEAD_DIM)
        value_states = value_states.view(HEADS, -1, HEAD_DIM)
        src_len = key_states.size(1)
        attn_weights = torch.bmm(query_states, key_states.transpose(1, 2))

        if attention_mask is not None:
            attn_weights = attn_weights.view(1, HEADS, tgt_len, src_len) + attention_mask
            attn_weights = attn_weights.view(HEADS, tgt_len, src_len)

        attn_weights = torch.nn.functional.softmax(attn_weights, dim=-1)
        if layer_head_mask is not None:
            attn_weights = layer_head_mask.view(1, HEADS, 1, 1) * attn_weights.view(1, HEADS, tgt_len, src_len)
            attn_weights = attn_weights.view(HEADS, tgt_len, src_len)

        attn_weights_reshaped = attn_weights.view(1, HEADS, tgt_len, src_len) if output_attentions else None
        attn_output = torch.bmm(attn_weights, value_states)
        attn_output = attn_output.view(1, HEADS, tgt_len, HEAD_DIM).transpose(1, 2)
        attn_output = attn_output.reshape(1, tgt_len, embed_dim)
        return self.out_proj(attn_output), attn_weights_reshaped, past_key_value


def replace_attention(module, config):
    for layer in module.layers:
        for name in ("self_attn", "encoder_attn"):
            original = getattr(layer, name)
            replacement = FixedBatchTrOCRAttention(
                config, original.embed_dim, original.num_heads, original.kdim,
                original.vdim, original.dropout, original.is_decoder,
                bias=True, is_cross_attention=(name == "encoder_attn"),
            )
            replacement.load_state_dict(original.state_dict())
            setattr(layer, name, replacement)


class DecoderKV(torch.nn.Module):
    def __init__(self, decoder, include_encoder_cache):
        super().__init__()
        self.include_encoder_cache = include_encoder_cache
        self.decoder = PositionAwareTrOCRDecoder(decoder.model.decoder)
        self.output_projection = decoder.output_projection

    def forward(self, input_ids, encoder_hidden_states, attention_mask, position_ids, *flat_cache):
        width = 4 if self.include_encoder_cache else 2
        cache = []
        for i in range(LAYERS):
            self_cache = (flat_cache[i * width], flat_cache[i * width + 1])
            if self.include_encoder_cache:
                cache.append(self_cache + (flat_cache[i * width + 2], flat_cache[i * width + 3]))
            else:
                # Keep TrOCRDecoderLayer's four-slot cache contract while
                # explicitly marking the initial cross-attention cache empty.
                cache.append(self_cache + (None, None))
        cache = tuple(cache)
        result = self.decoder(
            input_ids=input_ids,
            encoder_hidden_states=encoder_hidden_states,
            attention_mask=attention_mask,
            position_ids=position_ids,
            past_key_values=cache,
            use_cache=True,
            return_dict=True,
        )
        logits = self.output_projection(result.last_hidden_state)
        return (logits,) + tuple(value for layer in result.past_key_values for value in layer)


class PositionAwareTrOCRDecoder(TrOCRDecoder):
    """TrOCR decoder with explicit position IDs for a fixed rolling cache.

    The upstream decoder derives position from the physical cache length. That
    is correct for a variable-length PyTorch cache but cannot represent a
    fixed Core ML cache whose inactive slots are masked. This implementation
    retains the trained decoder layers and changes only position selection and
    the one-token masked attention path.
    """

    def __init__(self, decoder):
        super().__init__(decoder.config)
        self.load_state_dict(decoder.state_dict())
        replace_attention(self, decoder.config)

    def forward(self, input_ids, attention_mask, encoder_hidden_states,
                position_ids, past_key_values, use_cache=True, return_dict=True):
        input_ids = input_ids.view(-1, input_ids.shape[-1])
        hidden_states = self.embed_tokens(input_ids)
        position_embeddings = F.embedding(position_ids + self.embed_positions.offset, self.embed_positions.weight)
        hidden_states = self.layernorm_embedding(hidden_states + position_embeddings)
        source_mask = (1.0 - attention_mask.to(hidden_states.dtype)).view(1, 1, 1, CACHE_TOKENS + 1) * -10000.0

        next_cache = []
        for index, layer in enumerate(self.layers):
            layer_output = layer(
                hidden_states,
                attention_mask=source_mask,
                encoder_hidden_states=encoder_hidden_states,
                encoder_attention_mask=None,
                layer_head_mask=None,
                cross_attn_layer_head_mask=None,
                past_key_value=past_key_values[index],
                output_attentions=False,
                use_cache=use_cache,
            )
            hidden_states = layer_output[0]
            next_cache.append(layer_output[1])

        return type("DecoderResult", (), {
            "last_hidden_state": hidden_states,
            "past_key_values": tuple(next_cache),
        })()


def convert(wrapper, output, include_encoder_cache):
    input_ids = torch.tensor([[2]], dtype=torch.long)
    encoder_hidden_states = torch.zeros((1, ENCODER_TOKENS, 768), dtype=torch.float32)
    attention_mask = torch.ones((1, CACHE_TOKENS + 1), dtype=torch.long)
    position_ids = torch.tensor([[0]], dtype=torch.long)
    cache = []
    for _ in range(LAYERS):
        cache.extend([
            torch.zeros((1, HEADS, CACHE_TOKENS, HEAD_DIM)), torch.zeros((1, HEADS, CACHE_TOKENS, HEAD_DIM)),
        ])
        if include_encoder_cache:
            cache.extend([
                torch.zeros((1, HEADS, ENCODER_TOKENS, HEAD_DIM)), torch.zeros((1, HEADS, ENCODER_TOKENS, HEAD_DIM)),
            ])
    with torch.no_grad():
        result = wrapper(input_ids, encoder_hidden_states, attention_mask, position_ids, *cache)
    if tuple(result[0].shape) != (1, 1, 15000):
        raise RuntimeError(f"unexpected logits shape: {tuple(result[0].shape)}")
    traced = torch.jit.trace(wrapper, (input_ids, encoder_hidden_states, attention_mask, position_ids, *cache), strict=False)

    inputs = [
        ct.TensorType(name="input_ids", shape=(1, 1), dtype=np.int32),
        ct.TensorType(name="encoder_hidden_states", shape=(1, ENCODER_TOKENS, 768), dtype=np.float16),
        ct.TensorType(name="attention_mask", shape=(1, CACHE_TOKENS + 1), dtype=np.int32),
        ct.TensorType(name="position_ids", shape=(1, 1), dtype=np.int32),
    ]
    for i in range(LAYERS):
        inputs.extend([
            ct.TensorType(name=f"past_key_values_{i}_decoder_key", shape=(1, HEADS, CACHE_TOKENS, HEAD_DIM), dtype=np.float16),
            ct.TensorType(name=f"past_key_values_{i}_decoder_value", shape=(1, HEADS, CACHE_TOKENS, HEAD_DIM), dtype=np.float16),
        ])
        if include_encoder_cache:
            inputs.extend([
                ct.TensorType(name=f"past_key_values_{i}_encoder_key", shape=(1, HEADS, ENCODER_TOKENS, HEAD_DIM), dtype=np.float16),
                ct.TensorType(name=f"past_key_values_{i}_encoder_value", shape=(1, HEADS, ENCODER_TOKENS, HEAD_DIM), dtype=np.float16),
            ])
    output_names = ["logits"] + [
        f"present_{i}_{part}" for i in range(LAYERS)
        for part in ("decoder_key", "decoder_value", "encoder_key", "encoder_value")
    ]
    converted = ct.convert(
        traced, inputs=inputs, outputs=[ct.TensorType(name=name) for name in output_names],
        convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    converted.save(output)
    print(f"SAVED {output}")


def main():
    model = VisionEncoderDecoderModel.from_pretrained(SOURCE, local_files_only=True).eval()
    replace_attention(model.decoder.model.decoder, model.decoder.config)
    convert(DecoderKV(model.decoder, include_encoder_cache=False).eval(), INIT_OUTPUT, False)
    convert(DecoderKV(model.decoder, include_encoder_cache=True).eval(), OUTPUT, True)


if __name__ == "__main__":
    main()
