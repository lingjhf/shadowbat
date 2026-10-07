import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadowbat/domain/routing/routing_settings.dart';
import 'package:shadowbat/ui/routing_page.dart';

void main() {
  late ValueNotifier<RoutingSettings> policy;
  late List<RoutingSettings> saves;
  var failSave = false;
  setUp(() {
    policy = ValueNotifier(const RoutingSettings());
    saves = [];
    failSave = false;
  });
  tearDown(() => policy.dispose());
  Future<void> mount(WidgetTester tester, {bool editable = true}) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ValueListenableBuilder<RoutingSettings>(
              valueListenable: policy,
              builder: (context, value, child) => RoutingPage(
                policy: value,
                editable: editable,
                onSave: (next) async {
                  if (failSave) throw StateError('磁盘写入失败');
                  saves.add(next);
                  policy.value = next;
                },
                onResolve: (target) async => ['198.18.0.123'],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('invalid rules stay in editor; normalized rules persist', (
    tester,
  ) async {
    await mount(tester);
    await tapVisible(tester, find.text('添加直连目标'));
    await tester.enterText(
      find.byKey(const ValueKey('routing-rule-target')),
      'https://example.com',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saves, isEmpty);
    expect(find.textContaining('请填写有效域名'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('routing-rule-target')),
      ' Example.COM. ',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saves.single.rules.single.target, 'example.com');
    expect(saves.single.rules.single.action, RouteAction.direct);
    expect(saves.single.defaultAction, RouteAction.proxy);
    expect(find.byType(RoutingRuleEditor), findsNothing);
    expect(find.text('example.com'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'failed persistence keeps editing available and explains failure',
    (tester) async {
      await mount(tester);
      failSave = true;
      await tapVisible(tester, find.text('添加直连目标'));
      await tester.enterText(
        find.byKey(const ValueKey('routing-rule-target')),
        'example.com',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(RoutingRuleEditor), findsOneWidget);
      expect(find.textContaining('磁盘写入失败'), findsWidgets);
      expect(policy.value.rules, isEmpty);
    },
  );
  testWidgets(
    'direct targets can be edited disabled and deleted without priority controls',
    (tester) async {
      policy.value = const RoutingSettings(
        rules: [
          RoutingRule(
            id: 'one',
            type: RouteMatch.domain,
            target: 'api.example.com',
            action: RouteAction.direct,
          ),
        ],
      );
      await mount(tester);
      expect(find.byTooltip('下移规则'), findsNothing);
      expect(find.byTooltip('上移规则'), findsNothing);
      expect(find.byKey(const ValueKey('routing-default')), findsNothing);
      expect(policy.value.test('api.example.com').action, RouteAction.direct);
      await tapVisible(tester, find.byTooltip('编辑直连目标'));
      expect(find.byType(DropdownButtonFormField<RouteAction>), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('routing-rule-target')),
        'edited.example.com',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(policy.value.rules.single.target, 'edited.example.com');
      final toggle = find.byType(CupertinoSwitch);
      await tapVisible(tester, toggle);
      expect(policy.value.rules.single.enabled, isFalse);
      expect(policy.value.test('edited.example.com').action, RouteAction.proxy);
      await tapVisible(tester, find.byTooltip('删除直连目标'));
      expect(policy.value.rules, isEmpty);
    },
  );
  testWidgets(
    'connected state locks edits but target testing remains available',
    (tester) async {
      await mount(tester, editable: false);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '添加直连目标'))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const ValueKey('routing-default')), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('routing-test-target')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('routing-test-target')),
        '192.168.1.2',
      );
      await tapVisible(tester, find.text('测试匹配'));
      expect(find.textContaining('局域网默认直连'), findsOneWidget);
      expect(saves, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
