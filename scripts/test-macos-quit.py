#!/usr/bin/env python3
"""Exercise the actual AppDelegate's quit path with an isolated slow core."""
import pathlib
import subprocess
import tempfile

from importlib.util import module_from_spec, spec_from_file_location

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAC = ROOT / 'macos'
spec = spec_from_file_location('port_cleanup', ROOT / 'scripts/test-macos-port-cleanup.py')
fixture = module_from_spec(spec)
spec.loader.exec_module(fixture)


def main():
    with tempfile.TemporaryDirectory(prefix='shadowbat-quit-cleanup-') as temporary:
        directory = pathlib.Path(temporary)
        core = directory / 'fake-core'
        core.write_text(fixture.FAKE_CORE)
        core.chmod(0o700)
        delegate = directory / 'AppDelegate.swift'
        delegate.write_text((MAC / 'Runner/AppDelegate.swift').read_text()
                            .replace('import FlutterMacOS\n', '').replace('@main\n', ''))
        sources = [MAC / 'Native/Models/ServerProfile.swift']
        sources += sorted((MAC / 'Shared').glob('*.swift'))
        sources += [MAC / 'Native/Services' / name for name in
                    ['ProcessProxyEngine.swift', 'PrivilegedTunClient.swift']]
        harness = directory / 'checks'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                        '-default-isolation', 'MainActor', *map(str, sources), str(delegate),
                        str(MAC / 'Tests/QuitCleanupChecks.swift'), '-o', str(harness)], check=True)
        socks, http = fixture.free_port(), fixture.free_port()
        while socks == http:
            http = fixture.free_port()
        process = subprocess.Popen([str(harness), str(core), str(socks), str(http), str(directory)],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            output, _ = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            output, _ = process.communicate(timeout=5)
            raise RuntimeError('AppKit quit blocked cleanup: ' + output)
        assert process.returncode == 0 and 'SHUTDOWN_COMPLETE' in output, output
        for port in (socks, http):
            with fixture.socket.socket() as probe:
                probe.setsockopt(fixture.socket.SOL_SOCKET, fixture.socket.SO_REUSEADDR, 1)
                probe.bind(('127.0.0.1', port))
                probe.listen()
        print('PASS: actual AppDelegate quit completes asynchronous shutdown and releases both ports')


if __name__ == '__main__':
    main()
