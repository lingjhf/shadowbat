import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../domain/routing/routing_settings.dart';

typedef SaveRouting = Future<void> Function(RoutingSettings policy);
typedef ResolveRouting = Future<List<String>> Function(String target);

class RoutingPage extends StatefulWidget {
  const RoutingPage({
    super.key,
    required this.policy,
    required this.editable,
    required this.onSave,
    required this.onResolve,
  });
  final RoutingSettings policy;
  final bool editable;
  final SaveRouting onSave;
  final ResolveRouting onResolve;
  @override
  State<RoutingPage> createState() => _RoutingPageState();
}

class _RoutingPageState extends State<RoutingPage> {
  final target = TextEditingController();
  String? error;
  String? result;
  bool saving = false, testing = false;
  bool get editable => widget.editable && !saving;
  @override
  void dispose() {
    target.dispose();
    super.dispose();
  }

  Future<void> save(List<RoutingRule> rules) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.onSave(RoutingSettings(rules: rules).directOnly());
      if (mounted) setState(() => result = null);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
      rethrow;
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> change(List<RoutingRule> rules) async {
    try {
      await save(rules);
    } catch (_) {
      /* Displayed above the rules. */
    }
  }

  Future<void> edit([RoutingRule? rule]) async {
    await showDialog<void>(
      context: context,
      builder: (context) => RoutingRuleEditor(
        rule: rule,
        onSave: (value) async {
          final rules = [...widget.policy.rules];
          final index = rules.indexWhere((r) => r.id == value.id);
          if (index < 0) {
            rules.add(value);
          } else {
            rules[index] = value;
          }
          await save(rules);
        },
      ),
    );
  }

  Future<void> test({bool resolve = false}) async {
    setState(() {
      testing = true;
      error = null;
    });
    try {
      final addresses = resolve
          ? await widget.onResolve(target.text)
          : <String>[];
      final decision = widget.policy.directOnly().test(
        target.text,
        resolvedAddresses: addresses,
      );
      final provisional = decision.needsAddresses
          ? '暂定结果（需要解析域名后确认 IP 直连配置）\n'
          : '';
      if (mounted) {
        setState(
          () => result =
              '$provisional${decision.action.label} · ${decision.reason}${addresses.isEmpty ? '' : '\n系统 DNS：${addresses.join(', ')}'}',
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        '直连配置',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text('公网流量默认使用当前代理节点；仅以下启用的目标直连。'),
      const SizedBox(height: 6),
      Text(
        widget.editable ? '保存后在下次连接生效。' : '请先断开连接，再修改直连配置。',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 12),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('未配置的公网目标始终走代理。'),
              const SizedBox(height: 8),
              const Text('局域网、回环与链路本地地址默认直连。', style: TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: editable ? () => edit() : null,
        icon: const Icon(Icons.add, size: 18),
        label: const Text('添加直连目标'),
      ),
      if (widget.policy.rules.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text('尚未添加直连目标，公网流量默认走代理。'),
        ),
      for (final (index, rule) in widget.policy.rules.indexed)
        Card(
          key: ValueKey('rule-${rule.id}'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(rule.type.label)),
                    CupertinoSwitch(
                      value: rule.enabled,
                      onChanged: editable
                          ? (enabled) {
                              final rules = [...widget.policy.rules];
                              rules[index] = rule.withEnabled(enabled);
                              change(rules);
                            }
                          : null,
                    ),
                  ],
                ),
                Text(
                  rule.target,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: '编辑直连目标',
                      onPressed: editable ? () => edit(rule) : null,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                    ),
                    IconButton(
                      tooltip: '删除直连目标',
                      onPressed: editable
                          ? () => change(
                              widget.policy.rules
                                  .where((r) => r.id != rule.id)
                                  .toList(),
                            )
                          : null,
                      icon: const Icon(Icons.delete_outline, size: 18),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 20),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('测试目标'),
              const SizedBox(height: 8),
              TextField(
                controller: target,
                key: const ValueKey('routing-test-target'),
                decoration: const InputDecoration(hintText: '域名或 IP，不包含协议和路径'),
                onChanged: (_) => setState(() => result = null),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: testing ? null : () => test(),
                    child: const Text('测试匹配'),
                  ),
                  TextButton(
                    onPressed: testing ? null : () => test(resolve: true),
                    child: const Text('解析并测试'),
                  ),
                ],
              ),
              if (testing) const LinearProgressIndicator(),
              if (result != null) SelectableText(result!),
              const SizedBox(height: 8),
              const Text(
                '解析测试使用系统 DNS；实际连接可能得到不同 IP，请结合内核日志确认。系统代理仅覆盖进入代理的流量；Windows TUN 可接管更多应用流量。',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class RoutingRuleEditor extends StatefulWidget {
  const RoutingRuleEditor({super.key, this.rule, required this.onSave});
  final RoutingRule? rule;
  final Future<void> Function(RoutingRule) onSave;
  @override
  State<RoutingRuleEditor> createState() => _RoutingRuleEditorState();
}

class _RoutingRuleEditorState extends State<RoutingRuleEditor> {
  late final target = TextEditingController(text: widget.rule?.target ?? '');
  late RouteMatch type = widget.rule?.type ?? RouteMatch.domain;
  bool saving = false;
  String? error;
  @override
  void dispose() {
    target.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final rule = RoutingRule.fromMap({
        'id':
            widget.rule?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        'type': type.name,
        'target': target.text,
        'action': RouteAction.direct.name,
        'enabled': widget.rule?.enabled ?? true,
      });
      await widget.onSave(rule);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.rule == null ? '添加直连目标' : '编辑直连目标'),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<RouteMatch>(
              initialValue: type,
              decoration: const InputDecoration(labelText: '匹配类型'),
              items: [
                for (final type in RouteMatch.values)
                  DropdownMenuItem(value: type, child: Text(type.label)),
              ],
              onChanged: saving
                  ? null
                  : (value) {
                      if (value != null) setState(() => type = value);
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: target,
              key: const ValueKey('routing-rule-target'),
              enabled: !saving,
              decoration: InputDecoration(
                labelText: '目标',
                hintText: switch (type) {
                  RouteMatch.domain => 'api.example.com',
                  RouteMatch.suffix => 'example.com',
                  RouteMatch.ip => '203.0.113.10',
                  RouteMatch.cidr => '192.168.1.0/24',
                },
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: saving ? null : submit,
        child: Text(saving ? '保存中…' : '保存'),
      ),
    ],
  );
}

Future<void> previewSaveRouting(RoutingSettings policy) async {}
Future<List<String>> previewResolveRouting(String target) async => [
  '203.0.113.10',
];
@Preview(name: '直连配置', size: Size(360, 720))
Widget previewRoutingPage() => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: RoutingPage(
        policy: const RoutingSettings(
          rules: [
            RoutingRule(
              id: 'preview',
              type: RouteMatch.suffix,
              target: 'example.com',
              action: RouteAction.direct,
            ),
          ],
        ),
        editable: true,
        onSave: previewSaveRouting,
        onResolve: previewResolveRouting,
      ),
    ),
  ),
);
