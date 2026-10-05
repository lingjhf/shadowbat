import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;

import 'package:flutter_test/flutter_test.dart';
import 'package:shadowbat/data/windows/sing_box_config.dart';
import 'package:shadowbat/data/windows/windows_platform.dart';
import 'package:shadowbat/data/windows/windows_repository.dart';
import 'package:shadowbat/domain/models/shadowbat_state.dart';

const node = ServerProfile(
  id: 'aabb',
  name: 'Local',
  host: '127.0.0.1',
  port: 8388,
  method: 'aes-256-gcm',
  participates: true,
);

class TestWindowsPlatform implements WindowsPlatform {
  TestWindowsPlatform(this.directory);
  final String directory;
  final credentials = <String, String>{};
  final calls = <String>[];
  final shellProfiles = <String>[];
  late WindowsAction action;
  bool credentialFailure = false;
  @override
  void setActionHandler(WindowsAction handler) => action = handler;
  @override
  Future<Object?> invoke(String name, [Map<String, Object?>? args]) async {
    calls.add(name);
    switch (name) {
      case 'initialize':
        return {
          'directory': directory,
          'core': 'sing-box.exe',
          'admin': false,
          'shellProfiles': shellProfiles,
        };
      case 'hasProxyBackup':
        return false;
      case 'readPassword':
        return credentials[args!['id']];
      case 'savePassword':
        if (credentialFailure) throw StateError('credential failure');
        credentials[args!['id'] as String] = args['password'] as String;
      case 'deletePassword':
        credentials.remove(args!['id']);
      case 'restoreSystemProxy':
        return false;
      case 'terminalScript':
        return "Get-Content -LiteralPath '__STATE_PATH__'";
      case 'updateTray':
        return null;
    }
    return null;
  }
}

class ProxyRestoreFailurePlatform extends TestWindowsPlatform {
  ProxyRestoreFailurePlatform(super.directory);
  final listeners = <ServerSocket>[];
  bool running = false, restoreFailure = true;
  @override
  Future<Object?> invoke(String name, [Map<String, Object?>? args]) async {
    switch (name) {
      case 'startCore':
        calls.add(name);
        final config = jsonDecode(
          await File(args!['config'] as String).readAsString(),
        ) as Map;
        for (final inbound in config['inbounds'] as List) {
          final listener = await ServerSocket.bind(
            '127.0.0.1',
            (inbound as Map)['listen_port'] as int,
          );
          listener.listen((socket) => socket.destroy());
          listeners.add(listener);
        }
        running = true;
        return 1;
      case 'coreStatus':
        return {'running': running, 'exitCode': 0};
      case 'enableSystemProxy':
        throw StateError('apply failure');
      case 'restoreSystemProxy':
        if (restoreFailure) throw StateError('restore failure');
        return false;
      case 'stopCore':
        calls.add(name);
        for (final listener in listeners) {
          await listener.close();
        }
        listeners.clear();
        running = false;
        return 0;
      default:
        return super.invoke(name, args);
    }
  }
}

void main() {
  test('TUN routes public traffic through selected proxy and excludes LAN', () {
    final config = singBoxConfig(
      profiles: [node],
      passwords: {'aabb': 'secret'},
      socksPort: 1081,
      httpPort: 1087,
      tun: true,
    );
    final tun = (config['inbounds'] as List).last as Map;
    expect(tun['auto_route'], true);
    expect(tun['strict_route'], true);
    expect(tun['route_exclude_address'], contains('192.168.0.0/16'));
    expect((config['route'] as Map)['final'], 'proxy');
    expect(
      (config['outbounds'] as List).where(
        (v) => (v as Map)['type'] == 'direct',
      ),
      isEmpty,
    );
    expect((config['dns'] as Map)['final'], 'remote-dns');
  });
  test('automatic candidates use urltest without direct fallback; missing credentials fail', () {
    const second = ServerProfile(
      id: 'ccdd',
      name: 'second',
      host: 'example.com',
      port: 8388,
      method: 'aes-256-gcm',
      participates: true,
    );
    final config = singBoxConfig(
      profiles: [node, second],
      passwords: {'aabb': 'one', 'ccdd': 'two'},
      socksPort: 1081,
      httpPort: 1087,
      tun: false,
    );
    expect(((config['outbounds'] as List).first as Map)['type'], 'urltest');
    expect((config['inbounds'] as List).length, 2);
    expect(
      () => singBoxConfig(
        profiles: [node],
        passwords: {},
        socksPort: 1081,
        httpPort: 1087,
        tun: false,
      ),
      throwsStateError,
    );
  });
  test('AEAD-2022 rejects wrong length or empty chained keys', () {
    const profile = ServerProfile(
      id: 'aabb',
      name: '2022',
      host: 'example.com',
      port: 8388,
      method: '2022-blake3-aes-128-gcm',
      participates: true,
    );
    expect(
      () => validateProfile(profile, 'AAAAAAAAAAAAAAAAAAAAAA=='),
      returnsNormally,
    );
    expect(() => validateProfile(profile, 'short'), throwsStateError);
    expect(
      () => validateProfile(profile, 'AAAAAAAAAAAAAAAAAAAAAA==:'),
      throwsStateError,
    );
  });
  test('Windows credentials remain outside profiles and native tray commands update state', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'shadowbat-windows-test-',
    );
    final platform = TestWindowsPlatform(temporary.path);
    final repository = WindowsShadowbatRepository(platform);
    try {
      await repository.initialize();
      await repository.command('saveProfile', {
        ...profileMap(node),
        'password': 'private-secret',
      });
      final profileFile = File(p.join(temporary.path, 'profiles.json'));
      expect(
        await profileFile.readAsString(),
        isNot(contains('private-secret')),
      );
      expect(platform.credentials['aabb'], 'private-secret');
      await platform.action('setSelectionMode', {'value': 'manual'});
      expect(repository.snapshot().selectionMode, 'manual');
      await platform.action('setTun', {'value': true});
      expect(repository.snapshot().useTun, true);
      await expectLater(
        repository.command('setService', {'value': true}),
        throwsStateError,
      );
      expect(platform.calls, isNot(contains('startCore')));
      expect(repository.snapshot().state, 'disconnected');
    } finally {
      await repository.close();
      await temporary.delete(recursive: true);
    }
  });
  test('failed credential save leaves persisted nodes unchanged', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'shadowbat-windows-test-',
    );
    final platform = TestWindowsPlatform(temporary.path)
      ..credentialFailure = true;
    final repository = WindowsShadowbatRepository(platform);
    try {
      await repository.initialize();
      await expectLater(
        repository.command('saveProfile', {
          ...profileMap(node),
          'password': 'secret',
        }),
        throwsStateError,
      );
      expect(repository.snapshot().profiles, isEmpty);
      expect(
        await File(p.join(temporary.path, 'profiles.json')).exists(),
        false,
      );
    } finally {
      await repository.close();
      await temporary.delete(recursive: true);
    }
  });
  test(
    'PowerShell preserves UTF-16 profiles and backs up original bytes',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'shadowbat-shell-',
      );
      final platform = TestWindowsPlatform(temporary.path);
      final profile = File(p.join(temporary.path, '用户', 'profile.ps1'));
      await profile.parent.create(recursive: true);
      final original = 'Write-Output "你好"\r\n';
      final originalBytes = [
        0xff,
        0xfe,
        for (final c in original.codeUnits) ...[c & 255, c >> 8],
      ];
      await profile.writeAsBytes(originalBytes);
      platform.shellProfiles.add(profile.path);
      final repository = WindowsShadowbatRepository(platform);
      try {
        await repository.command('installTerminalIntegration');
        final saved = await profile.readAsBytes();
        expect(saved.take(3), [0xef, 0xbb, 0xbf]);
        final text = utf8.decode(saved.sublist(3));
        expect(text, contains(original));
        final backups = await temporary
            .list()
            .where((entry) => entry.path.endsWith('.ps1.backup'))
            .toList();
        expect(backups, hasLength(1));
        expect(await File(backups.single.path).readAsBytes(), originalBytes);
        await repository.command('installTerminalIntegration');
        expect(await profile.readAsBytes(), saved);
        expect(repository.snapshot().terminalInstalled, true);
      } finally {
        await repository.close();
        await temporary.delete(recursive: true);
      }
    },
  );
  test(
    'failed startup recovery keeps listener until proxy restore succeeds',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'shadowbat-restore-',
      );
      final platform = ProxyRestoreFailurePlatform(temporary.path);
      final repository = WindowsShadowbatRepository(platform);
      final first = await ServerSocket.bind('127.0.0.1', 0);
      final second = await ServerSocket.bind('127.0.0.1', 0);
      final socks = first.port, http = second.port;
      await first.close();
      await second.close();
      try {
        await repository.command('saveProfile', {
          ...profileMap(node),
          'password': 'secret',
        });
        await repository.command('setPorts', {'socks': socks, 'http': http});
        await repository.command('setSystemProxy', {'value': true});
        await expectLater(
          repository.command('setService', {'value': true}),
          throwsStateError,
        );
        expect(repository.snapshot().recoveryNeeded, true);
        expect(repository.snapshot().serviceEnabled, true);
        expect(platform.running, true);
        expect(platform.calls, isNot(contains('stopCore')));
        platform.restoreFailure = false;
        await repository.command('setService', {'value': false});
        expect(platform.running, false);
        expect(repository.snapshot().recoveryNeeded, false);
        expect(await File(p.join(temporary.path, 'run.json')).exists(), false);
      } finally {
        platform.restoreFailure = false;
        await platform.invoke('stopCore');
        await repository.close();
        await temporary.delete(recursive: true);
      }
    },
  );
}
