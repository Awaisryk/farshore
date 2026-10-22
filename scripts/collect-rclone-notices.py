#!/usr/bin/env python3
"""Reproduce the pinned rclone notice/source kit for a Farshore release.

Usage: python3 scripts/collect-rclone-notices.py --collect --prepare --validate --package
Validation needs Apple Silicon macOS and Apple's Command Line Tools.
"""
import argparse
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
for action in ['collect', 'prepare', 'validate', 'package']:
    parser.add_argument('--' + action, action='store_true')
options = parser.parse_args()
if not any(vars(options).values()):
    parser.error('Choose at least one action; see --help.')
folder = root / 'licenses/rclone-third-party'
if options.collect:
    subprocess.run([sys.executable, str(folder / 'collect.py')], cwd=root, check=True)
if options.prepare:
    subprocess.run([sys.executable, str(folder / 'prepare_source.py')], cwd=root, check=True)
if options.validate:
    subprocess.run([sys.executable, str(folder / 'validate_source.py')], cwd=root, check=True)
if options.package:
    subprocess.run([sys.executable, str(folder / 'prepare_source.py'), '--package'], cwd=root, check=True)
