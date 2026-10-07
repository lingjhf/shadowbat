import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';

/// The tray renders a read-only snapshot; all commands go to the main repository.
class TrayState {
  TrayState(Map<String, dynamic> values) : values = Map.unmodifiable(values);
  final Map<String, dynamic> values;
  bool flag(String key, [bool fallback = false]) =>
      values[key] as bool? ?? fallback;
  String get label => values['stateLabel'] as String? ?? '未连接';
  String get mode => values['selectionMode'] as String? ?? 'automatic';
  String? get manualID => values['manualID'] as String?;
  String get description =>
      values['connectionDescription'] as String? ?? '自动选择 · 0 个候选节点';
  String? get error => values['errorMessage'] as String?;
  List<Map<String, dynamic>> get profiles => (values['profiles'] as List? ?? [])
      .map((v) => Map<String, dynamic>.from(v as Map))
      .toList();
}

typedef TrayCommand = void Function(
  String name,
  Map<String, Object?> arguments,
);

class NativeTrayApp extends StatefulWidget {
  const NativeTrayApp({super.key});
  @override
  State<NativeTrayApp> createState() => _NativeTrayAppState();
}

class _NativeTrayAppState extends State<NativeTrayApp> {
  static const channel = MethodChannel('com.lingj.shadowbat/tray');
  TrayState state = TrayState({});
  @override
  void initState() {
    super.initState();
    channel.setMethodCallHandler((call) async {
      if (call.method == 'stateChanged' && mounted) {
        setState(
          () => state = TrayState(
            Map<String, dynamic>.from(call.arguments as Map),
          ),
        );
      }
    });
    _load();
  }

  Future<void> _load() async {
    final snapshot = await channel.invokeMapMethod<String, dynamic>('snapshot');
    if (mounted && snapshot != null) {
      setState(() => state = TrayState(snapshot));
    }
  }

  @override
  void dispose() {
    channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TrayApp(
    state: state,
    onHide: () => channel.invokeMethod<void>('hide'),
    onCommand: (name, args) {
      channel.invokeMethod<void>('command', {'name': name, 'arguments': args});
    },
  );
}

class TrayApp extends StatelessWidget {
  const TrayApp({
    super.key,
    required this.state,
    required this.onCommand,
    required this.onHide,
  });
  final TrayState state;
  final TrayCommand onCommand;
  final VoidCallback onHide;
  ThemeData theme(Brightness brightness) => ThemeData(
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff007aff),
      brightness: brightness,
    ),
    scaffoldBackgroundColor: brightness == Brightness.dark
        ? const Color(0xff272729)
        : const Color(0xfffafafa),
    visualDensity: VisualDensity.compact,
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 13),
      bodySmall: TextStyle(fontSize: 11),
    ),
  );
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    home: TrayContent(state: state, onCommand: onCommand, onHide: onHide),
  );
}

class TrayContent extends StatelessWidget {
  const TrayContent({
    super.key,
    required this.state,
    required this.onCommand,
    required this.onHide,
  });
  final TrayState state;
  final TrayCommand onCommand;
  final VoidCallback onHide;
  Widget toggle(
    BuildContext context,
    String title,
    IconData icon,
    String field,
    String method,
    bool disabled,
  ) => SizedBox(
    height: 38,
    child: Row(
      children: [
        Icon(
          icon,
          size: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(title)),
        Semantics(
          label: title,
          child: SizedBox(
            width: 42,
            height: 28,
            child: FittedBox(
              child: CupertinoSwitch(
                key: ValueKey(method),
                value: state.flag(field),
                onChanged: disabled
                    ? null
                    : (value) => onCommand(method, {'value': value}),
              ),
            ),
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final busy = state.flag('busy');
    final editable = state.flag('canChangeSelection');
    final profiles = state.profiles;
    final selected = profiles.any((p) => p['id'] == state.manualID)
        ? state.manualID!
        : '';
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): onHide},
        child: Focus(
          autofocus: true,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Text(
                      'Shadowbat',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: CupertinoActivityIndicator(radius: 6),
                      ),
                    Text(
                      state.label,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 8),
                toggle(
                  context,
                  '代理服务',
                  CupertinoIcons.power,
                  'serviceEnabled',
                  'setService',
                  state.flag('serviceUnavailable', true),
                ),
                toggle(
                  context,
                  '系统代理',
                  CupertinoIcons.globe,
                  'systemProxy',
                  'setSystemProxy',
                  busy,
                ),
                toggle(
                  context,
                  '终端代理',
                  CupertinoIcons.chevron_left_slash_chevron_right,
                  'terminalProxy',
                  'setTerminalProxy',
                  busy,
                ),
                toggle(
                  context,
                  'TUN 隧道',
                  CupertinoIcons.shield,
                  'useTun',
                  'setTun',
                  !editable,
                ),
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 12),
                CupertinoSlidingSegmentedControl<String>(
                  groupValue: state.mode,
                  disabledChildren: editable
                      ? const {}
                      : const {'automatic', 'manual'},
                  children: const {
                    'automatic': Padding(
                      padding: EdgeInsets.symmetric(vertical: 3),
                      child: Text('自动选择', style: TextStyle(fontSize: 12)),
                    ),
                    'manual': Padding(
                      padding: EdgeInsets.symmetric(vertical: 3),
                      child: Text('手动选择', style: TextStyle(fontSize: 12)),
                    ),
                  },
                  onValueChanged: (value) {
                    if (editable && value != null) {
                      onCommand('setSelectionMode', {'value': value});
                    }
                  },
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 32,
                  child: state.mode == 'manual'
                      ? DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: colors.outlineVariant),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: DropdownButton<String>(
                              key: const ValueKey('manual-node'),
                              value: selected,
                              isExpanded: true,
                              underline: const SizedBox.shrink(),
                              style: Theme.of(context).textTheme.bodyMedium,
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('请选择节点'),
                                ),
                                ...profiles.map(
                                  (p) => DropdownMenuItem(
                                    value: p['id'] as String,
                                    child: Text(
                                      p['name'] as String,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                              onChanged: editable
                                  ? (id) => onCommand('setManualNode', {
                                      'id': id == '' ? null : id,
                                    })
                                  : null,
                            ),
                          ),
                        )
                      : Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            state.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 12),
                if (state.flag('recoveryNeeded'))
                  TextButton.icon(
                    onPressed: busy
                        ? null
                        : () => onCommand('recoverSystemProxy', {}),
                    icon: const Icon(
                      CupertinoIcons.exclamationmark_triangle,
                      size: 16,
                    ),
                    label: const Text('恢复系统代理'),
                  ),
                if (state.error case final error? when error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: colors.error),
                    ),
                  ),
                const Divider(height: 1),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 30),
                        foregroundColor: colors.onSurface,
                      ),
                      onPressed: () => onCommand('showMainWindow', {}),
                      icon: const Icon(CupertinoIcons.macwindow, size: 16),
                      label: const Text(
                        '打开 Shadowbat',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(36, 30),
                        foregroundColor: colors.onSurface,
                      ),
                      onPressed: busy ? null : () => onCommand('quit', {}),
                      child: const Text('退出', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void previewTrayCommand(String name, Map<String, Object?> arguments) {}
void previewHideTray() {}

@Preview(
  name: 'Windows tray · light',
  size: Size(320, 386),
  brightness: Brightness.light,
)
@Preview(
  name: 'Windows tray · dark',
  size: Size(320, 386),
  brightness: Brightness.dark,
)
Widget previewTray() => TrayApp(
  state: TrayState({
    'stateLabel': '未连接',
    'canChangeSelection': true,
    'serviceUnavailable': true,
    'selectionMode': 'automatic',
    'systemProxy': true,
  }),
  onCommand: previewTrayCommand,
  onHide: previewHideTray,
);
