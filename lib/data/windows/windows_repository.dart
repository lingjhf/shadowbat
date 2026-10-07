import '../../domain/routing/routing_settings.dart';
import '../services/routing_resolver.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';

import '../../domain/models/shadowbat_state.dart';
import '../repositories/shadowbat_repository.dart';
import 'sing_box_config.dart';
import 'windows_platform.dart';

class WindowsShadowbatRepository implements ShadowbatRepository {
  WindowsShadowbatRepository(
    this.platform, {
    this.probeURL = 'https://www.apple.com/library/test/success.html',
  }) {
    platform.setActionHandler((name, args) async {
      try {
        await command(name, args);
      } catch (e) {
        _error = _message(e);
        _publish();
      }
    });
  }
  final WindowsPlatform platform;
  final _events = StreamController<ShadowbatState>.broadcast();
  final _random = Random.secure();
  final _logs = <Map<String, dynamic>>[];
  RoutingSettings _routing = const RoutingSettings();
  final _preferences = <String, Object?>{};
  List<ServerProfile> _profiles = [];
  List<String> _activeIDs = [];
  String? _selectedID, _error, _testResult;
  String _state = 'disconnected';
  String _directory = '', _core = '', _logFile = '';
  List<String> _shellProfiles = [];
  bool _initialized = false, _systemActive = false, _terminalActive = false;
  bool _busy = false, _testing = false, _recovery = false, _admin = false;
  bool _polling = false, _closed = false;
  int _logOffset = 0, _generation = 0;
  Timer? _timer;
  Future<void>? _initializing;
  Future<Object?>? _quitting;
  final String probeURL;
  String get _mode => _preferences['selectionMode'] as String? ?? 'automatic';
  String? get _manualID => _preferences['manualID'] as String?;
  bool _flag(String key) => _preferences[key] as bool? ?? false;
  int get _socks => _preferences['socksPort'] as int? ?? 1081;
  int get _http => _preferences['httpPort'] as int? ?? 1087;
  bool get _enabled => _state == 'connected' || _state == 'starting';
  List<ServerProfile> get _candidates => _profiles
      .where((v) => _mode == 'automatic' ? v.participates : v.id == _manualID)
      .toList();
  String _message(Object e) => e is PlatformException
      ? e.message ?? e.code
      : e is StateError
      ? e.message.toString()
      : e.toString();
  File _file(String name) => File(p.join(_directory, name));
  String _id() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    final paths = Map<String, dynamic>.from(
      await platform.invoke('initialize') as Map,
    );
    _directory = paths['directory'] as String;
    _core = paths['core'] as String;
    _admin = paths['admin'] as bool;
    _shellProfiles = (paths['shellProfiles'] as List).cast<String>();
    await Directory(_directory).create(recursive: true);
    await platform.invoke('secureFile', {'path': _directory});
    if (await _file('profiles.json').exists()) {
      _profiles =
          (jsonDecode(await _file('profiles.json').readAsString()) as List)
              .map(
                (v) =>
                    ServerProfile.fromMap(Map<String, dynamic>.from(v as Map)),
              )
              .toList();
    }
    if (await _file('preferences.json').exists()) {
      _preferences.addAll(
        Map<String, Object?>.from(
          jsonDecode(await _file('preferences.json').readAsString()) as Map,
        ),
      );
    }
    if (await _file('routing.json').exists()) {
      final saved = Map<String, dynamic>.from(
        jsonDecode(await _file('routing.json').readAsString()) as Map,
      );
      final legacy = RoutingSettings.fromMap(saved);
      _routing = legacy.directOnly();
      if (legacy.defaultAction != RouteAction.proxy ||
          legacy.rules.length != _routing.rules.length) {
        if (!await _file('routing-before-direct-config.json').exists()) {
          await _write('routing-before-direct-config.json', saved);
        }
        await _write('routing.json', _routing.toMap());
        _log('已迁移直连配置：公网默认代理，保留 ${_routing.rules.length} 条直连配置；原设置已备份。');
      }
    }
    if (!_profiles.any((v) => v.id == _manualID)) {
      _preferences['manualID'] = _profiles.firstOrNull?.id;
    }
    _selectedID = _profiles.firstOrNull?.id;
    _recovery = await platform.invoke('hasProxyBackup') as bool;
    if (_recovery) {
      _log('检测到系统代理备份，请先恢复设置。');
    }
    await _terminalState(false);
    if (await _file('run.json').exists()) await _file('run.json').delete();
    _initialized = true;
    _log('Windows 后端已就绪 · sing-box · ${_admin ? "管理员" : "普通权限"}');
    _publish();
  }

  @override
  Stream<ShadowbatState> watch() async* {
    await initialize();
    yield snapshot();
    yield* _events.stream;
  }

  ShadowbatState snapshot() => ShadowbatState({
    'platform': 'windows',
    'routing': _routing.toMap(),
    'profiles': _profiles.map(profileMap).toList(),
    'selectedID': _selectedID,
    'manualID': _manualID,
    'activeCandidateIDs': _activeIDs,
    'selectionMode': _mode,
    'state': _state,
    'stateLabel': {
      'disconnected': '未连接',
      'starting': '正在连接',
      'connected': '代理运行中',
      'stopping': '正在断开',
      'failed': '连接失败',
    }[_state],
    'connectionDescription': _mode == 'automatic'
        ? '自动选择 · ${_candidates.length} 个候选节点'
        : '手动选择 · ${_profiles.where((v) => v.id == _manualID).firstOrNull?.name ?? "请选择节点"}',
    'serviceEnabled': _enabled,
    'busy': _busy,
    'canChangeSelection': _initialized && !_enabled && !_busy,
    'canConnect':
        _initialized &&
        !_enabled &&
        !_busy &&
        !_recovery &&
        _candidates.isNotEmpty,
    'serviceUnavailable':
        _busy ||
        (!_enabled && (!_initialized || _recovery || _candidates.isEmpty)),
    'systemProxyEnabled': _systemActive,
    'systemProxySwitch': _enabled ? _systemActive : _flag('useSystemProxy'),
    'useSystemProxy': _flag('useSystemProxy'),
    'useTerminalProxy': _flag('useTerminalProxy'),
    'terminalProxyEnabled': _terminalActive,
    'terminalIntegrationInstalled': _flag('terminalInstalled'),
    'helperInstallation': 'ready',
    'helperLabel': '当前用户代理，无需管理员权限',
    'tunSupported': true,
    'useTun': _flag('useTun'),
    'tunEnabled': _enabled && _flag('useTun'),
    'isAdministrator': _admin,
    'recoveryNeeded': _recovery,
    'socksPort': _socks,
    'httpPort': _http,
    'testing': _testing,
    'testResult': _testResult,
    'networkAvailable': true,
    'errorMessage': _error,
    'logs': List<Map<String, dynamic>>.from(_logs),
  });
  void _publish() {
    if (_closed || !_initialized) return;
    final state = snapshot();
    _events.add(state);
    unawaited(
      platform
          .invoke('updateTray', {
            'stateLabel': state.stateLabel,
            'state': state.state,
            'serviceEnabled': _enabled,
            'systemProxy': state.systemProxySwitch,
            'terminalProxy': _flag('useTerminalProxy'),
            'useTun': _flag('useTun'),
            'busy': _busy,
            'serviceUnavailable': state.serviceUnavailable,
            'canChangeSelection': state.canChangeSelection,
            'connectionDescription': state.description,
            'selectionMode': _mode,
            'manualID': _manualID,
            'profiles': _profiles.map(profileMap).toList(),
            'recoveryNeeded': _recovery,
            'errorMessage': state.error,
          })
          .catchError((Object _) => null),
    );
  }

  void _log(String text) {
    // Never emit the credential-bearing run configuration.
    _logs.add({
      'id': _id(),
      'date': DateTime.now().toIso8601String(),
      'text': text,
    });
    if (_logs.length > 500) _logs.removeRange(0, _logs.length - 500);
  }

  Future<void> _write(String name, Object contents) async {
    final temporary = _file('$name.tmp');
    await temporary.writeAsString(jsonEncode(contents), flush: true);
    await platform.invoke('secureFile', {'path': temporary.path});
    await temporary.rename(_file(name).path);
  }

  Future<void> _savePreferences() => _write('preferences.json', _preferences);
  void _editable() {
    if (_enabled || _busy) throw StateError('请先关闭代理服务，再修改配置。');
  }

  ServerProfile _profile(Map<String, Object?> args) => _profiles.firstWhere(
    (v) => v.id == args['id'],
    orElse: () => throw StateError('节点不存在。'),
  );
  Future<void> _commandQueue = Future<void>.value();
  @override
  Future<Object?> command(String name, [Map<String, Object?>? arguments]) {
    if (name == 'quit') return _quitting ??= _requestQuit();
    if (_quitting != null && name != 'snapshot') {
      return Future<Object?>.error(StateError('应用正在退出。'));
    }
    if ([
      'snapshot',
      'password',
      'selectProfile',
      'dismissError',
      'clearLogs',
      'testConnection',
      'resolveRoutingTarget',
    ].contains(name)) {
      return _executeCommand(name, arguments);
    }
    final work = _commandQueue.then((_) => _executeCommand(name, arguments));
    _commandQueue = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return work;
  }

  Future<Object?> _requestQuit() async {
    _timer?.cancel();
    try {
      // This UI-only native operation must precede queued connection/cleanup work.
      await platform.invoke('beginShutdown');
      await _commandQueue;
      return await _executeCommand('quit');
    } catch (_) {
      _quitting = null;
      await platform.invoke('cancelShutdown');
      if (!_closed && _state == 'connected') {
        _timer = Timer.periodic(
          const Duration(milliseconds: 300),
          (_) => unawaited(_poll()),
        );
      }
      rethrow;
    }
  }

  Future<Object?> _executeCommand(
    String name, [
    Map<String, Object?>? arguments,
  ]) async {
    await initialize();
    final args = arguments ?? {};
    try {
      switch (name) {
        case 'snapshot':
          return snapshot();
        case 'resolveRoutingTarget':
          return await resolveRoutingTarget(args['target'] as String);
        case 'saveRouting':
          _editable();
          final policy = RoutingSettings.fromMap(
            Map<String, dynamic>.from(args),
          ).directOnly();
          await _write('routing.json', policy.toMap());
          _routing = policy;
        case 'setService':
          if (_busy) return null;
          if (args['value'] == true) {
            await _connect();
          } else {
            await _disconnect();
          }
        case 'setSelectionMode':
          _editable();
          if (!['automatic', 'manual'].contains(args['value'])) {
            throw StateError('未知节点选择模式。');
          }
          _preferences['selectionMode'] = args['value'];
          await _savePreferences();
        case 'setManualNode':
          _editable();
          if (args['id'] != null) _profile(args);
          _preferences['manualID'] = args['id'];
          await _savePreferences();
        case 'selectProfile':
          _selectedID = args['id'] as String?;
        case 'password':
          return await platform.invoke('readPassword', {
            'id': _profile(args).id,
          });
        case 'saveProfile':
          _editable();
          final id = args['id'] as String? ?? _id();
          final profile = ServerProfile.fromMap({...args, 'id': id});
          final password = args['password'] as String;
          validateProfile(profile, password);
          final before =
              await platform.invoke('readPassword', {'id': id}) as String?;
          await platform.invoke('savePassword', {
            'id': id,
            'password': password,
          });
          final updated = [..._profiles.where((v) => v.id != id), profile];
          try {
            await _write('profiles.json', updated.map(profileMap).toList());
          } catch (_) {
            await platform.invoke(
              before == null ? 'deletePassword' : 'savePassword',
              {'id': id, 'password': ?before},
            );
            rethrow;
          }
          _profiles = updated;
          _selectedID = id;
          _preferences['manualID'] ??= id;
          await _savePreferences();
          _log('已保存节点「${profile.name}」。');
        case 'deleteProfile':
          _editable();
          final profile = _profile(args);
          final before = await platform.invoke('readPassword', {
            'id': profile.id,
          }) as String?;
          await platform.invoke('deletePassword', {'id': profile.id});
          final updated = _profiles.where((v) => v.id != profile.id).toList();
          try {
            await _write('profiles.json', updated.map(profileMap).toList());
          } catch (_) {
            if (before != null) {
              await platform.invoke('savePassword', {
                'id': profile.id,
                'password': before,
              });
            }
            rethrow;
          }
          _profiles = updated;
          if (_manualID == profile.id) {
            _preferences['manualID'] = updated.firstOrNull?.id;
          }
          if (_selectedID == profile.id) _selectedID = updated.firstOrNull?.id;
          await _savePreferences();
        case 'setParticipation':
          _editable();
          final profile = _profile(args);
          final updated = _profiles
              .map(
                (v) => v.id == profile.id
                    ? ServerProfile.fromMap({
                        ...profileMap(v),
                        'participatesInAutomaticSelection': args['value'],
                      })
                    : v,
              )
              .toList();
          await _write('profiles.json', updated.map(profileMap).toList());
          _profiles = updated;
        case 'setPorts':
          _editable();
          final socks = args['socks'] as int, http = args['http'] as int;
          if (socks < 1024 ||
              socks > 65535 ||
              http < 1024 ||
              http > 65535 ||
              socks == http) {
            throw StateError('本地端口应为 1024–65535，且不能相同。');
          }
          _preferences.addAll({'socksPort': socks, 'httpPort': http});
          await _savePreferences();
        case 'setTun':
          _editable();
          _preferences['useTun'] = args['value'] as bool;
          await _savePreferences();
        case 'restartElevated':
          _editable();
          await platform.invoke('restartElevated');
          await close();
          await platform.invoke('quit');
        case 'setSystemProxy':
          if (_busy) return null;
          final enabled = args['value'] as bool;
          if (_state == 'connected') {
            await _systemProxy(enabled);
          }
          _preferences['useSystemProxy'] = enabled;
          await _savePreferences();
        case 'setTerminalProxy':
          if (_busy) return null;
          final enabled = args['value'] as bool;
          if (enabled && !_flag('terminalInstalled')) await _installTerminal();
          if (_state == 'connected') await _terminalState(enabled);
          _preferences['useTerminalProxy'] = enabled;
          await _savePreferences();
        case 'recoverSystemProxy':
          await _systemProxy(false);
        case 'installTerminalIntegration':
          await _installTerminal();
        case 'copyActivationCommand':
          await Clipboard.setData(
            ClipboardData(
              text:
                  ". '${_file('terminal-proxy.ps1').path.replaceAll("'", "''")}'",
            ),
          );
        case 'testConnection':
          await _testConnection();
        case 'refreshHelper':
          _admin = await platform.invoke('isAdministrator') as bool;
        case 'clearLogs':
          _logs.clear();
        case 'dismissError':
          _error = null;
        case 'quit':
          await _disconnect();
          await close();
          await platform.invoke('quit');
        default:
          throw StateError('Windows 不支持此操作：$name');
      }
      return null;
    } catch (e) {
      _error = _message(e);
      rethrow;
    } finally {
      _publish();
    }
  }

  Future<void> _connect() async {
    if (_enabled || _busy || _recovery) throw StateError('请先停止服务或恢复系统代理。');
    if (_flag('useTun') && !_admin) {
      throw StateError('TUN 隧道需要管理员权限，请在设置中以管理员身份重启。');
    }
    _busy = true;
    _state = 'starting';
    _error = null;
    _testResult = null;
    _publish();
    final generation = ++_generation;
    try {
      final candidates = _candidates;
      final passwords = <String, String>{};
      for (final v in candidates) {
        passwords[v.id] =
            await platform.invoke('readPassword', {'id': v.id}) as String? ??
            '';
      }
      final config = singBoxConfig(
        profiles: candidates,
        passwords: passwords,
        socksPort: _socks,
        httpPort: _http,
        tun: _flag('useTun'),
        routing: _routing,
        testURL: probeURL,
      );
      await _write('run.json', config);
      _logFile = _file('core.log').path;
      await _file('core.log').writeAsString('');
      _logOffset = 0;
      await platform.invoke('startCore', {
        'config': _file('run.json').path,
        'log': _logFile,
        'executable': _core,
      });
      _timer = Timer.periodic(
        const Duration(milliseconds: 300),
        (_) => _poll(),
      );
      var ready = false;
      for (var i = 0; i < 80; i++) {
        final status = Map<String, dynamic>.from(
          await platform.invoke('coreStatus') as Map,
        );
        if (status['running'] != true) throw StateError('代理内核启动失败，请查看连接日志。');
        try {
          final a = await Socket.connect(
            '127.0.0.1',
            _socks,
            timeout: const Duration(milliseconds: 100),
          );
          a.destroy();
          final b = await Socket.connect(
            '127.0.0.1',
            _http,
            timeout: const Duration(milliseconds: 100),
          );
          b.destroy();
          ready = true;
          break;
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      if (!ready) throw StateError('代理内核启动超时。');
      if (_flag('useSystemProxy')) await _systemProxy(true);
      if (_flag('useTerminalProxy')) await _terminalState(true);
      if (generation != _generation) throw StateError('连接已取消。');
      _activeIDs = candidates.map((v) => v.id).toList();
      _state = 'connected';
      _log(
        _flag('useTun')
            ? 'TUN 隧道与本地 HTTP/SOCKS5 代理已就绪。局域网保持直连。'
            : '本地 HTTP/SOCKS5 代理已就绪。',
      );
    } catch (e) {
      var restored = true;
      try {
        await _systemProxy(false);
      } catch (_) {
        _recovery = true;
        restored = false;
      }
      if (restored) {
        await _terminalState(false);
        await _stopCore();
        _state = 'failed';
      } else {
        // Keep the listener available while Windows may still point at it.
        final status = await platform.invoke('coreStatus') as Map;
        final running = status['running'] == true;
        _state = running ? 'connected' : 'failed';
        _activeIDs = running ? _candidates.map((v) => v.id).toList() : [];
        _log('系统代理恢复失败，请重试恢复或断开。');
      }
      _error = _message(e);
      _log('连接失败：${_message(e)}');
      rethrow;
    } finally {
      _busy = false;
      _publish();
    }
  }

  Future<void> _stopCore() async {
    _timer?.cancel();
    _timer = null;
    await platform.invoke('stopCore');
    await _readCoreLogs();
    if (await _file('run.json').exists()) await _file('run.json').delete();
    _activeIDs = [];
  }

  Future<void> _disconnect() async {
    if (_busy) throw StateError('服务正在切换，请稍后再试。');
    _busy = true;
    _state = 'stopping';
    ++_generation;
    _publish();
    try {
      // Restore proxy before stopping the listener; failed restore keeps core alive.
      await _systemProxy(false);
      await _terminalState(false);
      await _stopCore();
      _state = 'disconnected';
      _log('已断开连接。');
    } catch (e) {
      _recovery = true;
      _state = _activeIDs.isNotEmpty ? 'connected' : 'failed';
      rethrow;
    } finally {
      _busy = false;
      _publish();
    }
  }

  Future<void> _systemProxy(bool enabled) async {
    final conflicts = await platform.invoke(
      enabled ? 'enableSystemProxy' : 'restoreSystemProxy',
      {'http': _http},
    );
    _systemActive = enabled;
    _recovery = false;
    if (enabled) {
      _log('Windows 当前用户系统代理已开启。');
    } else if (conflicts == true) {
      _log('系统代理已由其他程序修改，已保留其设置。');
    }
  }

  Future<void> _readCoreLogs() async {
    if (_logFile.isEmpty) return;
    final file = File(_logFile);
    if (!await file.exists()) return;
    final handle = await file.open();
    late List<int> bytes;
    try {
      final length = await handle.length();
      if (length < _logOffset) _logOffset = 0;
      if (length == _logOffset) return;
      await handle.setPosition(_logOffset);
      bytes = await handle.read(min(length - _logOffset, 1024 * 1024));
    } finally {
      await handle.close();
    }
    final end = bytes.lastIndexOf(10);
    if (end < 0) return;
    final text = utf8.decode(bytes.sublist(0, end + 1), allowMalformed: true);
    _logOffset += end + 1;
    for (final line in text.split('\n').where((v) => v.trim().isNotEmpty)) {
      _log(line.trim());
    }
  }

  Future<void> _poll() async {
    if (_polling || _closed || _quitting != null) return;
    _polling = true;
    try {
      await _readCoreLogs();
      final status = Map<String, dynamic>.from(
        await platform.invoke('coreStatus') as Map,
      );
      if (status['running'] != true && _state == 'connected' && !_busy) {
        _state = 'failed';
        _activeIDs = [];
        _error = '代理内核意外退出（${status['exitCode']}）。';
        await _terminalState(false);
        try {
          await _systemProxy(false);
        } catch (_) {
          _recovery = true;
        }
        await _stopCore();
      }
      _publish();
    } catch (e) {
      _error = _message(e);
      _publish();
    } finally {
      _polling = false;
    }
  }

  Future<void> _testConnection() async {
    if (_state != 'connected' || _testing) return;
    _testing = true;
    _testResult = null;
    _publish();
    final generation = _generation, watch = Stopwatch()..start();
    final client = HttpClient();
    client.findProxy = (_) => 'PROXY 127.0.0.1:$_http';
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .getUrl(Uri.parse(probeURL))
          .timeout(const Duration(seconds: 12));
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      await response.drain<void>().timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      if (generation == _generation) {
        _testResult = '连接测试成功，耗时 ${watch.elapsedMilliseconds} ms。';
      }
    } catch (e) {
      if (generation == _generation) _testResult = '测试失败：${_message(e)}';
    } finally {
      client.close(force: true);
      _testing = false;
      if (_testResult != null) _log(_testResult!);
      _publish();
    }
  }

  Future<void> _terminalState(bool enabled) async {
    await _write('terminal-proxy.json', {
      'enabled': enabled,
      'appPID': pid,
      'corePID': enabled ? await platform.invoke('corePID') : 0,
      'socks': _socks,
      'http': _http,
    });
    _terminalActive = enabled;
  }

  // Windows PowerShell 5 interprets UTF-8 without a BOM as the ANSI code page.
  Future<void> _writePowerShell(File file, String text) => file
      .writeAsBytes([0xef, 0xbb, 0xbf, ...utf8.encode(text)], flush: true)
      .then((_) {});

  String _decodePowerShell(List<int> bytes) {
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff))) {
      final little = bytes[0] == 0xff;
      return String.fromCharCodes([
        for (var i = 2; i + 1 < bytes.length; i += 2)
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
      ]);
    }
    final offset =
        bytes.length >= 3 &&
            bytes[0] == 0xef &&
            bytes[1] == 0xbb &&
            bytes[2] == 0xbf
        ? 3
        : 0;
    return utf8.decode(bytes.sublist(offset));
  }

  Future<void> _installTerminal() async {
    final script = await platform.invoke('terminalScript') as String;
    await _writePowerShell(
      _file('terminal-proxy.ps1'),
      script.replaceAll(
        '__STATE_PATH__',
        _file('terminal-proxy.json').path.replaceAll("'", "''"),
      ),
    );
    for (final profilePath in _shellProfiles) {
      final profile = File(profilePath);
      await profile.parent.create(recursive: true);
      final existingBytes = await profile.exists()
          ? await profile.readAsBytes()
          : <int>[];
      final existing = _decodePowerShell(existingBytes);
      if (!existing.contains('# >>> Shadowbat terminal proxy >>>')) {
        if (await profile.exists()) {
          await _file('profile-${_id()}.ps1.backup')
              .writeAsBytes(existingBytes);
        }
        final loader =
            "\n# >>> Shadowbat terminal proxy >>>\n. '${_file('terminal-proxy.ps1').path.replaceAll("'", "''")}'\n# <<< Shadowbat terminal proxy <<<\n";
        await _writePowerShell(profile, existing + loader);
      }
    }
    _preferences['terminalInstalled'] = true;
    await _savePreferences();
    _log('PowerShell 终端集成已安装，已有终端请执行激活命令。');
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _events.close();
  }
}
