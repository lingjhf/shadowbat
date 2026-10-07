import 'dart:convert';

import '../../domain/models/shadowbat_state.dart';
import '../../domain/routing/routing_settings.dart';
import '../routing/sing_box_routing.dart';

Map<String, Object?> profileMap(ServerProfile p) => {
  'id': p.id,
  'name': p.name,
  'host': p.host,
  'port': p.port,
  'method': p.method,
  'participatesInAutomaticSelection': p.participates,
};

void validateProfile(ServerProfile p, String password) {
  if (p.name.trim().isEmpty) throw StateError('请填写节点名称。');
  if (p.host.isEmpty ||
      p.host.trim() != p.host ||
      RegExp(r'\s|://|/|@').hasMatch(p.host)) {
    throw StateError('请填写域名或 IP 地址，不要包含协议或路径。');
  }
  if (p.port < 1 || p.port > 65535) throw StateError('服务器端口应为 1–65535。');
  if (!ServerProfile.methods.contains(p.method)) throw StateError('不支持此加密方式。');
  if (password.isEmpty) throw StateError('请填写密码或密钥。');
  if (p.method.startsWith('2022-')) {
    final length = p.method == '2022-blake3-aes-128-gcm' ? 16 : 32;
    try {
      if (password
          .split(':')
          .any((key) => base64.decode(key).length != length)) {
        throw const FormatException();
      }
    } on FormatException {
      throw StateError('此加密方式需要 Base64 编码的 $length 字节密钥。');
    }
  }
}

/// No public destination falls back to direct when candidates are unavailable.
Map<String, Object?> singBoxConfig({
  required List<ServerProfile> profiles,
  required Map<String, String> passwords,
  required int socksPort,
  required int httpPort,
  required bool tun,
  RoutingSettings routing = const RoutingSettings(),
  String testURL = 'https://www.apple.com/library/test/success.html',
}) {
  if (profiles.isEmpty) throw StateError('请启用至少一个候选节点或选择固定节点。');
  final tags = profiles.map((p) => 'node-${p.id}').toList();
  for (final profile in profiles) {
    validateProfile(profile, passwords[profile.id] ?? '');
  }
  return {
    'log': {'level': 'info', 'timestamp': true},
    ...singBoxRouting(routing, tun: tun),
    'inbounds': [
      {
        'type': 'socks',
        'tag': 'socks-in',
        'listen': '127.0.0.1',
        'listen_port': socksPort,
      },
      {
        'type': 'http',
        'tag': 'http-in',
        'listen': '127.0.0.1',
        'listen_port': httpPort,
      },
      if (tun)
        {
          'type': 'tun',
          'tag': 'tun-in',
          'interface_name': 'Shadowbat',
          'address': ['172.29.255.1/30', 'fdfe:29:ffff::1/126'],
          'mtu': 1500,
          'auto_route': true,
          'strict_route': true,
          'stack': 'mixed',
          'route_exclude_address': reservedNetworks,
        },
    ],
    'outbounds': [
      {'type': 'direct', 'tag': 'direct'},
      if (tags.length > 1)
        {
          'type': 'urltest',
          'tag': 'proxy',
          'outbounds': tags,
          'url': testURL,
          'interval': '1m',
          'tolerance': 50,
          'interrupt_exist_connections': false,
        }
      else
        {'type': 'selector', 'tag': 'proxy', 'outbounds': tags},
      for (final p in profiles)
        {
          'type': 'shadowsocks',
          'tag': 'node-${p.id}',
          'server': p.host,
          'server_port': p.port,
          'method': p.method,
          'password': passwords[p.id],
        },
    ],
  };
}
