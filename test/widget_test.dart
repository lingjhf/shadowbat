import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadowbat/data/repositories/shadowbat_repository.dart';
import 'package:shadowbat/domain/models/shadowbat_state.dart';
import 'package:shadowbat/ui/shadowbat_app.dart';
import 'package:shadowbat/ui/shadowbat_view_model.dart';

class FakeRepository implements ShadowbatRepository {
  final events = StreamController<ShadowbatState>.broadcast();
  final calls = <(String, Map<String, Object?>?)>[];
  final values = <String, dynamic>{
    'canChangeSelection': true,
    'serviceUnavailable': true,
    'profiles': <Map<String, dynamic>>[],
  };
  bool failSave = false;
  void emit() => events.add(ShadowbatState(values));
  @override
  Stream<ShadowbatState> watch() async* {
    yield ShadowbatState(values);
    yield* events.stream;
  }

  @override
  Future<Object?> command(String name, [Map<String, Object?>? args]) async {
    calls.add((name, args));
    switch (name) {
      case 'saveProfile':
        if (failSave) {
          throw PlatformException(code: 'shadowbat', message: '钥匙串写入失败');
        }
        values['profiles'] = [
          {...args!, 'id': 'node-1'}..remove('password'),
        ];
        values['serviceUnavailable'] = false;
      case 'setSelectionMode':
        values['selectionMode'] = args!['value'];
      case 'selectProfile':
        values['selectedID'] = args!['id'];
      case 'setManualNode':
        values['manualID'] = args!['id'];
      case 'password':
        return 'secret';
    }
    emit();
    return null;
  }
}

void main() {
  late FakeRepository repository;
  late ShadowbatViewModel model;
  setUp(() {
    repository = FakeRepository();
    model = ShadowbatViewModel(repository);
  });
  tearDown(() async {
    model.dispose();
    await repository.events.close();
  });
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ShadowbatApp(model: model));
    await tester.pumpAndSettle();
  }

  testWidgets('portrait navigation and node creation persist fields', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('未连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('节点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加节点'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '名称'), 'Tokyo');
    await tester.enterText(
      find.widgetWithText(TextFormField, '服务器地址'),
      'example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '密码或密钥'),
      'secret',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('Tokyo'), findsOneWidget);
    final args = repository.calls
        .firstWhere((call) => call.$1 == 'saveProfile')
        .$2!;
    expect(args['host'], 'example.com');
    expect(args['port'], 8388);
    expect(args['participatesInAutomaticSelection'], true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native tray updates refresh Flutter and lock node edits', (
    tester,
  ) async {
    await mount(tester);
    repository.values.addAll({
      'state': 'connected',
      'stateLabel': '代理运行中',
      'serviceEnabled': true,
      'canChangeSelection': false,
      'serviceUnavailable': false,
      'systemProxyEnabled': true,
      'systemProxySwitch': true,
      'connectionDescription': '自动选择 · 1 个候选节点',
      'profiles': [
        {
          'id': 'node-1',
          'name': 'Tokyo',
          'host': 'example.com',
          'port': 8388,
          'method': 'aes-256-gcm',
        },
      ],
    });
    repository.emit();
    await tester.pumpAndSettle();
    expect(find.text('代理运行中'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    await tester.tap(find.text('节点'));
    await tester.pumpAndSettle();
    final add = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '添加'),
    );
    expect(add.onPressed, isNull);
    await tester.tap(find.text('Tokyo'));
    await tester.pumpAndSettle();
    expect(repository.calls.last.$1, 'selectProfile');
    expect(repository.calls.where((c) => c.$1 == 'setService'), isEmpty);
    expect(find.text('aes-256-gcm'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed credential save keeps editor open and explains failure', (
    tester,
  ) async {
    repository.failSave = true;
    await mount(tester);
    await tester.tap(find.text('节点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加节点'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '名称'), 'Tokyo');
    await tester.enterText(
      find.widgetWithText(TextFormField, '服务器地址'),
      'example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '密码或密钥'),
      'secret',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('钥匙串写入失败'), findsWidgets);
    expect(repository.values['profiles'], isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'manual selection routes to native model; settings fit portrait window',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('手动选择'));
      await tester.pumpAndSettle();
      expect(repository.calls.last.$1, 'setSelectionMode');
      expect(repository.calls.last.$2, {'value': 'manual'});
      expect(find.text('请选择固定节点'), findsOneWidget);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('SOCKS5'), findsOneWidget);
      expect(find.text('1081'), findsOneWidget);
      expect(find.text('1087'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
