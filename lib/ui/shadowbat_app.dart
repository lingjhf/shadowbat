import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/models/shadowbat_state.dart';
import 'shadowbat_view_model.dart';
import 'server_editor.dart';
import 'routing_page.dart';

const accent = Color(0xff007aff);

class ShadowbatApp extends StatelessWidget {
  const ShadowbatApp({super.key, required this.model});
  final ShadowbatViewModel model;
  ThemeData _theme(Brightness brightness) => ThemeData(
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      primary: accent,
    ),
    scaffoldBackgroundColor: brightness == Brightness.light
        ? const Color(0xfff4f4f6)
        : const Color(0xff202023),
    fontFamily: null,
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 13),
      bodySmall: TextStyle(fontSize: 11),
    ),
    visualDensity: VisualDensity.compact,
  );
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Shadowbat',
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    home: ShadowbatWindow(model: model),
  );
}

class ShadowbatWindow extends StatefulWidget {
  const ShadowbatWindow({super.key, required this.model});
  final ShadowbatViewModel model;
  @override
  State<ShadowbatWindow> createState() => _ShadowbatWindowState();
}

class _ShadowbatWindowState extends State<ShadowbatWindow> {
  int page = 0;
  ShadowbatViewModel get model => widget.model;
  ShadowbatState get s => model.state;
  Future<void> edit([ServerProfile? profile]) async {
    final password = profile == null ? '' : await model.password(profile);
    if (!mounted || password == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) =>
          ServerEditor(model: model, profile: profile, password: password),
    );
  }

  Future<void> delete(ServerProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除节点「${profile.name}」？'),
        content: const Text('节点配置及其保存的密码将一并删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await model.command('deleteProfile', {'id': profile.id});
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 36, 18, 12),
            child: Row(
              children: [
                Image.asset('assets/shadowbat.png', width: 32, height: 32),
                const SizedBox(width: 10),
                const Text(
                  'Shadowbat',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '打开连接日志',
                  onPressed: showLogs,
                  icon: const Icon(Icons.notes, size: 19),
                ),
              ],
            ),
          ),
          Expanded(
            child: model.loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                    children: [
                      if (model.error != null) ...[
                        panel(
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                model.error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                              TextButton(
                                onPressed: model.dismissError,
                                child: const Text('确定'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (s.recoveryNeeded) ...[
                        panel(
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '⚠ 系统代理需要恢复',
                                style: TextStyle(color: Colors.orange),
                              ),
                              const SizedBox(height: 8),
                              const Text('恢复原设置后即可重新连接。'),
                              TextButton(
                                onPressed: s.busy
                                    ? null
                                    : () => model.command('recoverSystemProxy'),
                                child: const Text('恢复设置'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      ...switch (page) {
                        0 => connection(),
                        1 => nodes(),
                        2 => [
                          RoutingPage(
                            policy: s.routing,
                            editable: s.canChangeSelection,
                            onSave: (policy) async {
                              if (!await model.command(
                                'saveRouting',
                                policy.toMap(),
                              )) {
                                throw StateError(model.error ?? '直连配置保存失败。');
                              }
                            },
                            onResolve: (target) async {
                              return (await model.repository.command(
                                'resolveRoutingTarget',
                                {'target': target},
                              ) as List).cast<String>();
                            },
                          ),
                        ],
                        _ => settings(),
                      },
                    ],
                  ),
          ),
          const Divider(height: 1),
          SizedBox(
            height: 66,
            child: Row(
              children: [
                for (final (index, icon, label) in [
                  (0, Icons.power_settings_new, '连接'),
                  (1, CupertinoIcons.square_stack_3d_up, '节点'),
                  (2, CupertinoIcons.arrow_branch, '直连配置'),
                  (3, CupertinoIcons.slider_horizontal_3, '设置'),
                ])
                  Expanded(
                    child: Semantics(
                      selected: page == index,
                      button: true,
                      child: InkWell(
                        onTap: () => setState(() => page = index),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              icon,
                              size: 21,
                              color: page == index ? accent : Colors.grey,
                            ),
                            const SizedBox(height: 5),
                            Text(
                              label,
                              style: TextStyle(
                                fontSize: 10,
                                color: page == index ? accent : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget panel(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).brightness == Brightness.light
          ? Colors.white
          : const Color(0xff2c2c2e),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.grey.withValues(alpha: .12)),
    ),
    child: child,
  );
  Widget caption(String text) => Text(
    text,
    style: TextStyle(
      fontSize: 11,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
  Widget toggle(
    String title,
    IconData icon,
    bool value,
    String status,
    void Function(bool)? onChanged,
  ) => Row(
    children: [
      Icon(icon, size: 21, color: Colors.grey),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 3),
            caption(status),
          ],
        ),
      ),
      Semantics(
        label: title,
        child: Transform.scale(
          scale: .8,
          alignment: Alignment.centerRight,
          child: CupertinoSwitch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: accent,
          ),
        ),
      ),
    ],
  );
  String proxyStatus(bool enabled, bool desired) => enabled
      ? '已启用'
      : desired
      ? '等待服务启动'
      : '已关闭';

  List<Widget> connection() => [
    Center(
      child: Semantics(
        label: s.serviceEnabled ? '关闭代理服务' : '开启代理服务',
        button: true,
        child: SizedBox(
          width: 116,
          height: 116,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (s.serviceEnabled ? accent : Colors.grey).withValues(
                alpha: .08,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: s.serviceEnabled
                      ? accent
                      : Theme.of(context).colorScheme.surface,
                  foregroundColor: s.serviceEnabled
                      ? Colors.white
                      : Colors.grey,
                ),
                onPressed: s.serviceUnavailable
                    ? null
                    : () => model.command('setService', {
                        'value': !s.serviceEnabled,
                      }),
                icon: s.busy
                    ? const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.power_settings_new, size: 34),
              ),
            ),
          ),
        ),
      ),
    ),
    const SizedBox(height: 10),
    Center(
      child: Text(
        s.stateLabel,
        style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
      ),
    ),
    const SizedBox(height: 8),
    Center(child: caption(s.networkAvailable ? s.description : '网络暂不可用')),
    if (s.tunSupported && s.useTun) ...[
      const SizedBox(height: 8),
      Center(child: caption('TUN 隧道模式 · 局域网直连')),
    ],
    const SizedBox(height: 20),
    panel(
      Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: IgnorePointer(
              ignoring: !s.canChangeSelection,
              child: CupertinoSlidingSegmentedControl<String>(
                groupValue: s.selectionMode,
                children: const {
                  'automatic': Text('自动选择'),
                  'manual': Text('手动选择'),
                },
                onValueChanged: (value) {
                  if (value != null && s.canChangeSelection) {
                    model.command('setSelectionMode', {'value': value});
                  }
                },
              ),
            ),
          ),
          if (s.selectionMode == 'manual') ...[
            const SizedBox(height: 10),
            DropdownButton<String>(
              isExpanded: true,
              value: s.profiles.any((p) => p.id == s.manualID)
                  ? s.manualID
                  : null,
              hint: const Text('请选择固定节点'),
              items: s.profiles
                  .map(
                    (p) => DropdownMenuItem(
                      value: p.id,
                      child: Text(p.name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: s.canChangeSelection
                  ? (id) => model.command('setManualNode', {'id': id})
                  : null,
            ),
          ],
        ],
      ),
    ),
    const SizedBox(height: 16),
    panel(
      Column(
        children: [
          toggle(
            '系统代理',
            CupertinoIcons.globe,
            s.systemProxySwitch,
            proxyStatus(s.systemProxyEnabled, s.useSystemProxy),
            s.busy
                ? null
                : (value) => model.command('setSystemProxy', {'value': value}),
          ),
          const Divider(height: 24),
          toggle(
            '终端代理',
            CupertinoIcons.chevron_left_slash_chevron_right,
            s.useTerminalProxy,
            proxyStatus(s.terminalProxyEnabled, s.useTerminalProxy),
            s.busy
                ? null
                : (value) =>
                      model.command('setTerminalProxy', {'value': value}),
          ),
        ],
      ),
    ),
    const SizedBox(height: 12),
    if (s.profiles.isEmpty)
      Center(
        child: FilledButton.icon(
          onPressed: s.canChangeSelection
              ? () {
                  setState(() => page = 1);
                  edit();
                }
              : null,
          icon: const Icon(Icons.add, size: 17),
          label: const Text('添加第一个节点'),
        ),
      )
    else ...[
      if (s.selectionMode == 'automatic' &&
          !s.profiles.any((p) => p.participates))
        Center(child: caption('请启用至少一个候选节点')),
      Center(
        child: TextButton.icon(
          onPressed: s.state == 'connected' && !s.testing
              ? () => model.command('testConnection')
              : null,
          icon: const Icon(Icons.bolt, size: 17),
          label: Text(s.testing ? '正在测试' : '测试连接'),
        ),
      ),
      if (s.testResult != null) Center(child: caption(s.testResult!)),
    ],
  ];

  List<Widget> nodes() => [
    Row(
      children: [
        const Text(
          '节点',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        caption('${s.profiles.length}'),
        const Spacer(),
        TextButton.icon(
          onPressed: s.canChangeSelection ? () => edit() : null,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('添加'),
        ),
      ],
    ),
    if (s.profiles.isEmpty)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 60),
        child: Column(
          children: [
            const Icon(
              CupertinoIcons.square_stack_3d_up,
              size: 32,
              color: Colors.grey,
            ),
            const SizedBox(height: 14),
            const Text('还没有节点', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            caption('添加服务器配置即可开始连接'),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: s.canChangeSelection ? () => edit() : null,
              child: const Text('添加节点'),
            ),
          ],
        ),
      ),
    for (final p in s.profiles) ...[
      panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => model.command('selectProfile', {
                      'id': s.selectedID == p.id ? null : p.id,
                    }),
                    child: Row(
                      children: [
                        const Icon(
                          CupertinoIcons.square_stack_3d_up,
                          size: 22,
                          color: Colors.grey,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                p.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${p.host}:${p.port}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (s.activeCandidateIDs.contains(p.id))
                          const Icon(
                            Icons.check_circle,
                            color: accent,
                            size: 18,
                          ),
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '管理节点 ${p.name}',
                  icon: const Icon(Icons.more_horiz, size: 18),
                  onSelected: (value) {
                    if (value == 'edit') edit(p);
                    if (value == 'delete') delete(p);
                    if (value == 'participation') {
                      model.command('setParticipation', {
                        'id': p.id,
                        'value': !p.participates,
                      });
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'edit',
                      enabled: s.canChangeSelection,
                      child: const Text('编辑节点'),
                    ),
                    PopupMenuItem(
                      value: 'participation',
                      enabled: s.canChangeSelection,
                      child: Text('${p.participates ? '✓ ' : ''}参与自动选择'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      enabled: s.canChangeSelection,
                      child: const Text(
                        '删除节点',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (s.selectedID == p.id) ...[
              const Divider(height: 24),
              SelectableText(
                p.method,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              const SizedBox(height: 8),
              toggle(
                '参与自动选择',
                Icons.auto_awesome,
                p.participates,
                '',
                s.canChangeSelection
                    ? (value) => model.command('setParticipation', {
                        'id': p.id,
                        'value': value,
                      })
                    : null,
              ),
              TextButton.icon(
                onPressed: s.canChangeSelection ? () => edit(p) : null,
                icon: const Icon(Icons.edit, size: 14),
                label: const Text('编辑节点'),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
    ],
    if (s.profiles.isNotEmpty)
      Center(child: caption(s.serviceEnabled ? '关闭代理服务后可编辑节点' : '浏览节点不会切换代理')),
  ];

  List<Widget> settings() => [
    if (s.tunSupported) ...[
      const Text('TUN 隧道', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            toggle(
              'TUN 隧道',
              Icons.vpn_lock,
              s.useTun,
              s.tunEnabled
                  ? '已启用'
                  : s.useTun
                  ? '下次启动时启用'
                  : '已关闭',
              s.canChangeSelection
                  ? (value) => model.command('setTun', {'value': value})
                  : null,
            ),
            const SizedBox(height: 8),
            caption('虚拟网卡接管 TCP / UDP 与 DNS；局域网保持直连。开启前请关闭代理服务。'),
            if (s.isWindows && !s.isAdministrator)
              TextButton(
                onPressed: s.canChangeSelection
                    ? () => model.command('restartElevated')
                    : null,
                child: const Text('以管理员身份重启'),
              ),
            caption(
              s.isWindows
                  ? s.isAdministrator
                        ? '已具备管理员权限'
                        : 'TUN 需要管理员授权；普通代理无需提升权限。'
                  : '连接时由 macOS 请求管理员授权，无需重启应用。断开或退出后自动清理隧道。',
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
    ],
    const Text('本地端口', style: TextStyle(fontWeight: FontWeight.w600)),
    const SizedBox(height: 10),
    panel(
      Column(
        children: [
          portRow('SOCKS5', s.socksPort),
          const Divider(height: 24),
          portRow('HTTP / HTTPS', s.httpPort),
        ],
      ),
    ),
    const SizedBox(height: 16),
    const Text('系统代理', style: TextStyle(fontWeight: FontWeight.w600)),
    const SizedBox(height: 10),
    panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(s.helperLabel),
              const Spacer(),
              IconButton(
                tooltip: '刷新授权状态',
                onPressed: s.busy ? null : () => model.command('refreshHelper'),
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          if (s.helperInstallation != 'ready')
            TextButton(
              onPressed: s.busy
                  ? null
                  : () => model.command(
                      s.helperInstallation == 'needsApproval'
                          ? 'openApprovalSettings'
                          : 'installProxyHelper',
                    ),
              child: Text(
                s.helperInstallation == 'needsApproval' ? '前往系统授权' : '安装并授权',
              ),
            ),
          caption(
            s.isWindows
                ? '设置 Windows 当前用户系统代理；关闭服务或退出时恢复原设置。'
                : '首次开启需要系统授权，之后无需重复输入密码。',
          ),
        ],
      ),
    ),
    const SizedBox(height: 16),
    const Text('终端代理', style: TextStyle(fontWeight: FontWeight.w600)),
    const SizedBox(height: 10),
    panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          caption(
            s.terminalInstalled
                ? '新终端自动生效，已有终端首次执行一次激活命令。'
                : s.isWindows
                ? '安装 PowerShell 集成后，代理环境变量随全局开关自动同步。'
                : '安装 zsh 集成后，代理环境变量随全局开关自动同步。',
          ),
          TextButton(
            onPressed: s.busy
                ? null
                : () async {
                    final copying = s.terminalInstalled;
                    final success = await model.command(
                      copying
                          ? 'copyActivationCommand'
                          : 'installTerminalIntegration',
                    );
                    if (success && copying && mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('激活命令已复制')));
                    }
                  },
            child: Text(s.terminalInstalled ? '复制激活命令' : '安装终端集成'),
          ),
          caption('已运行的命令不会切换代理。'),
        ],
      ),
    ),
    const SizedBox(height: 10),
    TextButton.icon(
      onPressed: showLogs,
      icon: const Icon(Icons.notes, size: 17),
      label: const Text('连接日志'),
    ),
    Center(child: caption('关闭窗口后继续在状态栏运行')),
  ];
  Widget portRow(String title, int port) => Row(
    children: [
      Text(title),
      const Spacer(),
      InkWell(
        onTap: s.canChangeSelection ? editPorts : null,
        child: Container(
          width: 82,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.withValues(alpha: .25)),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            '$port',
            style: TextStyle(color: s.canChangeSelection ? null : Colors.grey),
          ),
        ),
      ),
    ],
  );
  Future<void> editPorts() async {
    final socks = TextEditingController(text: '${s.socksPort}'),
        http = TextEditingController(text: '${s.httpPort}');
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('本地端口'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: socks,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'SOCKS5'),
              ),
              TextField(
                controller: http,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'HTTP / HTTPS'),
              ),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                final a = int.tryParse(socks.text), b = int.tryParse(http.text);
                if (a == null ||
                    b == null ||
                    a < 1024 ||
                    b < 1024 ||
                    a > 65535 ||
                    b > 65535 ||
                    a == b) {
                  update(() => error = '端口应为 1024–65535，且不能相同。');
                  return;
                }
                final saved = await model.command('setPorts', {
                  'socks': a,
                  'http': b,
                });
                if (!context.mounted) return;
                if (saved) {
                  Navigator.pop(context);
                } else {
                  update(() => error = model.error);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    // Dialog transition may still paint the fields; release after it finishes.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    socks.dispose();
    http.dispose();
  }

  void showLogs() {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 320,
          height: 440,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: ListenableBuilder(
              listenable: model,
              builder: (context, _) => Column(
                children: [
                  Row(
                    children: [
                      const Text(
                        '连接日志',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => model.command('clearLogs'),
                        child: const Text('清空'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: s.logs.isEmpty
                        ? Center(child: caption('连接后会在这里显示日志。'))
                        : SelectionArea(
                            child: ListView.builder(
                              reverse: true,
                              itemCount: s.logs.length,
                              itemBuilder: (context, i) {
                                final log = s.logs[s.logs.length - 1 - i];
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      caption(
                                        log.date.toIso8601String().substring(
                                          11,
                                          19,
                                        ),
                                      ),
                                      Text(
                                        log.text,
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
