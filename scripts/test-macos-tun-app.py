#!/usr/bin/env python3
"""Exercise the real application TUN engine/helper with scoped routes and native authorization.

Run as the desktop user after building the app. macOS may display an administrator prompt.
Tests never load personal settings, credentials or enable the real system proxy.
"""
import http.server
import argparse
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
MAC = ROOT / 'macos'
APP = ROOT / 'build/macos-ci/Build/Products/Release/shadowbat.app/Contents/MacOS'
WORK = ROOT / 'build/macos-tun-app'


def output(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class HTTPFixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.server.marker
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class UDPFixture(socketserver.BaseRequestHandler):
    def handle(self):
        _, sock = self.request
        sock.sendto(self.server.marker, self.client_address)


def cleanup_state(before):
    for _ in range(100):
        if subprocess.run(['/sbin/ifconfig', 'utun64'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            break
        time.sleep(.1)
    else:
        raise RuntimeError('utun64 remained after native app shutdown')
    for target in ('198.18.0.123', '198.18.0.124', '2001:db8::123', '2001:db8::124'):
        result = subprocess.run(['/sbin/route', '-n', 'get', target], capture_output=True, text=True)
        assert 'interface: utun64' not in result.stdout, 'Synthetic route remained'
    for key, args in [('default', ['/sbin/route', '-n', 'get', 'default']), ('dns', ['/usr/sbin/scutil', '--dns']), ('proxy', ['/usr/sbin/scutil', '--proxy'])]:
        assert output(args) == before[key], key + ' changed'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sudo-authorization', action='store_true', help='For disposable CI runners with existing passwordless sudo only')
    args = parser.parse_args()
    environment = os.environ.copy()
    if args.sudo_authorization:
        subprocess.run(['/usr/bin/sudo', '-n', 'true'], check=True)
        environment['SHADOWBAT_TUN_TEST_SUDO'] = '1'
    if os.geteuid() == 0:
        raise SystemExit('Run as the desktop user; the application performs its own macOS authorization.')
    if subprocess.run(['/sbin/ifconfig', 'utun64'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        raise SystemExit('utun64 is already in use; isolated validation skipped')
    for target in ('198.18.0.123', '198.18.0.124'):
        state = output(['/sbin/route', '-n', 'get', target])
        destination = next(line for line in state.splitlines() if 'destination:' in line)
        if '198.18.' in destination:
            raise SystemExit('Synthetic targets already have routes; isolated validation skipped')
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / 'report.json').write_text(json.dumps({'passed': False, 'status': 'not-completed'}))
    sources = [MAC / 'Native/Models/ServerProfile.swift'] + sorted((MAC / 'Shared').glob('*.swift'))
    sources += sorted((MAC / 'Native/Services').glob('*.swift')) + [MAC / 'Tests/TunAppChecks.swift']
    harness = WORK / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-default-isolation', 'MainActor',
                    *map(str, sources), '-o', str(harness)], check=True)
    before = {'default': output(['/sbin/route', '-n', 'get', 'default']), 'dns': output(['/usr/sbin/scutil', '--dns']),
              'proxy': output(['/usr/sbin/scutil', '--proxy'])}
    control_directories = {path.name for path in Path('/private/tmp').glob('shadowbat-tun-*') if path.lstat().st_uid == os.getuid()}
    fixtures, server, modes = [], None, []
    try:
        with tempfile.TemporaryDirectory(prefix='shadowbat-app-tun-') as scratch:
            scratch = Path(scratch)
            for marker in (b'shadowbat-tun-proxy', b'shadowbat-tun-direct'):
                httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), HTTPFixture)
                udp = socketserver.ThreadingUDPServer(('127.0.0.1', httpd.server_port), UDPFixture)
                httpd.marker = udp.marker = marker
                fixtures.extend([httpd, udp])
                for fixture in (httpd, udp):
                    threading.Thread(target=fixture.serve_forever, daemon=True).start()
            ss_port = free_port()
            config = {'log': {'level': 'error'},
                      'inbounds': [{'type': 'shadowsocks', 'listen': '127.0.0.1', 'listen_port': ss_port,
                                    'method': 'aes-256-gcm', 'password': 'temporary-tun-fixture-password'}],
                      'outbounds': [{'type': 'direct', 'tag': 'fixture'}],
                      'route': {'rules': [{'action': 'route', 'outbound': 'fixture', 'override_address': '127.0.0.1',
                                           'override_port': fixtures[0].server_port}], 'final': 'fixture'}}
            path = scratch / 'server.json'
            path.write_text(json.dumps(config)); path.chmod(0o600)
            server = subprocess.Popen([str(APP / 'sing-box'), 'run', '-c', str(path)], stdout=subprocess.DEVNULL)
            for _ in range(100):
                try:
                    with socket.create_connection(('127.0.0.1', ss_port), timeout=.1):
                        break
                except OSError:
                    time.sleep(.05)
            else:
                raise RuntimeError('Fixture Shadowsocks server did not start')
            for mode in ('disconnect', 'cancelled-disconnect', 'core-crash', 'supervisor-crash', 'app-crash'):
                directory = scratch / mode
                ports = set()
                while len(ports) < 2:
                    ports.add(free_port())
                socks, http_port = ports
                result = subprocess.run([str(harness), mode, str(APP / 'sing-box'), str(ss_port), str(fixtures[2].server_port),
                                         str(socks), str(http_port), str(APP / 'shadowbat-proxy-helper'), str(directory)], timeout=240, env=environment)
                assert result.returncode == (-9 if mode == 'app-crash' else 0), 'Native mode failed: ' + mode
                cleanup_state(before)
                for _ in range(100):
                    current = {path.name for path in Path('/private/tmp').glob('shadowbat-tun-*') if path.lstat().st_uid == os.getuid()}
                    if current <= control_directories:
                        break
                    time.sleep(.1)
                else:
                    raise RuntimeError('Private IPC directory survived native shutdown')
                for _ in range(100):
                    if not list(directory.glob('run-*')):
                        break
                    time.sleep(.1)
                else:
                    raise RuntimeError('Runtime credentials survived isolated app crash')
                modes.append(mode)
    finally:
        if server is not None and server.poll() is None:
            server.terminate(); server.wait(timeout=5)
        for fixture in fixtures:
            fixture.shutdown(); fixture.server_close()
    report = {'passed': True, 'modes': modes, 'checks': ['native-authorization', 'app-engine', 'tcp-proxy', 'tcp-direct',
              'udp-proxy', 'udp-direct', 'ipv6-tcp-udp-proxy-direct', 'dns-hijack', 'cancelled-disconnect-reconnect', 'crash-cleanup', 'no-default-route-dns-proxy-changes', 'credential-cleanup']}
    (WORK / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
