/// Portable routing policy. No platform APIs are needed to validate or test it.
enum RouteAction {
  direct('直连'),
  proxy('代理');

  const RouteAction(this.label);
  final String label;
}

enum RouteMatch {
  domain('精确域名'),
  suffix('域名及子域名'),
  ip('单个 IP'),
  cidr('IP 网段');

  const RouteMatch(this.label);
  final String label;
}

class IPAddress {
  const IPAddress(this.value, this.bits);
  final BigInt value;
  final int bits;
  static IPAddress? parse(String text) {
    if (!text.contains(':')) {
      final parts = text.split('.');
      if (parts.length != 4) return null;
      var value = BigInt.zero;
      for (final part in parts) {
        if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) return null;
        final number = int.parse(part);
        if (number > 255) return null;
        value = (value << 8) | BigInt.from(number);
      }
      return IPAddress(value, 32);
    }
    if (text.contains('.') || text.contains('%')) {
      if (text.contains('%')) return null;
      final split = text.lastIndexOf(':');
      final ipv4 = parse(text.substring(split + 1));
      if (ipv4 == null || ipv4.bits != 32) return null;
      text =
          '${text.substring(0, split + 1)}${(ipv4.value >> 16).toRadixString(16)}:${(ipv4.value & BigInt.from(65535)).toRadixString(16)}';
    }
    final halves = text.split('::');
    if (halves.length > 2) return null;
    List<String> parts(String value) => value.isEmpty ? [] : value.split(':');
    final left = parts(halves.first);
    final right = halves.length == 2 ? parts(halves.last) : <String>[];
    final missing = 8 - left.length - right.length;
    if ((halves.length == 1 && missing != 0) ||
        (halves.length == 2 && missing < 1)) {
      return null;
    }
    final groups = [...left, ...List.filled(missing, '0'), ...right];
    var value = BigInt.zero;
    for (final group in groups) {
      if (!RegExp(r'^[0-9a-fA-F]{1,4}$').hasMatch(group)) return null;
      value = (value << 16) | BigInt.from(int.parse(group, radix: 16));
    }
    return IPAddress(value, 128);
  }

  String get text {
    if (bits == 32) {
      return [24, 16, 8, 0]
          .map((shift) => ((value >> shift) & BigInt.from(255)).toString())
          .join('.');
    }
    return List.generate(
      8,
      (i) => ((value >> ((7 - i) * 16)) & BigInt.from(65535)).toRadixString(16),
    ).join(':');
  }
}

class IPNetwork {
  IPNetwork(IPAddress address, this.prefix)
    : bits = address.bits,
      value =
          (address.value >> (address.bits - prefix)) << (address.bits - prefix);
  final int bits, prefix;
  final BigInt value;
  static IPNetwork? parse(String text) {
    final parts = text.split('/');
    if (parts.length != 2 || !RegExp(r'^[0-9]{1,3}$').hasMatch(parts.last)) {
      return null;
    }
    final address = IPAddress.parse(parts.first);
    final prefix = int.parse(parts.last);
    if (address == null || prefix > address.bits) return null;
    return IPNetwork(address, prefix);
  }

  bool contains(IPAddress address) =>
      bits == address.bits &&
      (address.value >> (bits - prefix)) == (value >> (bits - prefix));
  String get text => '${IPAddress(value, bits).text}/$prefix';
}

String normalizeDomain(String input) {
  final value = input.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (value.isEmpty ||
      value.length > 253 ||
      IPAddress.parse(value) != null ||
      value
          .split('.')
          .any(
            (label) =>
                !RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$')
                    .hasMatch(label),
          )) {
    throw const FormatException('请填写有效域名，不含协议、路径或通配符；国际域名请使用 Punycode。');
  }
  return value;
}

class RoutingRule {
  const RoutingRule({
    required this.id,
    required this.type,
    required this.target,
    required this.action,
    this.enabled = true,
  });
  factory RoutingRule.fromMap(Map<String, dynamic> map) {
    final id = map['id'];
    if (id is! String || id.isEmpty || id.length > 100) {
      throw const FormatException('规则标识无效。');
    }
    final type = RouteMatch.values
        .where((v) => v.name == map['type'])
        .firstOrNull;
    final action = RouteAction.values
        .where((v) => v.name == map['action'])
        .firstOrNull;
    if (type == null ||
        action == null ||
        map['target'] is! String ||
        (map['enabled'] != null && map['enabled'] is! bool)) {
      throw const FormatException('分流规则信息不完整。');
    }
    final input = (map['target'] as String).trim();
    final String target;
    switch (type) {
      case RouteMatch.domain:
      case RouteMatch.suffix:
        target = normalizeDomain(input);
      case RouteMatch.ip:
        final ip = IPAddress.parse(input);
        if (ip == null) throw const FormatException('请填写有效的 IPv4 或 IPv6 地址。');
        target = ip.text;
      case RouteMatch.cidr:
        final network = IPNetwork.parse(input);
        if (network == null) {
          throw const FormatException(
            '请填写有效网段，例如 192.168.1.0/24 或 2001:db8::/32。',
          );
        }
        target = network.text;
    }
    return RoutingRule(
      id: id,
      type: type,
      target: target,
      action: action,
      enabled: map['enabled'] as bool? ?? true,
    );
  }
  final String id, target;
  final RouteMatch type;
  final RouteAction action;
  final bool enabled;
  Map<String, Object?> toMap() => {
    'id': id,
    'type': type.name,
    'target': target,
    'action': action.name,
    'enabled': enabled,
  };
  bool matches(String domain, List<IPAddress> addresses) => switch (type) {
    RouteMatch.domain => domain == target,
    RouteMatch.suffix => domain == target || domain.endsWith('.$target'),
    RouteMatch.ip => addresses.any((ip) {
      final expected = IPAddress.parse(target)!;
      return ip.bits == expected.bits && ip.value == expected.value;
    }),
    RouteMatch.cidr => addresses.any(IPNetwork.parse(target)!.contains),
  };
  RoutingRule withEnabled(bool value) => RoutingRule(
    id: id,
    type: type,
    target: target,
    action: action,
    enabled: value,
  );
}

const reservedNetworks = [
  '127.0.0.0/8',
  '169.254.0.0/16',
  '::1/128',
  'fe80::/10',
];
const privateNetworks = [
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  'fc00::/7',
];

class RoutingDecision {
  const RoutingDecision(
    this.action,
    this.reason, {
    this.rule,
    this.needsAddresses = false,
  });
  final RouteAction action;
  final String reason;
  final RoutingRule? rule;
  final bool needsAddresses;
}

class RoutingSettings {
  const RoutingSettings({
    this.rules = const [],
    this.defaultAction = RouteAction.proxy,
  });
  factory RoutingSettings.fromMap(Map<String, dynamic> map) {
    final action = RouteAction.values
        .where((v) => v.name == (map['defaultAction'] ?? 'proxy'))
        .firstOrNull;
    final data = map['rules'] ?? <Object?>[];
    if (action == null || data is! List || data.length > 1000) {
      throw const FormatException('分流设置无效，最多支持 1000 条规则。');
    }
    final rules = data
        .map((r) => RoutingRule.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList();
    if (rules.map((r) => r.id).toSet().length != rules.length) {
      throw const FormatException('规则标识不能重复。');
    }
    return RoutingSettings(
      rules: List.unmodifiable(rules),
      defaultAction: action,
    );
  }
  final List<RoutingRule> rules;
  final RouteAction defaultAction;

  /// Windows exposes only direct exceptions; legacy proxy/default choices
  /// cannot override the fixed public proxy fallback.
  RoutingSettings directOnly() => RoutingSettings(
    rules: List.unmodifiable(
      rules.where((r) => r.action == RouteAction.direct),
    ),
  );
  Map<String, Object?> toMap() => {
    'rules': rules.map((r) => r.toMap()).toList(),
    'defaultAction': defaultAction.name,
  };
  RoutingDecision test(
    String target, {
    List<String> resolvedAddresses = const [],
  }) {
    final input = target.trim();
    final literal = IPAddress.parse(input);
    final domain = literal == null ? normalizeDomain(input) : '';
    final addresses = literal != null
        ? [literal]
        : resolvedAddresses.map((v) {
            final parsed = IPAddress.parse(v);
            if (parsed == null) throw const FormatException('DNS 结果不是有效 IP。');
            return parsed;
          }).toList();
    if (literal != null &&
        reservedNetworks.any((v) => IPNetwork.parse(v)!.contains(literal))) {
      return const RoutingDecision(RouteAction.direct, '系统保留地址始终直连');
    }
    var needsAddresses = false;
    final unresolvedActions = <RouteAction>{};
    for (final rule in rules.where((r) => r.enabled)) {
      if (literal == null &&
          addresses.isEmpty &&
          (rule.type == RouteMatch.ip || rule.type == RouteMatch.cidr)) {
        needsAddresses = true;
        unresolvedActions.add(rule.action);
      }
      if (rule.matches(domain, addresses)) {
        return RoutingDecision(
          rule.action,
          '命中「${rule.type.label}：${rule.target}」',
          rule: rule,
          needsAddresses: unresolvedActions.any(
            (action) => action != rule.action,
          ),
        );
      }
    }
    if (addresses.any(
      (ip) => privateNetworks.any((v) => IPNetwork.parse(v)!.contains(ip)),
    )) {
      return RoutingDecision(
        RouteAction.direct,
        '局域网默认直连',
        needsAddresses: needsAddresses,
      );
    }
    if (literal == null && addresses.isEmpty) needsAddresses = true;
    return RoutingDecision(
      defaultAction,
      '未命中规则，使用默认动作',
      needsAddresses: needsAddresses,
    );
  }
}
