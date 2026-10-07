import 'dart:io';

import '../../domain/routing/routing_settings.dart';

Future<List<String>> resolveRoutingTarget(String target) async {
  final ip = IPAddress.parse(target.trim());
  if (ip != null) return [ip.text];
  final domain = normalizeDomain(target);
  final addresses = await InternetAddress.lookup(domain)
      .timeout(const Duration(seconds: 5));
  if (addresses.isEmpty) throw const FormatException('系统 DNS 没有返回 IP 地址。');
  return addresses.map((v) => v.address).toSet().toList();
}
