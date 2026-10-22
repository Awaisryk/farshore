#!/usr/bin/env python3
"""Prove that the offline kit builds and accepts a changed LGPL library."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tarfile
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
STAGE = ROOT / '.build/rclone-corresponding-source'
spec = importlib.util.spec_from_file_location('rclone_notices', HERE / 'collect.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


def validate(modified_only=False):
    toolchain = collector.fetch('https://go.dev/dl/go1.26.9.darwin-arm64.tar.gz', 'go1.26.9.darwin-arm64.tar.gz')
    if collector.sha(toolchain.read_bytes()) != 'f9bb7c0a02506c5d9bf0d1eb1f7ee6c7684f844ae49558308a0427b830e022cc':
        raise ValueError('Unexpected Go toolchain checksum')
    destination = ROOT / '.tools/rclone-relink-go'
    binary = destination / 'go/bin/go'
    if not binary.exists():
        destination.mkdir(parents=True, exist_ok=True)
        with tarfile.open(toolchain) as archive:
            for item in archive.getmembers():
                if not (destination / item.name).resolve().is_relative_to(destination):
                    raise ValueError('Unexpected toolchain path')
            archive.extractall(destination)
    environment = {**os.environ, 'GO_BINARY': str(binary), 'BUILD_PARALLELISM': '2'}
    command = ['sh', str(STAGE / 'build-rclone.sh')]
    if not modified_only:
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=900)
        if result.returncode:
            raise RuntimeError(result.stderr[-6000:])
    baseline = STAGE / 'output/rclone'
    result = subprocess.run([str(baseline), 'version'], capture_output=True, text=True, check=True, timeout=20)
    if 'rclone v1.75.2' not in result.stdout or 'go1.26.9' not in result.stdout:
        raise ValueError('Unexpected baseline build')
    baseline_sha = collector.sha(baseline.read_bytes())
    source = STAGE / 'module-proxy/github.com/cloudsoda/sddl/@v/v0.0.0-20250224235906-926454e91efc.zip'
    editable = STAGE / '.work/modified-sddl'
    editable.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source) as archive:
        prefix = 'github.com/cloudsoda/sddl@v0.0.0-20250224235906-926454e91efc/'
        for item in archive.infolist():
            relative = item.filename.removeprefix(prefix)
            if not relative or item.is_dir():
                continue
            target = editable / relative
            if not target.resolve().is_relative_to(editable):
                raise ValueError('Unexpected library source path')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(item))
    (editable / 'farshore_relink_verification.go').write_text('''package sddl

import "os"

func init() {
    if os.Getenv("FARSHORE_RELINK_VERIFY") == "1" {
        os.Stderr.WriteString("farshore-lgpl-relinked\\n")
    }
}
''')
    changed = subprocess.run(command, env={**environment, 'SDDL_SOURCE': str(editable)}, capture_output=True, text=True, timeout=900)
    if changed.returncode:
        raise RuntimeError(changed.stderr[-6000:])
    verified = subprocess.run([str(baseline), 'version'], env={**environment, 'FARSHORE_RELINK_VERIFY': '1'}, capture_output=True, text=True, check=True, timeout=20)
    if 'farshore-lgpl-relinked' not in verified.stderr:
        raise ValueError('The rebuilt binary did not use the changed LGPL library')
    result = {'baselinePassed': True, 'modifiedLibraryPassed': True,
              'baselineSha256': baseline_sha, 'modifiedLibrarySha256': collector.sha(baseline.read_bytes()),
              'goVersion': 'go1.26.9', 'offlineModuleProxy': True, 'parallelism': 2}
    (STAGE / '.validation.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2), flush=True)


if __name__ == '__main__':
    import sys
    validate('--modified-only' in sys.argv)
