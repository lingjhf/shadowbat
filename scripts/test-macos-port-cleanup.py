#!/usr/bin/env python3
"""Stress cancelled shutdown on isolated ports with a deliberately slow core."""
import pathlib
import os
import select
import signal
import socket
import subprocess
import tempfile
import time
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAC = ROOT / 'macos'
FAKE_CORE = r'''#!/usr/bin/env python3
import json, select, signal, socket, sys, time
config = json.load(open(sys.argv[sys.argv.index('-c') + 1]))
listeners = []
for inbound in config['inbounds']:
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', inbound['listen_port']))
    listener.listen()
    listeners.append((listener, inbound['type']))
def shutdown(*_):
    time.sleep(.15)
    sys.exit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN if sys.argv[0].endswith('-stubborn') else shutdown)
while True:
    ready, _, _ = select.select([item[0] for item in listeners], [], [], 1)
    for listener, kind in listeners:
        if listener in ready:
            connection, _ = listener.accept()
            connection.settimeout(.5)
            try:
                if kind == 'socks':
                    connection.recv(3)
                    connection.sendall(bytes([5, 0]))
            finally:
                connection.close()
'''


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def check_signal_permission(directory, source):
    # Run the production shell body, simulating EPERM for the child signal probe.
    # This reproduces sudo ownership without requiring root or changing networking.
    script = textwrap.dedent(source.split('let script = """', 1)[1].split('"""', 1)[0])
    runtime = directory / 'permission-runtime'
    control = directory / 'permission-control'
    runtime.mkdir()
    control.mkdir()
    child = subprocess.Popen(['/bin/sleep', '30'])
    denial = f'kill() {{ if [ "$1" = -0 ] && [ "$2" = "{child.pid}" ]; then return 1; fi; command kill "$@"; }}\n'
    watcher = subprocess.Popen(['/bin/sh', '-c', denial + script, 'permission-fixture',
                                str(os.getpid()), str(child.pid), str(runtime), str(control)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(.5)
        assert watcher.poll() is None and runtime.is_dir() and control.is_dir(), \
            'A signal-permission denial deleted a live TUN control directory'
        print('PASS: signal-permission denial leaves live launcher and control directories intact')
    finally:
        if watcher.poll() is None:
            watcher.terminate()
        watcher.wait(timeout=5)
        child.terminate()
        child.wait(timeout=5)


def main():
    with tempfile.TemporaryDirectory(prefix='shadowbat-port-cleanup-') as temporary:
        directory = pathlib.Path(temporary)
        check_signal_permission(directory, (MAC / "Native/Services/ProcessProxyEngine.swift").read_text())
        core = directory / 'fake-core'
        core.write_text(FAKE_CORE)
        core.chmod(0o700)
        harness = directory / 'checks'
        sources = [MAC / 'Native/Models/ServerProfile.swift']
        sources += sorted((MAC / 'Shared').glob('*.swift'))
        sources += [MAC / 'Native/Services' / name for name in
                    ['ProcessProxyEngine.swift', 'PrivilegedTunClient.swift']]
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                        '-default-isolation', 'MainActor', *map(str, sources),
                        str(MAC / 'Tests/PortCleanupChecks.swift'), '-o', str(harness)], check=True)
        socks = free_port()
        http = free_port()
        while http == socks:
            http = free_port()
        arguments = [str(harness), str(core), str(socks), str(http), str(directory)]
        subprocess.run([*arguments, '--checks'], check=True, timeout=90)
        stubborn = directory / 'fake-core-stubborn'
        stubborn.write_text(FAKE_CORE)
        stubborn.chmod(0o700)
        host = subprocess.Popen([str(harness), str(stubborn), str(socks), str(http),
                                 str(directory), '--host'], stdout=subprocess.PIPE, text=True)
        core_pid = None
        try:
            if not select.select([host.stdout], [], [], 10)[0]:
                raise RuntimeError('Crash fixture did not become ready')
            line = host.stdout.readline().strip()
            if not line.startswith('READY: '):
                raise RuntimeError('Unexpected crash fixture output: ' + line)
            core_pid = int(line.split(': ')[1])
            host.kill()
            host.wait(timeout=5)
            # Reconnect immediately, without waiting for watchdog cleanup first.
            subprocess.run([*arguments, '--checks'], check=True, timeout=90)
            print('PASS: immediate restart after host crash and a core that ignores SIGTERM')
        finally:
            if host.poll() is None:
                host.kill()
                host.wait(timeout=5)
            if core_pid:
                command = subprocess.run(['/bin/ps', '-ww', '-p', str(core_pid), '-o', 'command='],
                                         capture_output=True, text=True).stdout
                if str(stubborn) in command and str(directory) + '/run-' in command:
                    try:
                        os.kill(core_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        with socket.socket() as occupied:
            occupied.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            occupied.bind(('127.0.0.1', socks))
            occupied.listen()
            subprocess.run([*arguments, '--occupied'], check=True, timeout=10)
            with socket.create_connection(('127.0.0.1', socks), timeout=1):
                pass
        authorizer = directory / 'fake-authorizer'
        authorizer.write_text('#!/usr/bin/env python3\nimport signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nwhile True: time.sleep(1)\n')
        authorizer.chmod(0o700)
        host = subprocess.Popen([str(harness), str(authorizer), str(socks), str(http),
                                 str(directory), '--pending-host'], stdout=subprocess.PIPE, text=True)
        launcher_pid = None
        try:
            if not select.select([host.stdout], [], [], 10)[0]:
                raise RuntimeError('Pending authorization fixture did not start')
            line = host.stdout.readline().strip()
            if not line.startswith('READY: '):
                raise RuntimeError('Unexpected pending fixture output: ' + line)
            launcher_pid = int(line.split(': ')[1])
            command = subprocess.check_output(['/bin/ps', '-ww', '-p', str(launcher_pid), '-o', 'command='], text=True)
            control = pathlib.Path(command.strip().split()[-1])
            assert control.name == 'control.sock' and control.parent.name.startswith('shadowbat-tun-'), command
            host.kill()
            host.wait(timeout=5)
            for _ in range(80):
                try:
                    os.kill(launcher_pid, 0)
                except ProcessLookupError:
                    if not control.parent.exists() and not list(directory.glob('run-*')):
                        break
                time.sleep(.1)
            else:
                raise RuntimeError('Pending authorization launcher or IPC survived its host crash')
            print('PASS: host crash during pending TUN authorization cleans launcher, IPC and credentials')
        finally:
            if host.poll() is None:
                host.kill()
                host.wait(timeout=5)
            if launcher_pid:
                command = subprocess.run(['/bin/ps', '-ww', '-p', str(launcher_pid), '-o', 'command='],
                                         capture_output=True, text=True).stdout
                if str(authorizer) in command:
                    try:
                        os.kill(launcher_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == '__main__':
    main()
