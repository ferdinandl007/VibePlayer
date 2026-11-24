"""Static YuE2 Core ML programs and GGUF Q4_0 conversion."""
import coremltools as ct
import numpy as np
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import get_new_symbol, types
from gguf import GGUFReader
from gguf.quants import dequantize
from decoder_ops import build_decoder

LAYERS, HIDDEN, KV_HEADS, HEAD_DIM, LATENT = 28, 2048, 8, 128, 64
MUSIC_END, CODEC_END = 151852, 151853 + 32768


def spec(*shape):
    return mb.TensorSpec(shape, dtype=types.fp16)


def q4_arrays(t, rows=slice(None)):
    size = int(t.shape[0])
    blocks = t.data[rows].reshape(-1, size // 32, 18)
    scale = np.ascontiguousarray(blocks[:, :, :2]).view("<f2").reshape(blocks.shape[:2])
    nibbles = blocks[:, :, 2:]
    data = np.concatenate((nibbles & 15, nibbles >> 4), axis=2).reshape(-1, size)
    signed = data.astype(np.int8) - 8
    return signed, scale


def weights_fp32(t):
    return dequantize(t.data, t.tensor_type).astype(np.float32, copy=False)


class Transformer:
    def __init__(self, checkpoint):
        self.tensors = {t.name.removeprefix("model_weights/"): t for t in GGUFReader(checkpoint).tensors}

    def weight(self, name):
        return weights_fp32(self.tensors[name]).astype(np.float16)

    def linear(self, x, name, rows=slice(None), bias=False):
        tensor = self.tensors[f"{name}.weight"]
        if tensor.tensor_type.name == "Q4_0":
            data, scales = q4_arrays(tensor, rows)
            weight = mb.constexpr_blockwise_shift_scale(data=data.astype(types.np_int4_dtype), scale=scales)
        else:
            weight = self.weight(f"{name}.weight")[rows]
        return mb.linear(x=x, weight=weight, bias=self.weight(f"{name}.bias") if bias else None)

    def rms(self, x, name):
        moment = mb.reduce_mean(x=mb.square(x=x), axes=[-1], keep_dims=True)
        inv = mb.rsqrt(x=mb.add(x=moment, y=np.float16(1e-6)))
        return mb.mul(x=mb.mul(x=x, y=inv), y=self.weight(f"{name}.weight"))

    @staticmethod
    def rotate(x, sine, cosine):
        even, odd = mb.split(x=x, num_splits=2, axis=-1)
        left = mb.sub(x=mb.mul(x=even, y=cosine), y=mb.mul(x=odd, y=sine))
        right = mb.add(x=mb.mul(x=odd, y=cosine), y=mb.mul(x=even, y=sine))
        return mb.concat(values=[left, right], axis=-1)

    @staticmethod
    def head_shape(x, heads, batch, length):
        x = mb.reshape(x=x, shape=[batch, length, heads, HEAD_DIM])
        return mb.transpose(x=x, perm=[0, 2, 1, 3])

    def block(self, x, layer, sine, cosine, mask=None, past=None, nar=False):
        batch, length, _ = x.shape
        layer = f"model.layers.{layer}."
        a = layer + ("nar_self_attn." if nar else "self_attn.")
        mlp = layer + ("nar_mlp." if nar else "mlp.")
        z = self.rms(x, layer + ("nar_input_layernorm" if nar else "input_layernorm"))
        q = self.head_shape(self.linear(z, a+"q_proj"), 16, batch, length)
        k = self.head_shape(self.linear(z, a+"k_proj"), KV_HEADS, batch, length)
        v = self.head_shape(self.linear(z, a+"v_proj"), KV_HEADS, batch, length)
        q = self.rotate(self.rms(q, a+"q_norm"), sine, cosine)
        k = self.rotate(self.rms(k, a+"k_norm"), sine, cosine)
        current_k, current_v = k, v
        q = mb.reshape(x=q, shape=[batch, KV_HEADS, 2*length, HEAD_DIM])
        if past:
            k = mb.concat(values=[past[0],k], axis=2)
            v = mb.concat(values=[past[1],v], axis=2)
        args = dict(query=q, key=k, value=v)
        if mask is not None:
            args["attn_mask"] = mask
        y = mb.scaled_dot_product_attention(**args)
        y = mb.reshape(x=y, shape=[batch, 16, length, HEAD_DIM])
        y = mb.transpose(x=y, perm=[0, 2, 1, 3])
        y = mb.reshape(x=y, shape=[batch, length, HIDDEN])
        x = mb.add(x=x, y=self.linear(y, a+"o_proj"))
        z = self.rms(x, layer + ("nar_pre_mlp_layernorm" if nar else "post_attention_layernorm"))
        gate = mb.silu(x=self.linear(z, mlp+"gate_proj"))
        gated = mb.mul(x=gate, y=self.linear(z, mlp+"up_proj"))
        return mb.add(x=x, y=self.linear(gated, mlp+"down_proj")), current_k, current_v

    def head(self, hidden):
        return self.linear(self.rms(hidden, "model.norm"), "lm_head", slice(MUSIC_END, CODEC_END))


def past_layer(cache, layer, batch, length):
    return mb.slice_by_index(x=cache, begin=[layer,0,0,0,0], end=[layer+1,batch,KV_HEADS,length,HEAD_DIM],
                             squeeze_mask=[True,False,False,False,False])


def stateful_decode(model, capacity, batch=2):
    cache_shape = (LAYERS,batch,KV_HEADS,capacity,HEAD_DIM)

    @mb.program(input_specs=[spec(batch,1,HIDDEN), spec(batch,1,1,64), spec(batch,1,1,64), spec(batch,1,2,capacity+1),
                             mb.TensorSpec((batch,), dtype=types.int32),
                             mb.StateTensorSpec(cache_shape, dtype=types.fp16), mb.StateTensorSpec(cache_shape, dtype=types.fp16)],
                opset_version=ct.target.macOS15)
    def decode_graph(embedding, sine, cosine, mask, positions, keys, values):
        key_cache = mb.read_state(input=keys)
        value_cache = mb.read_state(input=values)
        current_keys, current_values = [], []
        x = embedding
        for layer in range(LAYERS):
            past = (past_layer(key_cache,layer,batch,capacity), past_layer(value_cache,layer,batch,capacity))
            x,k,v = model.block(x,layer,sine,cosine,mask=mask,past=past)
            current_keys.append(k)
            current_values.append(v)
        index = mb.reshape(x=positions,shape=[1,batch,1,1,1])
        index = mb.tile(x=index,reps=[LAYERS,1,KV_HEADS,1,HEAD_DIM])
        for state, cache, updates in ((keys,key_cache,current_keys),(values,value_cache,current_values)):
            updated = mb.scatter_along_axis(data=cache,indices=index,updates=mb.stack(values=updates,axis=0),
                                            axis=3,mode="update")
            mb.coreml_update_state(state=state, value=updated)
        return mb.identity(x=model.head(x),name="logits")
    return decode_graph


def growable_decode(model, capacity):
    names = ("embedding", "sine", "cosine", "mask", "keys", "values")
    frames = get_new_symbol()
    mask_frames = get_new_symbol()
    shape = (LAYERS, 2, KV_HEADS, frames, HEAD_DIM)
    shapes = ((2, 1, HIDDEN), (2, 1, 1, 64), (2, 1, 1, 64),
              (2, 1, 2, mask_frames), shape, shape)

    def cache_layer(cache, layer):
        return mb.slice_by_index(
            x=cache, begin=[layer, 0, 0, 0, 0], end=[layer + 1, 2, KV_HEADS, 0, HEAD_DIM],
            end_mask=[False, False, False, True, False],
            squeeze_mask=[True, False, False, False, False],
        )

    @mb.program(input_specs=[spec(*shape) for shape in shapes], opset_version=ct.target.macOS15)
    def graph(embedding, sine, cosine, mask, keys, values):
        x = embedding
        current_keys, current_values = [], []
        for i in range(LAYERS):
            past = (cache_layer(keys, i), cache_layer(values, i))
            x, k, v = model.block(x, i, sine, cosine, mask=mask, past=past)
            current_keys.append(k)
            current_values.append(v)
        return (
            mb.identity(x=model.head(x), name="logits"),
            mb.stack(values=current_keys, axis=0, name="current_keys"),
            mb.stack(values=current_values, axis=0, name="current_values"),
        )

    bounds = {
        frames: ct.RangeDim(1, capacity, default=128),
        mask_frames: ct.RangeDim(2, capacity + 1, default=129),
    }
    inputs = [
        ct.TensorType(name=name, shape=tuple(bounds.get(dim, dim) for dim in shape), dtype=types.fp16)
        for name, shape in zip(names, shapes)
    ]
    return graph, inputs


class MIL:
    @staticmethod
    def snake(x, alpha, beta):
        alpha = np.exp(alpha.astype(np.float32)).astype(np.float16).reshape(1, -1, 1, 1)
        inverse_beta = (1 / (np.exp(beta.astype(np.float32)) + 1e-9))
        inverse_beta = inverse_beta.astype(np.float16).reshape(1, -1, 1, 1)
        sine = mb.sin(x=mb.mul(x=x, y=alpha))
        return mb.add(x=x, y=mb.mul(x=mb.mul(x=sine, y=sine), y=inverse_beta))

    @staticmethod
    def conv(x, weight, bias, padding, dilation, transpose_stride):
        args = dict(x=x, weight=weight[:, :, np.newaxis, :], pad_type="custom",
                    pad=[0, 0, padding, padding])
        if bias is not None:
            args["bias"] = bias
        if transpose_stride is not None:
            return mb.conv_transpose(**args, strides=[1, transpose_stride])
        return mb.conv(**args, dilations=[1, dilation])

    @staticmethod
    def add(x, residual):
        return mb.add(x=x, y=residual)


