"""Prepare the optional paired Q4 Metal layout for one indexed version 3 asset bundle."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile

from weight_layout.pack import convert


def digest(path):
    with path.open("rb") as source:
        result = hashlib.sha256()
        for chunk in iter(lambda: source.read(4 << 20), b""):
            result.update(chunk)
        return result.hexdigest()


def prepare(assets):
    destination = assets / "MetalPaired"
    source = assets / "Autoregressive.mlmodelc/weights/weight.bin"
    index = assets / "metal-decoder.json"
    expected = {"version": 1, "sourceSHA256": digest(source), "indexSHA256": digest(index)}

    def verify_existing():
        manifest = json.loads((destination / "manifest.json").read_text())
        if manifest != {**expected, "packedSHA256": digest(destination / "weights.bin")}:
            raise ValueError("Existing MetalPaired belongs to different assets or is damaged.")

    if destination.exists():
        verify_existing()
        return
    with tempfile.TemporaryDirectory(dir=assets) as temporary:
        pending = Path(temporary) / "MetalPaired"
        pending.mkdir()
        packed = pending / "weights.bin"
        convert(assets, packed, paired=True)
        (pending / "manifest.json").write_text(json.dumps({**expected, "packedSHA256": digest(packed)}) + "\n")
        try:
            pending.rename(destination)
        except OSError:
            if not destination.exists():
                raise
            verify_existing()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("assets", type=Path)
    prepare(parser.parse_args().assets)
