import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/shadowbat_state.dart';
import '../../domain/routing/routing_settings.dart';
import 'sing_box_config.dart';

/// Black-box routing checks use two HTTP fixtures with distinct responses.
/// Only test destinations are redirected; production matching/order is retained.
Future<List<String>> testWindowsRouting({
  required String core,
  required String directory,
  required ServerProfile profile,
  String? directTarget,
}) async {
  final checks = <String>[];
  final direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  direct.listen((request) {
    request.response.write('direct-routing-fixture');
    request.response.close();
  });
  final dns = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  dns.listen((event) {
    if (event != RawSocketEvent.read) return;
    final packet = dns.receive();
    if (packet == null || packet.data.length < 17) return;
    final data = packet.data;
    var end = 12;
    while (end < data.length && data[end] != 0) {
      end += data[end] + 1;
    }
    end++;
    if (end + 4 > data.length) return;
    final type = (data[end] << 8) | data[end + 1];
    final address = type == 1
        ? [198, 18, 0, 123]
        : type == 28
        ? [0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]
        : <int>[];
    final answer = address.isEmpty
        ? <int>[]
        : [
            0xc0,
            0x0c,
            0,
            type,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            address.length,
            ...address,
          ];
    dns.send(
      [
        data[0],
        data[1],
        0x81,
        0x80,
        0,
        1,
        0,
        address.isEmpty ? 0 : 1,
        0,
        0,
        0,
        0,
        ...data.sublist(12, end + 4),
        ...answer,
      ],
      packet.address,
      packet.port,
    );
  });
  Future<int> port() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final number = s.port;
    await s.close();
    return number;
  }

  RoutingRule rule(
    String id,
    RouteMatch type,
    String target,
    RouteAction action, {
    bool enabled = true,
  }) => RoutingRule.fromMap({
    'id': id,
    'type': type.name,
    'target': target,
    'action': action.name,
    'enabled': enabled,
  });
  final policies = <(RoutingSettings, List<(String, RouteAction)>)>[
    (
      RoutingSettings(
        rules: [
          rule(
            'exact',
            RouteMatch.domain,
            'api.other.test',
            RouteAction.direct,
          ),
          rule('suffix', RouteMatch.suffix, 'example.test', RouteAction.direct),
          rule('ip', RouteMatch.ip, '198.18.0.124', RouteAction.direct),
          rule('network', RouteMatch.cidr, '198.18.1.0/24', RouteAction.direct),
          rule('ipv6', RouteMatch.ip, '2001:db8::3', RouteAction.direct),
          rule(
            'ipv6-network',
            RouteMatch.cidr,
            '2001:db8:1::/48',
            RouteAction.direct,
          ),
          rule(
            'disabled',
            RouteMatch.domain,
            'disabled.other.test',
            RouteAction.direct,
            enabled: false,
          ),
          rule('requested', RouteMatch.ip, '101.33.73.2', RouteAction.direct),
        ],
      ).directOnly(),
      [
        ('api.other.test', RouteAction.direct),
        ('example.test', RouteAction.direct),
        ('sub.example.test', RouteAction.direct),
        ('evil-example.test', RouteAction.proxy),
        ('disabled.other.test', RouteAction.proxy),
        ('198.18.0.123', RouteAction.proxy),
        ('198.18.0.124', RouteAction.direct),
        ('198.18.1.10', RouteAction.direct),
        ('2001:db8::2', RouteAction.proxy),
        ('2001:db8::3', RouteAction.direct),
        ('2001:db8:1::10', RouteAction.direct),
        ('192.168.1.3', RouteAction.direct),
        ('101.33.73.2', RouteAction.direct),
      ],
    ),
    (
      const RoutingSettings(),
      [
        ('unmatched.test', RouteAction.proxy),
        ('198.18.0.123', RouteAction.proxy),
      ],
    ),
    if (directTarget != null)
      (
        RoutingSettings(
          rules: [
            rule(
              'requested-live',
              RouteMatch.ip,
              directTarget,
              RouteAction.direct,
            ),
          ],
        ),
        [(directTarget, RouteAction.direct)],
      ),
  ];
  try {
    for (final (index, (policy, targets)) in policies.indexed) {
      final live = directTarget != null && index == policies.length - 1;
      final http = await port(), socks = await port();
      final config = singBoxConfig(
        profiles: [profile],
        passwords: {profile.id: 'temporary-fixture-password'},
        socksPort: socks,
        httpPort: http,
        tun: false,
        routing: policy,
      );
      if (!live) {
        final dnsConfig = config['dns'] as Map<String, Object?>;
        // Fixture domains have deterministic IPv4 destinations; IPv6 routing
        // is covered separately with literal addresses below.
        dnsConfig['strategy'] = 'ipv4_only';
        dnsConfig['servers'] = [
          for (final tag in ['bootstrap', 'remote-dns'])
            {
              'type': 'udp',
              'tag': tag,
              'server': '127.0.0.1',
              'server_port': dns.port,
            },
        ];
        final route = config['route'] as Map<String, Object?>;
        final routes = route['rules'] as List<Map<String, Object?>>;
        for (final rule in routes) {
          if (rule['action'] == 'route' && rule['outbound'] == 'direct') {
            rule.addAll({
              'override_address': '127.0.0.1',
              'override_port': direct.port,
            });
          }
        }
        routes.add({
          'action': 'route',
          'outbound': policy.defaultAction.name,
          if (policy.defaultAction == RouteAction.direct)
            'override_address': '127.0.0.1',
          if (policy.defaultAction == RouteAction.direct)
            'override_port': direct.port,
        });
      }
      final file = File(p.join(directory, 'routing-fixture-$index.json'));
      await file.writeAsString(jsonEncode(config));
      final logs = StringBuffer();
      Process? child;
      try {
        final validation = await Process.run(core, ['check', '-c', file.path]);
        if (validation.exitCode != 0) {
          throw StateError('Routing config rejected: ${validation.stderr}');
        }
        child = await Process.start(core, [
          'run',
          '-c',
          file.path,
        ], workingDirectory: p.dirname(core));
        child.stdout.transform(utf8.decoder).listen(logs.write);
        child.stderr.transform(utf8.decoder).listen(logs.write);
        var ready = false;
        for (var i = 0; i < 80; i++) {
          try {
            final s = await Socket.connect(
              '127.0.0.1',
              http,
              timeout: const Duration(milliseconds: 100),
            );
            s.destroy();
            ready = true;
            break;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        if (!ready) throw StateError('Routing listener failed: $logs');
        for (final (target, action) in targets) {
          final ip = IPAddress.parse(target);
          final host = ip?.bits == 128 ? '[$target]' : target;
          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 5);
          client.findProxy = (_) => 'PROXY 127.0.0.1:$http';
          try {
            final request = await client
                .openUrl(live ? 'HEAD' : 'GET', Uri.parse('http://$host/'))
                .timeout(const Duration(seconds: 8));
            if (live) request.followRedirects = false;
            final response = await request.close().timeout(
              const Duration(seconds: 8),
            );
            if (live) {
              checks.add(
                'live direct target $target HTTP status ${response.statusCode}',
              );
              await response.drain<void>().timeout(const Duration(seconds: 3));
            } else {
              final body = await utf8.decoder
                  .bind(response)
                  .join()
                  .timeout(const Duration(seconds: 5));
              final expected = action == RouteAction.direct
                  ? 'direct-routing-fixture'
                  : 'shadowbat-windows-encrypted-fixture';
              if (body != expected) {
                throw StateError(
                  'Routing $target expected ${action.name}, received $body',
                );
              }
              checks.add('routing $index: $target -> ${action.name}');
            }
          } catch (e) {
            if (!live) {
              throw StateError('Routing $index $target: $e\n$logs');
            }
            checks.add('live target $target did not return HTTP: $e');
          } finally {
            client.close(force: true);
          }
          if (live) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            final directLines = logs
                .toString()
                .split('\n')
                .where(
                  (line) =>
                      line.contains('outbound/direct[direct]') &&
                      line.contains(target),
                )
                .toList();
            if (directLines.isEmpty) {
              throw StateError(
                'Live probe did not select direct outlet: $logs',
              );
            }
            checks.add('live rule verified: ${directLines.first.trim()}');
          }
        }
      } finally {
        child?.kill();
        if (child != null) {
          await child.exitCode.timeout(const Duration(seconds: 5));
        }
        if (await file.exists()) await file.delete();
      }
    }
  } finally {
    dns.close();
    await direct.close(force: true);
  }
  return checks;
}
