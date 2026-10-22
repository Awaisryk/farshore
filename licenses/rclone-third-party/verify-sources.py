#!/usr/bin/env python3
"""Verify the original inputs before building. User edits belong under .work/."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent
manifest = json.loads((root / 'source-manifest.json').read_text())
for item in manifest['files']:
    path = root / item['path']
    if not path.resolve().is_relative_to(root):
        raise SystemExit('Unexpected manifest path')
    if path.stat().st_size != item['bytes'] or hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
        raise SystemExit('Source verification failed: ' + item['path'])
print('Verified', len(manifest['files']), 'original source files and archives.')
