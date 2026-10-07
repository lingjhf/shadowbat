import 'windows_routing_self_test.dart';
import '../../domain/routing/routing_settings.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/shadowbat_state.dart';
import 'sing_box_config.dart';
import 'windows_platform.dart';
import 'windows_repository.dart';

/// Explicit CLI smoke test on a real Windows Flutter runner, entirely local.
Future<void> runWindowsSelfTest(
  List<String> args,
  WindowsPlatform platform,
) async {
  if (!args.contains('--isolated-preview')) {
    throw StateError('自检必须指定 --isolated-preview。');
  }
  final resultArgument = args
      .where((a) => a.startsWith('--self-test-result='))
      .firstOrNull;
  final output = File(
    resultArgument?.substring('--self-test-result='.length) ??
        p.join(Directory.current.path, 'windows-self-test.json'),
  );
  final directTarget = args
      .where((v) => v.startsWith('--self-test-direct-target='))
      .firstOrNull
      ?.split('=')
      .last;
  final tunnelOnly = args.contains('--self-test-tun-only');
  final results = <String>[];
  WindowsShadowbatRepository? repository;
  Process? server;
  int? serverExit;
  final serverLogs = StringBuffer();
  HttpServer? http;
  final fixtureFiles = <File>[];
  final credentialIDs = <String>[];
  Object? failure;
  Future<int> freePort() async {
    // Windows can reserve a UDP range even when its TCP ports are available.
    for (var attempt = 0; attempt < 30; attempt++) {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      try {
        final udp = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          s.port,
        );
        final port = s.port;
        udp.close();
        return port;
      } on SocketException {
        // Select another port instead of launching a partially bound fixture.
      } finally {
        await s.close();
      }
    }
    throw StateError('No free TCP/UDP port for the native fixture.');
  }

  void check(bool value, String reason) {
    if (!value) throw StateError(reason);
    results.add(reason);
  }

  Future<String> fetch(int port, String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      return await utf8.decoder.bind(response).join();
    } finally {
      client.close(force: true);
    }
  }

  try {
    final paths = Map<String, dynamic>.from(
      await platform.invoke('initialize') as Map,
    );
    final directory = paths['directory'] as String,
        core = paths['core'] as String;
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      http.forEach((request) async {
        request.response.write('shadowbat-windows-encrypted-fixture');
        await request.response.close();
      }),
    );
    final url = 'http://198.18.0.123:${http.port}/';
    final serverPort = await freePort(),
        socks = await freePort(),
        localHTTP = await freePort();
    final config = File(p.join(directory, 'fixture-server.json'));
    fixtureFiles.add(config);
    await config.writeAsString(
      jsonEncode({
        'log': {'level': 'info'},
        'inbounds': [
          {
            'type': 'shadowsocks',
            'listen': '127.0.0.1',
            'listen_port': serverPort,
            'method': 'aes-256-gcm',
            'password': 'temporary-fixture-password',
          },
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {
          'rules': [
            {
              'action': 'route',
              'outbound': 'direct',
              'override_address': '127.0.0.1',
              'override_port': http.port,
            },
          ],
        },
      }),
    );
    await platform.invoke('secureFile', {'path': config.path});
    server = await Process.start(core, [
      'run',
      '-c',
      config.path,
    ], workingDirectory: p.dirname(core));
    server.stdout.transform(utf8.decoder).listen(serverLogs.write);
    server.stderr.transform(utf8.decoder).listen(serverLogs.write);
    unawaited(server.exitCode.then((value) => serverExit = value));
    var serverReady = false;
    for (var i = 0; i < 50; i++) {
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          serverPort,
          timeout: const Duration(milliseconds: 100),
        );
        socket.destroy();
        serverReady = true;
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (!serverReady || serverExit != null) {
      throw StateError(
        'Fixture server did not listen (exit $serverExit): $serverLogs',
      );
    }
    check(true, 'local encrypted fixture listener is ready');
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final profile = ServerProfile(
      id: id,
      name: 'Windows fixture',
      host: '127.0.0.1',
      port: serverPort,
      method: 'aes-256-gcm',
      participates: true,
    );
    if (!tunnelOnly) {
      repository = WindowsShadowbatRepository(platform, probeURL: url);
      await repository.initialize();
      if (repository.snapshot().recoveryNeeded) {
        await repository.command('recoverSystemProxy');
      }
      await repository.command('setPorts', {'socks': socks, 'http': localHTTP});
      credentialIDs.add(id);
      await repository.command('saveProfile', {
        ...profileMap(profile),
        'password': 'temporary-fixture-password',
      });
      check(
        await repository.command('password', {'id': id}) ==
            'temporary-fixture-password',
        'Windows Credential Manager round-trip',
      );
      check(
        !(await File(
          p.join(directory, 'profiles.json'),
        ).readAsString()).contains('temporary-fixture-password'),
        'profiles contain no passwords',
      );
      var slowCompleted = false;
      final slowNative = platform.invoke('testWorkerDelay').then((_) {
        slowCompleted = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final uiWatch = Stopwatch()..start();
      await platform.invoke('updateTray', {
        'stateLabel': '正在连接',
        'state': 'starting',
        'busy': true,
      });
      check(
        !slowCompleted && uiWatch.elapsedMilliseconds < 400,
        'native UI responds during 1200 ms worker operation (${uiWatch.elapsedMilliseconds} ms)',
      );
      uiWatch.reset();
      check(
        await platform.invoke('beginShutdown') == true &&
            !slowCompleted &&
            uiWatch.elapsedMilliseconds < 400,
        'quit hides native UI immediately during pending cleanup (${uiWatch.elapsedMilliseconds} ms)',
      );
      await platform.invoke('cancelShutdown');
      await slowNative;
      await repository.command('setSelectionMode', {'value': 'manual'});
      await repository.command('setManualNode', {'id': id});
      await repository.command(
        'saveRouting',
        const RoutingSettings(
          rules: [
            RoutingRule(
              id: 'direct-fixture',
              type: RouteMatch.ip,
              target: '101.33.73.2',
              action: RouteAction.direct,
            ),
          ],
        ).toMap(),
      );
      await repository.command('setService', {'value': true});
      check(
        repository.snapshot().state == 'connected',
        'native core launch and listener readiness',
      );
      check(
        await fetch(localHTTP, url) == 'shadowbat-windows-encrypted-fixture',
        'encrypted HTTP through Shadowsocks',
      );
      check(
        await fetch(localHTTP, 'http://127.0.0.1:${http.port}/') ==
            'shadowbat-windows-encrypted-fixture',
        'local HTTP stays direct alongside public proxy fallback',
      );
      check(
        repository.snapshot().routing.defaultAction == RouteAction.proxy,
        'public traffic uses fixed proxy fallback with direct exceptions',
      );
      final curl = await Process.run('curl.exe', [
        '--max-time',
        '8',
        '--noproxy',
        'shadowbat.invalid',
        '--socks5-hostname',
        '127.0.0.1:$socks',
        url,
      ]);
      check(
        curl.exitCode == 0 &&
            curl.stdout.toString().contains(
              'shadowbat-windows-encrypted-fixture',
            ),
        'encrypted SOCKS5 through Shadowsocks',
      );
      await repository.command('testConnection');
      check(
        repository.snapshot().testResult?.contains('成功') == true,
        'application connection probe',
      );
      await repository.command('setSystemProxy', {'value': true});
      check(
        repository.snapshot().systemProxyEnabled,
        'isolated system-proxy transaction',
      );
      await repository.command('setTerminalProxy', {'value': true});
      check(
        repository.snapshot().terminalProxyEnabled,
        'isolated PowerShell profiles installed',
      );
      final script = p.join(directory, 'terminal-proxy.ps1');
      final shell = await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        ". '${script.replaceAll("'", "''")}'; if (\$env:https_proxy -ne 'http://127.0.0.1:$localHTTP') { exit 2 }; curl.exe --noproxy shadowbat.invalid --max-time 8 $url",
      ]);
      check(
        shell.exitCode == 0 &&
            shell.stdout.toString().contains(
              'shadowbat-windows-encrypted-fixture',
            ),
        'PowerShell environment sends encrypted request',
      );
      await repository.command('setService', {'value': false});
      check(
        !(await platform.invoke('hasProxyBackup') as bool),
        'system proxy restored on disconnect',
      );
      check(
        !await File(p.join(directory, 'run.json')).exists(),
        'temporary credential config deleted',
      );
      await repository.command('setSystemProxy', {'value': false});
      await repository.command('setTerminalProxy', {'value': false});
      final before = await platform.invoke('coreStatus') as Map;
      check(before['running'] == false, 'native core stopped');
    }
    // Validate the production TUN schema without changing system routes.
    final tunFile = File(p.join(directory, 'tun-check.json'));
    if (!tunnelOnly) {
      results.addAll(
        await testWindowsRouting(
          core: core,
          directory: directory,
          profile: profile,
          directTarget: directTarget,
        ),
      );
    }
    fixtureFiles.add(tunFile);
    final tunConfig = singBoxConfig(
      profiles: [profile],
      passwords: {id: 'temporary-fixture-password'},
      socksPort: socks,
      httpPort: localHTTP,
      tun: true,
    );
    await tunFile.writeAsString(jsonEncode(tunConfig));
    await platform.invoke('secureFile', {'path': tunFile.path});
    final validated = await Process.run(core, [
      'check',
      '-c',
      tunFile.path,
    ], workingDirectory: p.dirname(core));
    check(
      validated.exitCode == 0,
      'production TUN configuration accepted by bundled core: ${validated.stderr}',
    );
    if (paths['admin'] == true) {
      final device = (tunConfig['inbounds'] as List).last as Map;
      device['interface_name'] = 'ShadowbatTest';
      device['auto_route'] = false;
      device['strict_route'] = false;
      await tunFile.writeAsString(jsonEncode(tunConfig));
      final run = File(p.join(directory, 'run.json'));
      fixtureFiles.add(run);
      await run.writeAsString(jsonEncode(tunConfig));
      await platform.invoke('secureFile', {'path': run.path});
      await platform.invoke('startCore', {
        'executable': core,
        'config': run.path,
        'log': p.join(directory, 'core.log'),
      });
      await Future<void>.delayed(const Duration(seconds: 3));
      final adapter = await Process.run('powershell.exe', [
        '-NoProfile',
        '-Command',
        "if (Get-NetAdapter -Name ShadowbatTest -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }",
      ]);
      if (adapter.exitCode != 0) {
        throw StateError(
          await File(p.join(directory, 'core.log')).readAsString(),
        );
      }
      check(true, 'real Wintun adapter created without default-route changes');
      // Route only a synthetic test destination, keeping SSH and default routes.
      final route = await Process.run('powershell.exe', [
        '-NoProfile',
        '-Command',
        "New-NetRoute -DestinationPrefix 198.18.0.123/32 -InterfaceAlias ShadowbatTest -NextHop 0.0.0.0 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null",
      ]);
      check(route.exitCode == 0, 'isolated TUN host route installed');
      final tunnelRequest = await Process.run('curl.exe', [
        '--max-time',
        '8',
        '--noproxy',
        '*',
        'http://198.18.0.123:18080/',
      ]);
      check(
        tunnelRequest.exitCode == 0 &&
            tunnelRequest.stdout.toString().contains(
              'shadowbat-windows-encrypted-fixture',
            ),
        'real TCP traffic traverses Wintun and encrypted Shadowsocks',
      );
      check(
        await platform.invoke('stopCore') == 0,
        'Wintun core exited gracefully',
      );
      final removed = await Process.run('powershell.exe', [
        '-NoProfile',
        '-Command',
        "if (Get-NetAdapter -Name ShadowbatTest -ErrorAction SilentlyContinue) { exit 1 } else { exit 0 }",
      ]);
      check(removed.exitCode == 0, 'Wintun adapter removed after shutdown');
    } else {
      if (tunnelOnly) throw StateError('TUN 自检需要管理员权限。');
      results.add('SKIP: Wintun live adapter requires elevation');
    }
    if (repository != null) {
      await repository.command('deleteProfile', {'id': id});
    }
  } catch (e, stack) {
    failure = '$e\n$stack\nFixture exit: $serverExit\n$serverLogs';
  } finally {
    if (repository != null) {
      try {
        await repository.command('setService', {'value': false});
      } catch (_) {}
      await repository.close();
    }

    try {
      await platform.invoke('stopCore');
    } catch (_) {}
    server?.kill();
    await http?.close(force: true);
    for (final id in credentialIDs) {
      try {
        await platform.invoke('deletePassword', {'id': id});
      } catch (_) {}
    }
    for (final file in fixtureFiles) {
      if (await file.exists()) await file.delete();
    }
    await output.parent.create(recursive: true);
    await output.writeAsString(
      jsonEncode({
        'passed': failure == null,
        'checks': results,
        'failure': failure,
      }),
      flush: true,
    );
    await platform.invoke('quit');
  }
}
