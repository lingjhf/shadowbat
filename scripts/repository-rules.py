#!/usr/bin/env python3
"""Verify GitHub rulesets; use --apply to create or update the tracked policies."""
import argparse
import json
import pathlib
import subprocess


def api(endpoint, method='GET', payload=None):
    command = ['gh', 'api', endpoint, '--method', method]
    if payload is not None:
        command += ['--input', '-']
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        raise SystemExit(result.stderr.strip() or result.stdout.strip())
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='lingjhf/shadowbat')
    parser.add_argument('--apply', action='store_true', help='Requires repository administrator access')
    args = parser.parse_args()
    endpoint = f'repos/{args.repo}/rulesets'
    existing = api(endpoint)
    root = pathlib.Path(__file__).resolve().parent.parent / '.github/rulesets'
    sources = sorted(root.glob('*.json'))
    if not sources:
        raise SystemExit(f'No ruleset definitions found in {root}')
    failed = False
    for source in sources:
        policy = json.loads(source.read_text())
        matches = [item for item in existing if item['name'] == policy['name']]
        if len(matches) > 1:
            raise SystemExit(f'Duplicate ruleset name: {policy["name"]}')
        current = api(f'{endpoint}/{matches[0]["id"]}') if matches else None
        if current is None or any(current.get(key) != value for key, value in policy.items()):
            if not args.apply:
                print(f'MISSING OR DIFFERENT: {policy["name"]}')
                failed = True
                continue
            current = api(f'{endpoint}/{current["id"]}', 'PUT', policy) if current else api(endpoint, 'POST', policy)
            current = api(f'{endpoint}/{current["id"]}')
        if any(current.get(key) != value for key, value in policy.items()):
            raise SystemExit(f'GitHub did not apply the requested policy: {policy["name"]}')
        print(f'PASS {policy["name"]}: {current["_links"]["html"]["href"]}')
    if failed:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
