import 'package:shadowbat/domain/routing/routing_settings.dart';

import 'dart:async';
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

class SlowShutdownPlatform extends TestWindowsPlatform {
  SlowShutdownPlatform(super.directory);
  Completer<void>? restoration;
  bool failRestoration = false;
  @override
  Future<Object?> invoke(String name, [Map<String, Object?>? args]) async {
    if (name == 'restoreSystemProxy' && restoration != null) {
      calls.add(name);
      await restoration!.future;
      if (failRestoration) throw StateError('restore failed');
      return false;
    }
    return super.invoke(name, args);
  }
}

void main() {
  test(
    'quit hides UI before slow restoration and coalesces repeated requests',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shadowbat-quit-',
      );
      final platform = SlowShutdownPlatform(directory.path);
      final repository = WindowsShadowbatRepository(platform);
      try {
        await repository.initialize();
        platform.calls.clear();
        platform.restoration = Completer<void>();
        final quit = repository.command('quit');
        expect(identical(quit, repository.command('quit')), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(platform.calls.first, 'beginShutdown');
        expect(platform.calls, contains('restoreSystemProxy'));
        expect(platform.calls, isNot(contains('quit')));
        await expectLater(
          repository.command('setTun', {'value': true}),
          throwsStateError,
        );
        platform.restoration!.complete();
        await quit;
        expect(platform.calls.where((v) => v == 'beginShutdown'), hasLength(1));
        expect(
          platform.calls.indexOf('quit'),
          greaterThan(platform.calls.indexOf('stopCore')),
        );
      } finally {
        await repository.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'failed quit restores UI and allows retry without killing core',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shadowbat-quit-',
      );
      final platform = SlowShutdownPlatform(directory.path);
      final repository = WindowsShadowbatRepository(platform);
      try {
        await repository.initialize();
        platform.calls.clear();
        platform.restoration = Completer<void>()..complete();
        platform.failRestoration = true;
        await expectLater(repository.command('quit'), throwsStateError);
        expect(platform.calls, contains('cancelShutdown'));
        expect(platform.calls, isNot(contains('stopCore')));
        expect(platform.calls, isNot(contains('quit')));
        platform.failRestoration = false;
        await repository.command('quit');
        expect(platform.calls, contains('quit'));
      } finally {
        await repository.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('legacy routing migrates to direct exceptions with an intact one-time backup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'shadowbat-migrate-',
    );
    WindowsShadowbatRepository? repository;
    WindowsShadowbatRepository? reopened;
    final legacy = const RoutingSettings(
      defaultAction: RouteAction.direct,
      rules: [
        RoutingRule(
          id: 'keep',
          type: RouteMatch.ip,
          target: '101.33.73.2',
          action: RouteAction.direct,
          enabled: false,
        ),
        RoutingRule(
          id: 'remove',
          type: RouteMatch.suffix,
          target: 'example.com',
          action: RouteAction.proxy,
        ),
      ],
    ).toMap();
    final saved = File(p.join(directory.path, 'routing.json'));
    final backup = File(
      p.join(directory.path, 'routing-before-direct-config.json'),
    );
    try {
      await saved.writeAsString(jsonEncode(legacy));
      repository = WindowsShadowbatRepository(
        TestWindowsPlatform(directory.path),
      );
      await repository.initialize();
      final migrated = repository.snapshot().routing;
      expect(migrated.defaultAction, RouteAction.proxy);
      expect(migrated.rules.single.id, 'keep');
      expect(migrated.rules.single.enabled, isFalse);
      expect(migrated.test('101.33.73.2').action, RouteAction.proxy);
      expect(migrated.test('8.8.8.8').action, RouteAction.proxy);
      expect(jsonDecode(await backup.readAsString()), legacy);
      expect(jsonDecode(await saved.readAsString()), migrated.toMap());
      await repository.command('saveRouting', legacy);
      expect(repository.snapshot().routing.toMap(), migrated.toMap());
      reopened = WindowsShadowbatRepository(
        TestWindowsPlatform(directory.path),
      );
      await reopened.initialize();
      expect(reopened.snapshot().routing.toMap(), migrated.toMap());
      expect(jsonDecode(await backup.readAsString()), legacy);
    } finally {
      await reopened?.close();
      await repository?.close();
      await directory.delete(recursive: true);
    }
  });

  test('routing persists atomically and invalid policies leave the saved state intact', () async {
    final directory = await Directory.systemTemp.createTemp(
      'shadowbat-routing-',
    );
    final repository = WindowsShadowbatRepository(
      TestWindowsPlatform(directory.path),
    );
    WindowsShadowbatRepository? reopened;
    try {
      await repository.initialize();
      final policy = RoutingSettings(
        defaultAction: RouteAction.direct,
        rules: [
          RoutingRule.fromMap({
            'id': 'first',
            'type': 'cidr',
            'target': '192.168.1.45/24',
            'action': 'direct',
            'enabled': true,
          }),
        ],
      );
      await repository.command('saveRouting', policy.toMap());
      final saved = await File(p.join(directory.path, 'routing.json'))
          .readAsString();
      await expectLater(
        repository.command('saveRouting', {'defaultAction': 'invalid'}),
        throwsFormatException,
      );
      expect(
        await File(p.join(directory.path, 'routing.json')).readAsString(),
        saved,
      );
      expect(
        repository.snapshot().routing.toMap(),
        policy.directOnly().toMap(),
      );
      reopened = WindowsShadowbatRepository(
        TestWindowsPlatform(directory.path),
      );
      await reopened.initialize();
      expect(reopened.snapshot().routing.rules.single.target, '192.168.1.0/24');
      expect(reopened.snapshot().routing.defaultAction, RouteAction.proxy);
    } finally {
      await reopened?.close();
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

  test(
    'TUN lets rules override LAN routing and keeps reserved addresses excluded',
    () {
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
      expect(tun['route_exclude_address'], isNot(contains('192.168.0.0/16')));
      expect(tun['route_exclude_address'], contains('127.0.0.0/8'));
      expect((config['route'] as Map)['final'], 'proxy');
      expect(
        (config['outbounds'] as List).where(
          (v) => (v as Map)['type'] == 'direct',
        ),
        hasLength(1),
      );
      expect((config['dns'] as Map)['final'], 'remote-dns');
    },
  );
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
    expect(
      (config['outbounds'] as List)
          .where((v) => (v as Map)['tag'] == 'proxy')
          .single['type'],
      'urltest',
    );
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
