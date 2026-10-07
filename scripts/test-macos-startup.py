#!/usr/bin/env python3
"""Run the packaged release app with isolated profiles and no system changes."""
import argparse
import pathlib
import plistlib
import shutil
import subprocess
import tempfile


def run_check(executable, arguments, marker):
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen([str(executable), '--startup-check', *arguments], stdout=output,
                                   stderr=subprocess.STDOUT)
        try:
            try:
                code = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                output.seek(0)
                log = output.read().decode('utf-8', errors='replace')
                raise SystemExit(f'Release startup check timed out:\n{log[-6000:]}')
            output.seek(0)
            log = output.read().decode('utf-8', errors='replace')
            if code != 0 or marker not in log:
                raise SystemExit(f'Release startup failed (exit {code}):\n{log[-6000:]}')
        finally:
            # The native check uses only its PID-specific temporary store.
            shutil.rmtree(pathlib.Path(tempfile.gettempdir()) /
                          f'shadowbat-preview-{process.pid}', ignore_errors=True)
    return log


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=pathlib.Path)
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    # Use a dedicated test status item name, keeping the user's real item untouched.
    run_check(executable, ['--seed-hidden-status-item'], 'SHADOWBAT_STATUS_ITEM_HIDDEN')
    log = run_check(executable, [], 'SHADOWBAT_STARTUP_OK')
    if 'SHADOWBAT_STATUS_ITEM_RESTORED_HIDDEN' not in log:
        raise SystemExit('Status item check did not reproduce saved hidden visibility')
    if 'SHADOWBAT_LOG_BURST_OK' not in log:
        raise SystemExit('Native log burst was not coalesced')
    tray_log = run_check(executable, ['--tray-position-check'], 'SHADOWBAT_TRAY_POSITION_OK')
    if 'SHADOWBAT_TRAY_FOCUS_READY' not in tray_log:
        raise SystemExit('Native tray did not configure its initial keyboard responder')
    if 'SHADOWBAT_TRAY_ARROWLESS_OK' not in tray_log:
        raise SystemExit('Native tray still has window chrome or a popover arrow')
    print('Passed: native tray uses an arrowless borderless panel')
    print('Passed: hidden menu bar item restored with a valid icon after relaunch')
    print('Passed: 500 native log updates coalesced into at most three snapshots')
    print('Passed: packaged native tray opens directly below its status item')
    print('Passed: packaged native tray configures its initial keyboard responder')
    print(f'Passed: packaged Flutter/native startup, version '
          f'{info["CFBundleShortVersionString"]}+{info["CFBundleVersion"]}')


if __name__ == '__main__':
    main()
