"""YuE2 Oobleck waveform decoder graph with pre-folded GGUF weights."""

def build_decoder(ops, latents, weights, config):
    def snake(x, layer):
        return ops.snake(x, weights[f"{layer}.alpha"], weights[f"{layer}.beta"])

    def conv(x, layer, padding, dilation=1, transpose_stride=None):
        return ops.conv(x, weights[f"{layer}.weight"], weights.get(f"{layer}.bias"),
                        padding, dilation, transpose_stride)

    layers = "decoder.layers"
    x = conv(latents, f"{layers}.0", 3)
    strides = config["decoder_config"]["strides"]
    for stage, stride in enumerate(reversed(strides), start=1):
        block = f"{layers}.{stage}.layers"
        x = snake(x, f"{block}.0")
        x = conv(x, f"{block}.1", (stride + 1) // 2, transpose_stride=stride)
        for index, dilation in enumerate((1, 3, 9), start=2):
            unit = f"{block}.{index}.layers"
            residual = snake(x, f"{unit}.0")
            residual = conv(residual, f"{unit}.1", 3 * dilation, dilation)
            residual = snake(residual, f"{unit}.2")
            residual = conv(residual, f"{unit}.3", 0)
            x = ops.add(x, residual)
    x = snake(x, f"{layers}.{len(strides) + 1}")
    return conv(x, f"{layers}.{len(strides) + 2}", 3)

