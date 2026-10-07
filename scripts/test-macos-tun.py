#!/usr/bin/env python3
"""Administrator-only isolated utun test. Never installs a helper or changes default routes/DNS.

Prepare as the normal user: python3 scripts/test-macos-tun.py --prepare
Run via macOS administrator authorization: /usr/bin/python3 scripts/test-macos-tun.py
Only two synthetic /32 routes are added; all processes and routes are removed in finally.
"""
import argparse
import copy
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / 'build/macos-tun'
CORE = ROOT / 'macos/Tools/sing-box'
TARGETS = ('198.18.0.123', '198.18.0.124')


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=30, **kwargs).stdout


def prepare():
    WORK.mkdir(parents=True, exist_ok=True)
    sources = [ROOT / 'macos/Native/Models/ServerProfile.swift']
    sources += sorted((ROOT / 'macos/Shared').glob('*.swift'))
    sources += sorted((ROOT / 'macos/Native/Services').glob('*.swift'))
    sources += [ROOT / 'macos/Tests/TunConfiguration.swift']
    emitter = WORK / 'config-emitter'
    run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-default-isolation', 'MainActor',
         *map(str, sources), '-o', str(emitter)])
    config = run([str(emitter)])
    (WORK / 'client-template.json').write_text(config)
    run([str(CORE), 'check', '-c', str(WORK / 'client-template.json')])
    print('PASS: native production TUN configuration compiled and accepted by sing-box')


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.server.marker
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def terminate(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def test():
    if os.geteuid() != 0:
        raise SystemExit('Use macOS administrator authorization to run the prepared isolated TUN test.')
    template = json.loads((WORK / 'client-template.json').read_text())
    # Validate the actual native template before adapting it to loopback fixtures.
    run([str(CORE), 'check', '-c', str(WORK / 'client-template.json')])
    interface_state = run(['/sbin/ifconfig', '-a'])
    interface = next('utun' + str(i) for i in range(64, 256) if 'utun' + str(i) + ':' not in interface_state)
    if '172.29.254.' in interface_state:
        raise RuntimeError('The isolated test subnet is already in use')
    for address in TARGETS:
        existing = run(['/sbin/route', '-n', 'get', address])
        destination = next(line.strip() for line in existing.splitlines() if 'destination:' in line)
        if '198.18.' in destination:
            raise RuntimeError('A synthetic fixture target already has a route: ' + address)
    before_default = run(['/sbin/route', '-n', 'get', 'default'])
    before_dns = run(['/usr/sbin/scutil', '--dns'])
    before_proxy = run(['/usr/sbin/scutil', '--proxy'])
    routes, processes, fixtures, checks = [], [], [], []
    errors = []
    try:
        with tempfile.TemporaryDirectory(prefix='shadowbat-tun-') as scratch:
            scratch = Path(scratch)
            scratch.chmod(0o700)
            for marker in (b'shadowbat-tun-proxy', b'shadowbat-tun-direct'):
                fixture = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
                fixture.marker = marker
                fixtures.append(fixture)
                threading.Thread(target=fixture.serve_forever, daemon=True).start()
            port = free_port()
            password = 'temporary-tun-fixture-password'
            server = {'log': {'level': 'info'},
                      'inbounds': [{'type': 'shadowsocks', 'listen': '127.0.0.1', 'listen_port': port,
                                    'method': 'aes-256-gcm', 'password': password}],
                      'outbounds': [{'type': 'direct', 'tag': 'fixture'}],
                      'route': {'rules': [{'action': 'route', 'outbound': 'fixture', 'override_address': '127.0.0.1',
                                           'override_port': fixtures[0].server_port}], 'final': 'fixture'}}
            client = copy.deepcopy(template)
            client['log']['output'] = str(scratch / 'client.log')
            client['route']['auto_detect_interface'] = False  # All fixture endpoints are loopback.
            client['inbounds'] = [inbound for inbound in client['inbounds'] if inbound['type'] == 'tun']
            tun = client['inbounds'][0]
            tun.update(interface_name=interface, auto_route=False, dns_mode='disabled')
            for outbound in client['outbounds']:
                if outbound['type'] == 'shadowsocks':
                    outbound.update(server_port=port, password=password)
            # Preserve production direct/proxy decisions, changing only the fixture destination.
            for rule in client['route']['rules']:
                if rule.get('ip_cidr') == [TARGETS[1] + '/32']:
                    rule.update(override_address='127.0.0.1', override_port=fixtures[1].server_port)
            for name, config in [('server', server), ('client', client)]:
                path = scratch / (name + '.json')
                path.write_text(json.dumps(config))
                path.chmod(0o600)
                run([str(CORE), 'check', '-c', str(path)])
                process = subprocess.Popen([str(CORE), 'run', '-c', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                processes.append(process)
                if name == 'server':
                    for _ in range(100):
                        try:
                            with socket.create_connection(('127.0.0.1', port), timeout=.1):
                                break
                        except OSError:
                            time.sleep(.05)
                    else:
                        raise RuntimeError('Fixture Shadowsocks server did not start')
            for _ in range(100):
                if processes[-1].poll() is not None:
                    raise RuntimeError('TUN core exited during startup')
                state = subprocess.run(['/sbin/ifconfig', interface], capture_output=True, text=True).stdout
                if '172.29.254.1' in state:
                    break
                time.sleep(.05)
            else:
                raise RuntimeError('utun interface did not become ready')
            checks.append('utun-created')
            for address in TARGETS:
                run(['/sbin/route', '-n', 'add', '-host', address, '-interface', interface])
                routes.append(address)
                assert 'interface: ' + interface in run(['/sbin/route', '-n', 'get', address])
            for address, marker in zip(TARGETS, ('shadowbat-tun-proxy', 'shadowbat-tun-direct')):
                response = run(['/usr/bin/curl', '--silent', '--show-error', '--fail', '--noproxy', '*',
                                '--max-time', '10', 'http://' + address + ':18080/'])
                assert response == marker, 'Wrong TUN path: ' + address
                checks.append(marker)
            terminate(processes[0])
            response = run(['/usr/bin/curl', '--silent', '--show-error', '--fail', '--noproxy', '*',
                            '--max-time', '5', 'http://' + TARGETS[1] + ':18080/'])
            assert response == 'shadowbat-tun-direct'
            failure = subprocess.run(['/usr/bin/curl', '--silent', '--noproxy', '*', '--max-time', '3',
                                      'http://' + TARGETS[0] + ':18080/'], capture_output=True)
            assert failure.returncode != 0, 'TUN silently bypassed stopped proxy upstream'
            checks.append('upstream-failure-without-direct-fallback')
            log = (scratch / 'client.log').read_text()
            assert 'outbound/shadowsocks' in log and 'outbound/direct' in log
            checks.append('native-routing-confirmed-in-core-log')
    except Exception as error:
        errors.append(str(error))
    finally:
        # Delete only routes successfully created by this test; the default route is never touched.
        for address in reversed(routes):
            try:
                run(['/sbin/route', '-n', 'delete', '-host', address, '-interface', interface])
            except Exception as error:
                errors.append('Route cleanup: ' + str(error))
        for process in reversed(processes):
            try:
                terminate(process)
            except Exception as error:
                errors.append('Process cleanup: ' + str(error))
        for fixture in fixtures:
            fixture.shutdown()
            fixture.server_close()
    for _ in range(50):
        if subprocess.run(['/sbin/ifconfig', interface], capture_output=True).returncode != 0:
            checks.append('utun-removed')
            break
        time.sleep(.1)
    else:
        errors.append('utun interface remained after core exit')
    for label, args, expected in [('default-route', ['/sbin/route', '-n', 'get', 'default'], before_default),
                                  ('dns', ['/usr/sbin/scutil', '--dns'], before_dns),
                                  ('system-proxy', ['/usr/sbin/scutil', '--proxy'], before_proxy)]:
        if run(args) == expected:
            checks.append(label + '-unchanged')
        else:
            errors.append(label + ' changed during test')
    for address in routes:
        if 'interface: ' + interface in run(['/sbin/route', '-n', 'get', address]):
            errors.append('Test route was left behind: ' + address)
    report = {'passed': not errors, 'interface': interface, 'checks': checks, 'errors': errors}
    path = WORK / 'report.json'
    path.write_text(json.dumps(report, indent=2))
    path.chmod(0o644)
    print(json.dumps(report, indent=2))
    if errors:
        raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true')
    args = parser.parse_args()
    if args.prepare:
        prepare()
    else:
        test()
