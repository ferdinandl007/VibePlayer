"""Index the compiled GrowableDecoder constants for the optional Metal decoder."""
import argparse
import json
from pathlib import Path
import re
import struct

LAYERS = 28
PROJECTION_SIZES = [(2048, 2048), (1024, 2048), (1024, 2048),
                    (2048, 2048), (6144, 2048), (6144, 2048), (2048, 6144)]


def make_index(assets):
    graph = assets / "Autoregressive.mlmodelc"
    text = (graph / "model.mil").read_text()
    match = re.search(r"(?m)^    func GrowableDecoder\b.*?(?=^    func |\Z)", text, re.S | re.M)
    if not match:
        raise ValueError("Expected a compiled version 3 GrowableDecoder function")
    decode = match[0]
    matrices = []
    norms = []
    offset_pattern = r"offset = uint64\((\d+)\)"
    for line in decode.splitlines():
        if " = constexpr_blockwise_shift_scale(" in line:
            size = re.search(r"data = tensor<int4, \[(\d+), (\d+)\]>", line)
            if size is None:
                raise ValueError("Expected an int4 projection")
            matrices.append((tuple(map(int, size.groups())), list(map(int, re.findall(offset_pattern, line)))))
        elif re.search(r"mul_\d+_y_0 = const\(", line) and "BLOBFILE(" in line:
            size = re.search(r"tensor<fp16, \[(\d+)\]>", line)
            if size is not None:
                norms.append((int(size[1]), int(re.search(offset_pattern, line)[1])))

    shapes = PROJECTION_SIZES * LAYERS + [(32769, 2048)]
    norm_shapes = [2048, 128, 128, 2048] * LAYERS + [2048]
    if [s for s, _ in matrices] != shapes or [s for s, _ in norms] != norm_shapes:
        raise ValueError("The compiler emitted an unknown decoder layout")

    weights = graph / "weights/weight.bin"
    length = weights.stat().st_size
    with weights.open("rb") as source:
        if struct.unpack("<II", source.read(8))[1] != 2:
            raise ValueError("The compiler emitted an unknown weight format")

        def payload(record, kind, size):
            source.seek(record)
            magic, actual_kind, count, begin = struct.unpack("<IIQQ", source.read(24))
            if (magic, actual_kind, count) != (0xDEADBEEF, kind, size):
                raise ValueError(f"Invalid weight record at {record}")
            if begin % 4 or begin < record + 24 or begin + size > length:
                raise ValueError(f"Invalid weight payload at {begin}")
            return begin

        projections = []
        for (rows, width), (weight, scale) in matrices:
            projections.append(dict(packed=payload(weight, 8, rows * width // 2),
                                    scale=payload(scale, 1, rows * width // 16)))
        scalar = [payload(record, 1, size * 2) for size, record in norms]
    return dict(version=1, weightsBytes=length, projections=projections, norms=scalar)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("assets", type=Path)
    assets = parser.parse_args().assets
    index = make_index(assets)
    temporary = assets / "metal-decoder.part"
    temporary.write_text(json.dumps(index, indent=2) + "\n")
    temporary.replace(assets / "metal-decoder.json")
