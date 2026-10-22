#!/usr/bin/env python3
"""Bounded, read-only SFTP range check. Never mounts or launches automatically."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backend.farshore_bridge import Bridge, BridgeError, remote_path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("alias")
parser.add_argument("path", help="Existing remote file, absolute or home relative")
parser.add_argument("--output", help="Optional local metrics JSON destination (filenames omitted)")
args = parser.parse_args()
bridge = Bridge()
hosts = bridge.discover()["hosts"]
host = next((h for h in hosts if h["alias"] == args.alias), None)
if not host:
    parser.error("The alias is not present in the existing SSH configuration.")
path = remote_path(args.path)
try:
    bridge.preflight(host)
    initial = bridge.stat(host, path)
    size = initial["Size"]
    if initial["IsDir"] or size <= 0:
        parser.error("Select a nonempty regular file.")
    count = min(65536, size)
    offsets = sorted(set([0, max(0, size // 2 - count // 2), max(0, size - count)]))
    results = []
    for offset in offsets:
        start = time.perf_counter()
        read = bridge.run([bridge.rclone, "cat", ":sftp:" + path, "--offset", str(offset), "--count", str(count),
                           "--sftp-chunk-size", "32Ki", "--sftp-concurrency", "2"] + bridge.engine_args(host))
        if read.returncode or len(read.stdout) != min(count, size - offset):
            raise BridgeError("range_failed", "The engine did not return the requested byte count.")
        results.append({"offset": offset, "requestedBytes": count, "returnedBytes": len(read.stdout),
                        "seconds": round(time.perf_counter() - start, 4), "sha256": hashlib.sha256(read.stdout).hexdigest()})
    final = bridge.stat(host, path)
    if (initial["Size"], initial.get("ModTime")) != (final["Size"], final.get("ModTime")):
        raise BridgeError("source_changed", "The source changed during the test; results discarded.")
    report = {"schemaVersion": 1, "engine": "rclone 1.75.2 via external OpenSSH", "sourceBytes": size,
              "samples": results, "returnedBytesTotal": sum(r["returnedBytes"] for r in results),
              "limitations": ["Returned payload bytes are not encrypted wire-byte measurements.",
                               "Range checks do not validate mounted playback, decoding, or seeking in a player.",
                               "Size and timestamp cannot detect every same-size remote replacement."]}
    encoded = json.dumps(report, indent=2)
    if args.output:
        Path(args.output).write_text(encoded + "\n")
    print(encoded)
except BridgeError as error:
    print(json.dumps({"ok": False, "code": error.code, "message": error.message}), file=sys.stderr)
    sys.exit(1)
