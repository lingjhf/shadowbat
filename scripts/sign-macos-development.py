#!/usr/bin/env python3
"""Sign a local app and its embedded code with an existing Apple Development identity."""
import argparse
import pathlib
import plistlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def signing_info(path):
    output = subprocess.run(['codesign', '-dvv', str(path)], check=True,
                            capture_output=True, text=True).stderr
    values = {}
    for line in output.splitlines():
        key, separator, value = line.partition('=')
        if separator:
            values[key] = value
    return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--identity', required=True, help='Existing certificate name or SHA-1 identity')
    parser.add_argument('--source', type=pathlib.Path,
                        default=ROOT / 'build/macos-ci/Build/Products/Release/shadowbat.app')
    parser.add_argument('--output', type=pathlib.Path,
                        default=ROOT / 'build/macos-development/shadowbat.app')
    args = parser.parse_args()
    app = args.output.resolve()
    if app.exists():
        raise SystemExit(f'Output already exists: {app}')
    app.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ditto', str(args.source.resolve()), str(app)], check=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    main_binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
    frameworks = sorted((app / 'Contents/Frameworks').glob('**/*.framework'),
                        key=lambda item: len(item.parts), reverse=True)
    # Sign inside out; the final app signature seals the helper, core and frameworks.
    embedded = [path for path in (app / 'Contents/MacOS').iterdir()
                if path.is_file() and path != main_binary]
    for path in [*frameworks, *embedded, app]:
        subprocess.run(['codesign', '--force', '--sign', args.identity,
                        '--options', 'runtime', '--timestamp=none',
                        '--entitlements', str(ROOT / 'macos/Runner/Release.entitlements'),
                        str(path)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    team = signing_info(app).get('TeamIdentifier')
    if not team or team == 'not set':
        raise SystemExit('Signing identity has no Apple Team ID')
    for path in [*frameworks, *embedded]:
        if signing_info(path).get('TeamIdentifier') != team:
            raise SystemExit(f'Embedded code has a different Team ID: {path}')
    print(f'Validated development app and embedded code: TeamIdentifier={team}')
    print(app)


if __name__ == '__main__':
    main()
