#!/usr/bin/env python3
"""Validate the Flutter version and optional release tag/main ancestry."""
import argparse
import pathlib
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--tag')
parser.add_argument('--require-main', action='store_true')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
match = re.search(r'^version:\s*(\S+)\s*$', (root / 'pubspec.yaml').read_text(), re.M)
if not match:
    raise SystemExit('pubspec.yaml has no version')
version = match.group(1)
if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?\+[1-9]\d*', version):
    raise SystemExit('Expected Flutter version MAJOR.MINOR.PATCH[‑prerelease]+BUILD')
if args.tag is not None and args.tag != 'v' + version:
    raise SystemExit(f'Tag must match pubspec.yaml exactly: v{version}')
if args.require_main:
    subprocess.run(['git', 'merge-base', '--is-ancestor', 'HEAD', 'origin/main'], cwd=root, check=True)
print(version)
