class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.method,
    required this.participates,
  });
  factory ServerProfile.fromMap(Map<String, dynamic> map) => ServerProfile(
    id: map['id'] as String,
    name: map['name'] as String,
    host: map['host'] as String,
    port: map['port'] as int,
    method: map['method'] as String,
    participates: map['participatesInAutomaticSelection'] as bool? ?? true,
  );
  final String id, name, host, method;
  final int port;
  final bool participates;
  static const methods = [
    'aes-128-gcm',
    'aes-256-gcm',
    'chacha20-ietf-poly1305',
    '2022-blake3-aes-128-gcm',
    '2022-blake3-aes-256-gcm',
    '2022-blake3-chacha20-poly1305',
  ];
}

class ConnectionLog {
  ConnectionLog.fromMap(Map<String, dynamic> map)
    : date = DateTime.parse(map['date'] as String).toLocal(),
      text = map['text'] as String;
  final DateTime date;
  final String text;
}

/// Immutable native snapshot; credentials are fetched only for the editor.
class ShadowbatState {
  ShadowbatState(Map<String, dynamic> values)
    : _values = Map.unmodifiable(values),
      profiles = List.unmodifiable(
        (values['profiles'] as List? ?? []).map(
          (p) => ServerProfile.fromMap(Map<String, dynamic>.from(p as Map)),
        ),
      ),
      logs = List.unmodifiable(
        (values['logs'] as List? ?? []).map(
          (p) => ConnectionLog.fromMap(Map<String, dynamic>.from(p as Map)),
        ),
      ),
      activeCandidateIDs = Set.unmodifiable(
        (values['activeCandidateIDs'] as List? ?? []).cast<String>(),
      );
  final Map<String, dynamic> _values;
  final List<ServerProfile> profiles;
  final List<ConnectionLog> logs;
  final Set<String> activeCandidateIDs;
  bool _flag(String key) => _values[key] as bool? ?? false;
  String? get selectedID => _values['selectedID'] as String?;
  String? get manualID => _values['manualID'] as String?;
  String get selectionMode =>
      _values['selectionMode'] as String? ?? 'automatic';
  String get state => _values['state'] as String? ?? 'disconnected';
  String get stateLabel => _values['stateLabel'] as String? ?? '未连接';
  String get description =>
      _values['connectionDescription'] as String? ?? '自动选择 · 0 个候选节点';
  String get helperInstallation =>
      _values['helperInstallation'] as String? ?? 'notInstalled';
  String get helperLabel => _values['helperLabel'] as String? ?? '尚未安装';
  String? get error => _values['errorMessage'] as String?;
  String? get testResult => _values['testResult'] as String?;
  int get socksPort => _values['socksPort'] as int? ?? 1081;
  int get httpPort => _values['httpPort'] as int? ?? 1087;
  bool get busy => _flag('busy');
  bool get serviceEnabled => _flag('serviceEnabled');
  bool get serviceUnavailable => _flag('serviceUnavailable');
  bool get canChangeSelection => _flag('canChangeSelection');
  bool get systemProxyEnabled => _flag('systemProxyEnabled');
  bool get systemProxySwitch => _flag('systemProxySwitch');
  bool get useSystemProxy => _flag('useSystemProxy');
  bool get useTerminalProxy => _flag('useTerminalProxy');
  bool get terminalProxyEnabled => _flag('terminalProxyEnabled');
  bool get terminalInstalled => _flag('terminalIntegrationInstalled');
  bool get recoveryNeeded => _flag('recoveryNeeded');
  bool get testing => _flag('testing');
  bool get isWindows => _values['platform'] == 'windows';
  bool get tunSupported => _flag('tunSupported');
  bool get useTun => _flag('useTun');
  bool get tunEnabled => _flag('tunEnabled');
  bool get isAdministrator => _flag('isAdministrator');
  bool get networkAvailable => _values['networkAvailable'] as bool? ?? true;
}
