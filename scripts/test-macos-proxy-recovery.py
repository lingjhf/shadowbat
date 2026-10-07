#!/usr/bin/env python3
"""Validate replacement recovery and XPC deadlines without touching the root helper."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAC = ROOT / 'macos'
with tempfile.TemporaryDirectory(prefix='shadowbat-proxy-recovery-') as temporary:
    sources = [MAC / 'Native/Models/ServerProfile.swift']
    sources += sorted((MAC / 'Shared').glob('*.swift'))
    sources += sorted((MAC / 'Native/Services').glob('*.swift'))
    sources += sorted((MAC / 'Native/ViewModels').glob('*.swift'))
    sources += [MAC / 'Tests/ProxyRecoveryChecks.swift']
    executable = pathlib.Path(temporary) / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                    '-default-isolation', 'MainActor', *map(str, sources), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=15)
