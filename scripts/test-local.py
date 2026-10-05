#!/usr/bin/env python3
"""Isolated loopback integration tests. Never changes the Mac's system proxy."""
import http.server
import json
import pathlib
import select
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent / 'macos'

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'shadowbat-test-response'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass

class FixtureDNS(socketserver.BaseRequestHandler):
    def handle(self):
        packet, sock = self.request
        if len(packet) < 13:
            return
        end = 12
        while end < len(packet) and packet[end]:
            end += packet[end] + 1
        end += 1
        if end + 4 > len(packet):
            return
        question = packet[12:end + 4]
        query_type = int.from_bytes(packet[end:end + 2], 'big')
        answer = b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x01\x00\x04\x7f\x00\x00\x01' if query_type == 1 else b''
        header = packet[:2] + b'\x81\x80\x00\x01' + (b'\x00\x01' if answer else b'\x00\x00') + b'\x00\x00\x00\x00'
        sock.sendto(header + question + answer, self.client_address)

class OutboundFixture(socketserver.BaseRequestHandler):
    """Map the core's TCP health probe to our HTTP fixture without privileged ports or internet."""
    def read(self, count):
        result = b''
        while len(result) < count:
            chunk = self.request.recv(count - len(result))
            if not chunk:
                raise EOFError()
            result += chunk
        return result

    def handle(self):
        try:
            self.request.settimeout(10)
            version, count = self.read(2)
            if version != 5 or 0 not in self.read(count):
                return
            self.request.sendall(b'\x05\x00')
            version, command, _, kind = self.read(4)
            if version != 5 or command != 1:
                return
            if kind == 1:
                self.read(4)
            elif kind == 3:
                self.read(self.read(1)[0])
            elif kind == 4:
                self.read(16)
            else:
                return
            port = int.from_bytes(self.read(2), 'big')
            # Only loopback fixture traffic is forwarded, including detectportal:80.
            if port not in (80, self.server.fixture_port):
                return
            if port == 80:
                time.sleep(self.server.health_delay)
            with socket.create_connection(('127.0.0.1', self.server.fixture_port), timeout=5) as target:
                self.request.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
                self.request.settimeout(None)
                while True:
                    ready, _, _ = select.select([self.request, target], [], [], 10)
                    if not ready:
                        return
                    for source in ready:
                        chunk = source.recv(65536)
                        if not chunk:
                            return
                        (target if source is self.request else self.request).sendall(chunk)
        except (OSError, EOFError):
            pass

class OutboundServer(socketserver.ThreadingTCPServer):
    daemon_threads = True

def main():
    core = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'Tools/sslocal'
    server_path = shutil.which('ssserver')
    if not server_path:
        raise RuntimeError('Install shadowsocks-rust with Homebrew first')
    httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    dns = socketserver.ThreadingUDPServer(('127.0.0.1', 0), FixtureDNS)
    threading.Thread(target=dns.serve_forever, daemon=True).start()
    servers = []
    outbound_servers = []
    try:
        with tempfile.TemporaryDirectory(prefix='shadowbat-integration-') as scratch:
            scratch = pathlib.Path(scratch)
            ports = set()
            while len(ports) < 5:
                ports.add(free_port())
            server_port, second_port, dead_port, socks_port, http_port = ports
            for index, port in enumerate((server_port, second_port)):
                outbound = OutboundServer(('127.0.0.1', 0), OutboundFixture)
                outbound.fixture_port = httpd.server_port
                outbound.health_delay = .2 if index == 0 else 0
                outbound_servers.append(outbound)
                threading.Thread(target=outbound.serve_forever, daemon=True).start()
                config = scratch / f'server-{index}.json'
                config.write_text(json.dumps(dict(server='127.0.0.1', server_port=port,
                                                 password='temporary-shadowbat-test-password' if index == 0 else 'second-temporary-test-password',
                                                 method='aes-256-gcm', mode='tcp_only',
                                                 outbound_proxy=f'socks5://127.0.0.1:{outbound.server_address[1]}',
                                                 dns=f'udp://127.0.0.1:{dns.server_address[1]}')))
                config.chmod(0o600)
                server = subprocess.Popen([server_path, '-c', str(config)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                servers.append(server)
                for _ in range(100):
                    if server.poll() is not None:
                        raise RuntimeError('Test server exited')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            break
                    except OSError:
                        time.sleep(.05)
                else:
                    raise RuntimeError('Test server did not become ready')
            harness = scratch / 'checks'
            sources = [ROOT / 'Native/Models/ServerProfile.swift']
            sources += sorted((ROOT / 'Shared').glob('*.swift'))
            sources += sorted((ROOT / 'Native/Services').glob('*.swift'))
            sources += sorted((ROOT / 'Native/ViewModels').glob('*.swift'))
            subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                            '-default-isolation', 'MainActor', *map(str, sources),
                            str(ROOT / 'Tests/SmokeChecks.swift'), str(ROOT / 'Tests/TerminalProxyChecks.swift'),
                            str(ROOT / 'Tests/AutomaticSelectionChecks.swift'),
                            str(ROOT / 'Tests/GlobalProxyChecks.swift'),
                            '-o', str(harness)], check=True)
            subprocess.run([str(harness), str(core), str(server_port), str(socks_port), str(http_port),
                            str(httpd.server_port), str(servers[0].pid), str(second_port), str(servers[1].pid),
                            str(dead_port)], check=True, timeout=180)
    finally:
        for server in servers:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
        for outbound in outbound_servers:
            outbound.shutdown()
            outbound.server_close()
        httpd.shutdown()
        httpd.server_close()
        dns.shutdown()
        dns.server_close()

if __name__ == '__main__':
    main()
