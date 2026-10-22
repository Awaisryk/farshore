#!/usr/bin/env python3
"""Copy development preferences/cache; never move, delete, signal or unmount."""
import argparse
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile

BUDGET = 512 * 1024 * 1024


def private_directory(path):
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise ValueError("Destination must be a real directory owned by the current user.")
    path.chmod(0o700)


def safe_file(path, maximum):
    try:
        metadata = path.lstat()
        return stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid() and metadata.st_size <= maximum
    except OSError:
        return False


def migrate(source, state, cache):
    source = source.resolve(strict=True)
    metadata = source.stat()
    if not source.is_dir() or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise ValueError("Legacy state must be a private directory owned by the current user.")
    private_directory(state)
    private_directory(cache)
    preferences = source / "preferences.json"
    copied_preferences = False
    if safe_file(preferences, 1024 * 1024) and not (state / "preferences.json").exists():
        payload = preferences.read_bytes()
        if not isinstance(json.loads(payload), dict):
            raise ValueError("Legacy preferences are not a JSON object.")
        with (state / "preferences.json").open("xb") as output:
            output.write(payload)
        (state / "preferences.json").chmod(0o600)
        copied_preferences = True
    target = cache / "thumbnails"
    private_directory(target)
    used = sum(file.stat().st_size for file in target.glob("*.png") if safe_file(file, BUDGET))
    copied = 0
    for file in sorted((source / "thumbnails").glob("*.png")):
        if file.name.endswith(".part.png") or not safe_file(file, 16 * 1024 * 1024):
            continue
        destination = target / file.name
        if destination.exists() or used + file.stat().st_size > BUDGET:
            continue
        try:
            with file.open("rb") as original, destination.open("xb") as output:
                shutil.copyfileobj(original, output)
            metadata = file.stat()
            os.utime(destination, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
            destination.chmod(0o600)
            used += destination.stat().st_size
            copied += 1
        except FileExistsError:
            pass
    manifest = state / "legacy-states.json"
    roots = []
    if safe_file(manifest, 65_536):
        data = json.loads(manifest.read_text())
        if data.get("version") == 1:
            roots = data.get("roots", [])
    roots = list(dict.fromkeys([str(source)] + [path for path in roots if isinstance(path, str)]))[:8]
    with tempfile.NamedTemporaryFile(mode="w", dir=state, prefix="migration-", delete=False) as temporary:
        json.dump({"version": 1, "roots": roots}, temporary)
        pending = Path(temporary.name)
    pending.chmod(0o600)
    pending.replace(manifest)
    return {"preferencesCopied": copied_preferences, "thumbnailFilesCopied": copied,
            "legacyMountLocationsPreserved": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="source", type=Path, required=True)
    parser.add_argument("--state", type=Path, default=Path.home() / "Library/Application Support/Farshore")
    parser.add_argument("--cache", type=Path, default=Path.home() / "Library/Caches/Farshore")
    args = parser.parse_args()
    print(json.dumps(migrate(args.source, args.state, args.cache)))


if __name__ == "__main__":
    main()
