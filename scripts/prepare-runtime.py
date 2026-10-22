#!/usr/bin/env python3
"""Stage verified portable dependencies, without touching any live bundle/state."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / "scripts/runtime-lock.json").read_text())


def archive(url, digest):
    name = urllib.parse.unquote(urllib.parse.urlparse(url).path.rsplit("/", 1)[-1])
    path = ROOT / ".tools" / name
    path.parent.mkdir(exist_ok=True)
    if not path.exists():
        pending = path.with_name(path.name + ".download")
        subprocess.run(["/usr/bin/curl", "--fail", "--silent", "--show-error", "--location",
                        "--proto", "=https", "--tlsv1.2", "--retry", "2", url, "-o", str(pending)], check=True)
        pending.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit("Pinned dependency SHA-256 mismatch; refusing to extract " + name)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.exists():
        raise SystemExit("Runtime staging destination must not exist.")
    python = LOCK["python"]
    install = archive(python["url"], python["sha256"])
    provenance = archive(python["provenanceUrl"], python["provenanceSha256"])
    rclone = archive(LOCK["rclone"]["url"], LOCK["rclone"]["sha256"])
    destination.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="runtime-extract-", dir=ROOT / ".build") as temporary:
        extraction = Path(temporary)
        with tarfile.open(install) as source:
            for member in source.getmembers():
                target = (extraction / member.name).resolve()
                if not target.is_relative_to(extraction) or member.isdev() or member.isfifo():
                    raise SystemExit("Unsafe path in verified Python archive.")
                if member.issym() or member.islnk():
                    link = (target.parent / member.linkname).resolve() if member.issym() else (extraction / member.linkname).resolve()
                    if not link.is_relative_to(extraction):
                        raise SystemExit("Unsafe link in verified Python archive.")
            source.extractall(extraction)
        shutil.move(str(extraction / "python"), destination / "python")
        subprocess.run(["/usr/bin/tar", "-xf", str(provenance), "-C", str(extraction),
                        "python/PYTHON.json", "python/licenses"], check=True)
        shutil.copytree(extraction / "python/licenses", destination / "licenses/python")
        shutil.copy2(extraction / "python/PYTHON.json", destination / "licenses/python/PYTHON.json")
    # This application has no third-party Python dependencies or package manager.
    stdlib = destination / "python/lib/python3.13"
    for folder in [stdlib / "site-packages", stdlib / "ensurepip", stdlib / "idlelib"]:
        if folder.exists():
            shutil.rmtree(folder)
    (stdlib / "site-packages").mkdir()
    for file in (destination / "python/bin").glob("pip*"):
        file.unlink()
    binaries = destination / "bin"
    binaries.mkdir()
    with zipfile.ZipFile(rclone) as source:
        binary = source.read("rclone-v1.75.2-osx-arm64/rclone")
        (binaries / "rclone").write_bytes(binary)
    (binaries / "rclone").chmod(0o755)
    native = ROOT / ".build/farshore-native"
    if not native.is_file():
        raise SystemExit("Build the native helper first: scripts/build-native.sh --check")
    shutil.copy2(native, binaries / "farshore-native")
    (destination / "backend").mkdir()
    shutil.copy2(ROOT / "backend/farshore_bridge.py", destination / "backend/farshore_bridge.py")
    shutil.copy2(ROOT / "scripts/runtime-lock.json", destination / "runtime-lock.json")
    shutil.copy2(ROOT / "licenses/rclone-MIT.txt", destination / "licenses/rclone-MIT.txt")
    if (ROOT / "licenses/rclone-third-party").is_dir():
        shutil.copytree(ROOT / "licenses/rclone-third-party", destination / "licenses/rclone-third-party")
    flutter = ROOT / ".tools/flutter"
    shutil.copy2(flutter / "LICENSE", destination / "licenses/Flutter-BSD.txt")
    engine_notice = flutter / "bin/cache/pkg/sky_engine/LICENSE"
    if engine_notice.exists():
        shutil.copy2(engine_notice, destination / "licenses/Flutter-engine-NOTICES.txt")
    else:
        raise SystemExit("Flutter engine third-party LICENSE is missing; refusing an incomplete bundle.")
    shutil.copy2(flutter / "bin/cache/dart-sdk/LICENSE", destination / "licenses/Dart-LICENSE.txt")
    shutil.copy2(flutter / "bin/cache/artifacts/material_fonts/MaterialIcons_LICENSE.txt", destination / "licenses/MaterialIcons-LICENSE.txt")
    shutil.copy2(ROOT / "docs/dependencies.md", destination / "licenses/DEPENDENCIES.md")
    subprocess.run([str(destination / "python/bin/python3"), "-I", "-B", "-c",
                    "import ssl, json, subprocess, concurrent.futures, http.server, hashlib; print('Portable Python runtime verified.')"], check=True)
    print("Staged verified portable runtime at " + str(destination))


if __name__ == "__main__":
    main()
