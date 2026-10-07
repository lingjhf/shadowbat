import 'package:flutter_test/flutter_test.dart';
import 'package:shadowbat/domain/routing/routing_settings.dart';
import 'package:shadowbat/data/routing/sing_box_routing.dart';
import 'package:shadowbat/data/windows/sing_box_config.dart';

import 'windows_backend_test.dart' show node;

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
void main() {
  test(
    '101.33.73.2 can be explicitly direct while other public IPs stay proxied',
    () {
      final policy = RoutingSettings(
        rules: [
          rule('requested', RouteMatch.ip, '101.33.73.2', RouteAction.direct),
        ],
      );
      expect(policy.test('101.33.73.2').action, RouteAction.direct);
      expect(policy.test('101.33.73.3').action, RouteAction.proxy);
      final compiled =
          (singBoxRouting(policy, tun: true)['route'] as Map)['rules'] as List;
      expect(
        compiled
            .where(
              (r) =>
                  (r as Map)['ip_cidr'] is List &&
                  (r['ip_cidr'] as List).contains('101.33.73.2/32'),
            )
            .single['outbound'],
        'direct',
      );
    },
  );

  test('IPv4/IPv6 validation and canonical CIDR boundaries', () {
    expect(IPAddress.parse('255.255.255.255')!.text, '255.255.255.255');
    expect(IPNetwork.parse('192.168.1.123/24')!.text, '192.168.1.0/24');
    expect(
      IPNetwork.parse('2001:db8:ffff::/32')!.text,
      '2001:db8:0:0:0:0:0:0/32',
    );
    expect(IPAddress.parse('::ffff:192.0.2.1'), isNotNull);
    for (final input in [
      '256.1.1.1',
      '01.2.3.4',
      '1.2.3',
      ':::1',
      '1::2::3',
      '2001:db8::fffff',
      'fe80::1%eth0',
    ]) {
      expect(IPAddress.parse(input), isNull, reason: input);
    }
    for (final input in ['1.2.3.4/33', '::1/129', '::1/-1', '::1/abc']) {
      expect(IPNetwork.parse(input), isNull, reason: input);
    }
    expect(
      IPNetwork.parse('0.0.0.0/0')!.contains(IPAddress.parse('203.0.113.7')!),
      isTrue,
    );
    expect(
      IPNetwork.parse('::/0')!.contains(IPAddress.parse('203.0.113.7')!),
      isFalse,
    );
  });
  test('direct exceptions do not need priority resolution for an exact domain match', () {
    final policy = RoutingSettings(
      rules: [
        rule('ip', RouteMatch.ip, '101.33.73.2', RouteAction.direct),
        rule('domain', RouteMatch.domain, 'example.com', RouteAction.direct),
      ],
    ).directOnly();
    expect(policy.test('example.com').action, RouteAction.direct);
    expect(policy.test('example.com').needsAddresses, isFalse);
    expect(policy.test('other.example').action, RouteAction.proxy);
    expect(policy.test('other.example').needsAddresses, isTrue);
  });
  test('normalization rejects URLs and preserves domain label boundaries', () {
    expect(normalizeDomain(' EXAMPLE.com. '), 'example.com');
    for (final input in [
      'https://example.com',
      'example.com/path',
      '*.example.com',
      '-bad.com',
      'a..com',
      '例子.中国',
      'example.com:443',
    ]) {
      expect(
        () => normalizeDomain(input),
        throwsFormatException,
        reason: input,
      );
    }
    final policy = RoutingSettings(
      rules: [
        rule('one', RouteMatch.suffix, 'example.com', RouteAction.direct),
      ],
    );
    expect(policy.test('EXAMPLE.COM.').rule?.id, 'one');
    expect(policy.test('a.b.example.com').rule?.id, 'one');
    expect(policy.test('evil-example.com').rule, isNull);
    expect(policy.test('example.com.evil').rule, isNull);
  });
  test(
    'first match wins across IP and domain rules; disabled entries are ignored',
    () {
      final specific = rule(
        'specific',
        RouteMatch.ip,
        '198.18.0.1',
        RouteAction.proxy,
      );
      final network = rule(
        'network',
        RouteMatch.cidr,
        '198.18.0.0/15',
        RouteAction.direct,
      );
      final domain = rule(
        'domain',
        RouteMatch.domain,
        'api.example.test',
        RouteAction.proxy,
      );
      final policy = RoutingSettings(
        rules: [specific, network, domain],
        defaultAction: RouteAction.direct,
      );
      expect(policy.test('198.18.0.1').rule?.id, 'specific');
      expect(
        policy
            .test('api.example.test', resolvedAddresses: ['198.18.0.1'])
            .rule
            ?.id,
        'specific',
      );
      expect(
        policy
            .test('api.example.test', resolvedAddresses: ['198.18.0.2'])
            .rule
            ?.id,
        'network',
      );
      expect(policy.test('api.example.test').needsAddresses, isTrue);
      expect(
        RoutingSettings(rules: [domain, network])
            .test('api.example.test')
            .needsAddresses,
        isFalse,
      );
      expect(
        RoutingSettings(rules: [specific.withEnabled(false), network])
            .test('198.18.0.1')
            .action,
        RouteAction.direct,
      );
      expect(
        RoutingSettings(rules: [network, specific]).test('198.18.0.1').action,
        RouteAction.direct,
      );
    },
  );
  test('private IP can use proxy while reserved destinations stay direct', () {
    final policy = RoutingSettings(
      rules: [
        rule('lan', RouteMatch.cidr, '192.168.0.0/16', RouteAction.proxy),
        rule('all', RouteMatch.cidr, '0.0.0.0/0', RouteAction.proxy),
      ],
    );
    expect(policy.test('192.168.1.8').action, RouteAction.proxy);
    expect(policy.test('127.0.0.1').action, RouteAction.direct);
    expect(
      const RoutingSettings().test('192.168.1.8').action,
      RouteAction.direct,
    );
    expect(
      const RoutingSettings(defaultAction: RouteAction.direct)
          .test('203.0.113.8')
          .action,
      RouteAction.direct,
    );
    expect(
      const RoutingSettings().test('203.0.113.8').action,
      RouteAction.proxy,
    );
  });
  test(
    'serialization validates IDs/actions and DNS rules follow domain policy',
    () {
      final policy = RoutingSettings(
        rules: [
          rule('1', RouteMatch.domain, 'api.example.com', RouteAction.proxy),
          rule('2', RouteMatch.suffix, 'example.com', RouteAction.direct),
          rule('3', RouteMatch.cidr, '2001:db8::/32', RouteAction.direct),
        ],
      );
      expect(
        RoutingSettings.fromMap(Map<String, dynamic>.from(policy.toMap()))
            .toMap(),
        policy.toMap(),
      );
      expect(
        () => RoutingSettings.fromMap({'defaultAction': 'invalid'}),
        throwsFormatException,
      );
      expect(
        () => RoutingSettings.fromMap({
          'rules': [policy.rules.first.toMap(), policy.rules.first.toMap()],
        }),
        throwsFormatException,
      );
      final config = singBoxRouting(policy, tun: true);
      final dns = config['dns'] as Map;
      expect(dns['reverse_mapping'], isTrue);
      final dnsRules = dns['rules'] as List;
      expect(dnsRules.first['server'], 'remote-dns');
      expect(dnsRules.last['server'], 'bootstrap');
      final routes = (config['route'] as Map)['rules'] as List;
      expect(routes.first['action'], 'sniff');
      expect(routes.where((r) => r['action'] == 'resolve'), hasLength(1));
      final custom = routes
          .where(
            (r) =>
                (r as Map).containsKey('domain') ||
                r.containsKey('domain_suffix'),
          )
          .toList();
      expect(custom.first['outbound'], 'proxy');
      expect(custom.last['outbound'], 'direct');
    },
  );
  test('TUN does not exclude user-routable LANs and proxy group never falls back direct', () {
    final config = singBoxConfig(
      profiles: [node],
      passwords: {node.id: 'secret'},
      socksPort: 18001,
      httpPort: 18002,
      tun: true,
      routing: RoutingSettings(
        rules: [
          rule('lan', RouteMatch.cidr, '192.168.0.0/16', RouteAction.proxy),
        ],
      ),
    );
    expect(
      ((config['inbounds'] as List).last as Map)['route_exclude_address'],
      isNot(contains('192.168.0.0/16')),
    );
    final proxy =
        (config['outbounds'] as List).where((r) => r['tag'] == 'proxy').single
            as Map;
    expect(proxy['outbounds'], isNot(contains('direct')));
  });
}
