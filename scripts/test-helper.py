#!/usr/bin/env python3
"""Exercise the helper transaction logic in a temporary directory, without root or system writes."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent / 'macos'
sources = sorted((ROOT / 'Shared').glob('*.swift'))
sources += [ROOT / 'ProxyHelper' / name for name in
            ('RootSnapshotStore.swift', 'ProxyPreferences.swift', 'ProxyHelperBackend.swift')]
with tempfile.TemporaryDirectory(prefix='shadowbat-helper-tests-') as temporary:
    executable = pathlib.Path(temporary) / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                    *map(str, sources), str(ROOT / 'Tests/ProxyHelperChecks.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
