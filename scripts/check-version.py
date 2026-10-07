#!/usr/bin/env python3
"""Validate the Flutter version and optional release tag/main ancestry."""
import argparse
import pathlib
import re
import subprocess

def validate_version(pubspec, tag=None, changelog=None):
    matches = re.findall(r'^version:\s*(\S+)\s*$', pubspec, re.M)
    if len(matches) != 1:
        raise ValueError('pubspec.yaml must contain exactly one version')
    version = matches[0]
    number = r'(?:0|[1-9][0-9]*)'
    identifier = r'(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)'
    pattern = rf'{number}\.{number}\.{number}(?:-{identifier}(?:\.{identifier})*)?\+[1-9][0-9]*'
    if not re.fullmatch(pattern, version):
        raise ValueError('Expected Flutter version MAJOR.MINOR.PATCH[-prerelease]+BUILD')
    if tag is not None and tag != 'v' + version:
        raise ValueError(f'Tag must match pubspec.yaml exactly: v{version}')
    if changelog is not None and not re.search(rf'^## {re.escape(version)}\s*$', changelog, re.M):
        raise ValueError(f'CHANGELOG.md must contain a release heading: ## {version}')
    return version


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag')
    parser.add_argument('--require-main', action='store_true')
    parser.add_argument('--check-changelog', action='store_true')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    try:
        version = validate_version(
            (root / 'pubspec.yaml').read_text(),
            args.tag,
            (root / 'CHANGELOG.md').read_text() if args.check_changelog else None,
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error
    if args.require_main:
        subprocess.run(['git', 'merge-base', '--is-ancestor', 'HEAD', 'origin/main'], cwd=root, check=True)
    print(version)


if __name__ == '__main__':
    main()
