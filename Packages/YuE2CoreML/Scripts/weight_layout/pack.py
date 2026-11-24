"""Create and verify a benchmark-only Metal Q4 sidecar with four words per lane."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from time import monotonic

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from index_metal_weights import LAYERS, PROJECTION_SIZES, make_index


def pack(source, destination, offset, rows, columns, lane_groups, paired=False):
    # Each 512-weight tile has four consecutive SIMD iterations in the source.
    # Gather these in one aligned vector per lane without changing any nibble.
    elements = rows * columns
    original = np.memmap(source, mode="r", dtype="<u2", offset=offset, shape=(elements,))
    target = np.memmap(destination, mode="r+", dtype="<u2", offset=offset, shape=(elements,))
    target_view = target.reshape(rows, -1, lane_groups, 4)
    source_view = original.reshape(rows, -1, 4, lane_groups)
    if paired:
        # Pair successive iterations so one uchar4 decodes two signed dot4s.
        # Each byte stores the matching channel from an even and an odd word.
        byte_pairs = target_view.view(np.uint8).reshape(rows, -1, lane_groups, 2, 4)
        for start in range(0, rows, 256):
            batch = slice(start, start + 256)
            lanes = source_view[batch].swapaxes(2, 3)
            for channel in range(4):
                even = (lanes[..., ::2] >> (channel * 4)) & 15
                odd = (lanes[..., 1::2] >> (channel * 4)) & 15
                byte_pairs[batch, ..., channel] = even | (odd << 4)
    else:
        target_view[:] = source_view.swapaxes(2, 3)
    target.flush()
    if paired:
        for start in range(0, rows, 256):
            batch = slice(start, start + 256)
            even = np.zeros_like(source_view[batch].swapaxes(2, 3)[..., ::2])
            odd = np.zeros_like(even)
            for channel in range(4):
                byte = byte_pairs[batch, ..., channel].astype(np.uint16)
                even |= (byte & 15) << (4 * channel)
                odd |= (byte >> 4) << (4 * channel)
            expected = source_view[batch].swapaxes(2, 3)
            if not (np.array_equal(even, expected[..., ::2]) and np.array_equal(odd, expected[..., 1::2])):
                raise ValueError(f"Paired nibble round-trip failed at offset {offset}")
    elif not np.array_equal(target_view.swapaxes(2, 3), source_view):
        raise ValueError(f"Round-trip failed at offset {offset}")


def convert(assets, output, paired=False):
    if output.exists():
        raise FileExistsError(f"Use a new destination: {output}")
    index = make_index(assets)
    if json.loads((assets / "metal-decoder.json").read_text()) != index:
        raise ValueError("Metal index differs from the compiled model")
    source = assets / "Autoregressive.mlmodelc/weights/weight.bin"
    start = monotonic()
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as f:
        temporary = Path(f.name)
    try:
        shutil.copyfile(source, temporary)
        shapes = PROJECTION_SIZES * LAYERS + [(32769, 2048)]
        for projection, (rows, width) in zip(index["projections"], shapes):
            pack(source, temporary, projection["packed"], rows, width // 4, 32, paired=paired)
            pack(source, temporary, projection["scale"], rows, width // 32, 4)
        # Link without overwriting a concurrently created destination.
        os.link(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Verified {len(shapes)} Q4 matrices and FP16 scale tables. "
          f"{source.stat().st_size} bytes in {monotonic() - start:.2f} seconds.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("assets", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--paired", action="store_true", help="Interleave nibbles from adjacent dot products")
    args = parser.parse_args()
    convert(args.assets, args.output, args.paired)
