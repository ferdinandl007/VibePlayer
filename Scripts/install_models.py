#!/usr/bin/env python3
"""Install the pinned infetit radio models on an Apple silicon Mac or a paired iPhone/iPad."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent
SUPPORT = Path.home() / "Library/Application Support"
CACHE = Path.home() / "Library/Caches/com.vibeplayer.model-installer"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url, path, expected):
    if path.is_file() and sha256(path) == expected:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(path.name + ".part")
    print(f"Downloading {path.name}", flush=True)
    command = ["curl", "--fail", "--location", "--retry", "3", "--connect-timeout", "20",
               "--silent", "--show-error", "--output", str(partial)]
    resume = partial.is_file()
    status = subprocess.run(command + (["--continue-at", "-"] if resume else []) + [url]).returncode
    if resume and status in (22, 33):
        partial.unlink(missing_ok=True)
        subprocess.run(command + [url], check=True)
    elif status:
        raise RuntimeError(f"Download failed for {path.name}. Run the command again to resume it.")
    if sha256(partial) != expected:
        partial.unlink()
        raise RuntimeError(f"Could not verify {path.name}. Run the command again to retry.")
    partial.replace(path)


def download_repo(repo, revision, files, location, prefix=""):
    origin = f"https://huggingface.co/{repo}/resolve/{revision}/"
    with ThreadPoolExecutor(max_workers=4) as pool:
        transfers = [pool.submit(download, origin + quote(prefix + name), location / name, expected)
                     for name, expected in files.items()]
        for transfer in transfers:
            transfer.result()


def install_directory(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".vibe-install-", dir=destination.parent) as temp:
        staging = Path(temp) / destination.name
        # Clone files on APFS when possible and fall back to a regular copy.
        subprocess.run(["cp", "-cR", str(source), str(staging)], check=True)
        backup = None
        if destination.exists():
            backup_dir = Path(tempfile.mkdtemp(prefix="previous-", dir=destination.parent))
            backup = backup_dir / destination.name
            destination.rename(backup)
        try:
            staging.rename(destination)
        except OSError:
            if backup is not None:
                backup.rename(destination)
            raise
        if backup is not None:
            print(f"Previous copy saved at {backup}")


def coreml_models(lock, target, destination, source):
    files = lock["coreml"][target]
    if all((destination / name).is_file() and sha256(destination / name) == expected
           for name, expected in files.items()):
        return
    if source is None:
        release = lock.get("release")
        if release is None:
            raise RuntimeError("A hosted Core ML release is pending. Supply an exported bundle with --coreml-source.")
        source = CACHE / release["revision"] / target / "YuE2MetalAssets"
        download_repo(release["repo"], release["revision"], files, source, f"{target}/YuE2MetalAssets/")
    else:
        for name, expected in files.items():
            if not (source / name).is_file() or sha256(source / name) != expected:
                raise RuntimeError(f"The local Core ML bundle does not match the release at {name}.")
    if source.resolve() != destination.resolve():
        install_directory(source, destination)


def provision(device, bundle_id, root):
    for directory in ["YuE2MetalAssets", "YuE2NativeAssets", "VibePlayer/Songwriting"]:
        print(f"Copying {directory} to {device}", flush=True)
        subprocess.run(
            ["xcrun", "devicectl", "device", "copy", "to", "--device", device,
             "--domain-type", "appDataContainer", "--domain-identifier", bundle_id,
             "--source", str(root / directory), "--destination", f"Library/Application Support/{directory}",
             "--timeout", "3600"], check=True
        )


def build_mac():
    derived = CACHE / "Build"
    subprocess.run(
        ["xcodebuild", "-project", str(ROOT / "VibePlayer.xcodeproj"), "-scheme", "VibePlayer",
         "-configuration", "Release", "-destination", "platform=macOS,arch=arm64",
         "-derivedDataPath", str(derived), "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGN_IDENTITY=-", "build"],
        check=True
    )
    app = derived / "Build/Products/Release/infetit radio.app"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    install_directory(app, Path.home() / "Applications/infetit radio.app")


def install(lock, args):
    target = "ios" if args.device else "macos"
    root = CACHE / "ios" if args.device else SUPPORT
    coreml_models(lock, target, root / "YuE2MetalAssets", args.coreml_source)

    native = root / "YuE2NativeAssets"
    download(lock["spec"]["url"], native / "yue2.json", lock["spec"]["sha256"])
    sources = lock["sources"]
    writer = root / "VibePlayer/Songwriting" / sources["songwriting"]["revision"]
    groups = {"native": native / "weights", "songwriting": writer}
    if args.all:
        groups.update(precision=native / "weights", reference=native / "Reference")
    for name, location in groups.items():
        source = sources[name]
        download_repo(source["repo"], source["revision"], source["files"], location)

    if args.device:
        provision(args.device, args.bundle_id, root)
    elif args.build_app:
        build_mac()
    print("infetit radio models are installed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    options = parser.add_mutually_exclusive_group()
    options.add_argument("--device", help="Provision an iPhone or iPad where infetit radio has already been run from Xcode.")
    options.add_argument("--build-app", action="store_true", help="Also build and install the Mac app in ~/Applications.")
    parser.add_argument("--all", action="store_true", help="Include full-precision and reference audio weights on Mac.")
    parser.add_argument("--bundle-id", default="com.vibeplayer.app", help="Bundle ID used to sign the iPhone or iPad build.")
    parser.add_argument("--coreml-source", type=Path, help="Use a local copy of the matching published Core ML bundle.")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Run this command on an Apple silicon Mac.")
    if args.device and args.all:
        parser.error("--all is for the Mac models.")
    if args.device or args.build_app:
        subprocess.run(["xcodebuild", "-version"], check=True)

    lock = json.loads((ROOT / "Scripts/model-assets.json").read_text())
    CACHE.mkdir(parents=True, exist_ok=True)
    with (CACHE / "install.lock").open("a") as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        install(lock, args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"infetit radio setup: {error}")
