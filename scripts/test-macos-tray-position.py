#!/usr/bin/env python3
"""Measure the native tray against its actual menu bar icon with isolated state."""
import pathlib
import plistlib
import argparse
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAC = ROOT / 'macos'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--interactive-focus', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='shadowbat-tray-position-') as temporary:
        sources = [MAC / 'Native/Models/ServerProfile.swift']
        sources += sorted((MAC / 'Shared').glob('*.swift'))
        sources += sorted((MAC / 'Native/Services').glob('*.swift'))
        sources += sorted((MAC / 'Native/ViewModels').glob('*.swift'))
        sources += [MAC / 'Native/Views/TrayPanelView.swift', MAC / 'Tests/TrayPositionChecks.swift']
        app = pathlib.Path(temporary) / 'TrayFixture.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.lingj.shadowbat.tray-fixture',
            'CFBundleExecutable': 'checks', 'CFBundleName': 'Shadowbat tray fixture',
            'CFBundlePackageType': 'APPL', 'NSPrincipalClass': 'NSApplication',
            'LSUIElement': True,
        }))
        harness = app / 'Contents/MacOS/checks'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                        '-default-isolation', 'MainActor', *map(str, sources), '-o', str(harness)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
        print('Fixture app: ' + str(app), flush=True)
        subprocess.run([str(harness), *(['--interactive-focus'] if args.interactive_focus else [])],
                       check=True, timeout=120 if args.interactive_focus else 15)


if __name__ == '__main__':
    main()
