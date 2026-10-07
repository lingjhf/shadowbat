import '../../domain/routing/routing_settings.dart';

Map<String, Object?> ruleMatch(RoutingRule rule) => switch (rule.type) {
  RouteMatch.domain => {
    'domain': [rule.target],
  },
  RouteMatch.suffix => {
    'domain_suffix': [rule.target],
  },
  RouteMatch.ip => {
    'ip_cidr': ['${rule.target}/${IPAddress.parse(rule.target)!.bits}'],
  },
  RouteMatch.cidr => {
    'ip_cidr': [rule.target],
  },
};

/// Compile the same ordered policy for Windows and the native macOS host.
Map<String, Object?> singBoxRouting(
  RoutingSettings policy, {
  required bool tun,
}) {
  final rules = policy.rules.where((r) => r.enabled).toList();
  var resolved = false;
  final routeRules = <Map<String, Object?>>[
    if (tun)
      {
        'inbound': ['tun-in'],
        'action': 'sniff',
        'timeout': '300ms',
      },
    if (tun) {'protocol': 'dns', 'action': 'hijack-dns'},
    {'ip_cidr': reservedNetworks, 'action': 'route', 'outbound': 'direct'},
  ];
  for (final rule in rules) {
    if (!resolved &&
        (rule.type == RouteMatch.ip || rule.type == RouteMatch.cidr)) {
      routeRules.add({'action': 'resolve'});
      resolved = true;
    }
    routeRules.add({
      ...ruleMatch(rule),
      'action': 'route',
      'outbound': rule.action.name,
    });
  }
  if (!resolved) routeRules.add({'action': 'resolve'});
  routeRules.add({
    'ip_cidr': privateNetworks,
    'action': 'route',
    'outbound': 'direct',
  });
  return {
    'dns': {
      'reverse_mapping': true,
      'servers': [
        {'type': 'local', 'tag': 'bootstrap'},
        {
          'type': 'https',
          'tag': 'remote-dns',
          'server': '1.1.1.1',
          'detour': 'proxy',
        },
      ],
      'rules': [
        for (final rule in rules.where(
          (r) => r.type == RouteMatch.domain || r.type == RouteMatch.suffix,
        ))
          {
            ...ruleMatch(rule),
            'action': 'route',
            'server': rule.action == RouteAction.direct
                ? 'bootstrap'
                : 'remote-dns',
          },
      ],
      'final': policy.defaultAction == RouteAction.direct
          ? 'bootstrap'
          : 'remote-dns',
      'strategy': 'prefer_ipv4',
    },
    'route': {
      'auto_detect_interface': true,
      'default_domain_resolver': 'bootstrap',
      'rules': routeRules,
      'final': policy.defaultAction.name,
    },
  };
}
