import 'package:flutter/material.dart';

import '../domain/models/shadowbat_state.dart';
import 'shadowbat_view_model.dart';

class ServerEditor extends StatefulWidget {
  const ServerEditor({
    super.key,
    required this.model,
    this.profile,
    required this.password,
  });
  final ShadowbatViewModel model;
  final ServerProfile? profile;
  final String password;
  @override
  State<ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<ServerEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.profile?.name ?? '');
  late final host = TextEditingController(text: widget.profile?.host ?? '');
  late final port = TextEditingController(
    text: '${widget.profile?.port ?? 8388}',
  );
  late final password = TextEditingController(text: widget.password);
  late String method = widget.profile?.method ?? ServerProfile.methods.first;
  late bool participates = widget.profile?.participates ?? true;
  bool saving = false;
  bool reveal = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    host.dispose();
    port.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    final saved = await widget.model.command('saveProfile', {
      if (widget.profile != null) 'id': widget.profile!.id,
      'name': name.text.trim(),
      'host': host.text.trim(),
      'port': int.parse(port.text),
      'method': method,
      'password': password.text,
      'participatesInAutomaticSelection': participates,
    });
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context);
    } else {
      setState(() {
        saving = false;
        error = widget.model.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.profile == null ? '添加节点' : '编辑节点'),
    content: SizedBox(
      width: 320,
      child: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              field(name, '名称'),
              field(host, '服务器地址'),
              TextFormField(
                controller: port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '服务器端口'),
                validator: (value) {
                  final number = int.tryParse(value ?? '');
                  return number == null || number < 1 || number > 65535
                      ? '服务器端口应为 1–65535。'
                      : null;
                },
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: method,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '加密方式'),
                items: ServerProfile.methods
                    .map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text(v, style: const TextStyle(fontSize: 11)),
                      ),
                    )
                    .toList(),
                onChanged: saving
                    ? null
                    : (value) => setState(() => method = value!),
              ),
              TextFormField(
                controller: password,
                obscureText: !reveal,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: '密码或密钥',
                  suffixIcon: IconButton(
                    tooltip: reveal ? '隐藏密码' : '显示密码',
                    onPressed: () => setState(() => reveal = !reveal),
                    icon: Icon(
                      reveal ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                    ),
                  ),
                ),
                validator: (value) =>
                    value == null || value.isEmpty ? '请填写密码或密钥。' : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('参与自动选择', style: TextStyle(fontSize: 13)),
                value: participates,
                onChanged: saving
                    ? null
                    : (value) => setState(() => participates = value),
              ),
              if (method.startsWith('2022-'))
                const Text(
                  'AEAD-2022 需要对应长度的 Base64 密钥。',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: saving ? null : save,
        child: Text(saving ? '正在保存' : '保存'),
      ),
    ],
  );
  Widget field(TextEditingController controller, String label) => TextFormField(
    controller: controller,
    autocorrect: false,
    decoration: InputDecoration(labelText: label),
    validator: (value) =>
        value == null || value.trim().isEmpty ? '请填写$label。' : null,
  );
}
