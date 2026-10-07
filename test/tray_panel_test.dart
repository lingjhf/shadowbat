import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadowbat/ui/tray_panel.dart';

void main() {
  late ValueNotifier<Map<String, dynamic>> snapshot;
  late List<(String, Map<String, Object?>)> calls;
  late int hidden;
  setUp(() {
    snapshot = ValueNotifier({
      'canChangeSelection': true,
      'serviceUnavailable': true,
      'profiles': [
        {'id': 'node-1', 'name': '香港节点'},
      ],
    });
    calls = [];
    hidden = 0;
  });
  tearDown(() => snapshot.dispose());
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 483);
    tester.view.devicePixelRatio = 1.25;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ValueListenableBuilder<Map<String, dynamic>>(
        valueListenable: snapshot,
        builder: (context, values, child) => TrayApp(
          state: TrayState(values),
          onCommand: (name, arguments) => calls.add((name, arguments)),
          onHide: () => hidden++,
        ),
      ),
    );
    if (snapshot.value['busy'] == true) {
      await tester.pump(const Duration(milliseconds: 300));
    } else {
      await tester.pumpAndSettle();
    }
  }

  CupertinoSwitch toggle(WidgetTester tester, String method) =>
      tester.widget(find.byKey(ValueKey(method)));

  testWidgets('disabled service and system toggle follow shared snapshots', (
    tester,
  ) async {
    await mount(tester);
    expect(toggle(tester, 'setService').onChanged, isNull);
    await tester.tap(find.byKey(const ValueKey('setSystemProxy')));
    expect(calls.single.$1, 'setSystemProxy');
    expect(calls.single.$2, {'value': true});
    // The view waits for the authoritative main repository's state.
    expect(toggle(tester, 'setSystemProxy').value, isFalse);
    snapshot.value = {
      ...snapshot.value,
      'systemProxy': true,
      'stateLabel': '已连接',
    };
    await tester.pumpAndSettle();
    expect(toggle(tester, 'setSystemProxy').value, isTrue);
    expect(find.text('已连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('manual mode shows nodes and clearing forwards null', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('手动选择'));
    await tester.pumpAndSettle();
    expect(calls.single.$1, 'setSelectionMode');
    expect(calls.single.$2, {'value': 'manual'});
    snapshot.value = {
      ...snapshot.value,
      'selectionMode': 'manual',
      'manualID': 'node-1',
    };
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual-node')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('请选择节点').last);
    await tester.pumpAndSettle();
    expect(calls.last.$1, 'setManualNode');
    expect(calls.last.$2, {'id': null});
    expect(tester.takeException(), isNull);
  });
  testWidgets('busy snapshots prevent repeated mutations and show progress', (
    tester,
  ) async {
    snapshot.value = {
      ...snapshot.value,
      'busy': true,
      'canChangeSelection': false,
      'serviceUnavailable': true,
    };
    await mount(tester);
    for (final method in [
      'setService',
      'setSystemProxy',
      'setTerminalProxy',
      'setTun',
    ]) {
      expect(toggle(tester, method).onChanged, isNull);
    }
    await tester.tap(find.text('手动选择'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, isEmpty);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Escape closes dropdown first then dismisses the panel', (
    tester,
  ) async {
    snapshot.value = {...snapshot.value, 'selectionMode': 'manual'};
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('manual-node')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(hidden, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(hidden, 1);
  });
  testWidgets('recovery errors and footer actions fit the compact panel', (
    tester,
  ) async {
    snapshot.value = {
      ...snapshot.value,
      'recoveryNeeded': true,
      'errorMessage': '连接失败，请检查节点设置',
    };
    await mount(tester);
    expect(find.text('连接失败，请检查节点设置'), findsOneWidget);
    await tester.ensureVisible(find.text('恢复系统代理'));
    await tester.tap(find.text('恢复系统代理'));
    await tester.pumpAndSettle();
    expect(calls.last.$1, 'recoverSystemProxy');
    await tester.ensureVisible(find.text('打开 Shadowbat'));
    await tester.tap(find.text('打开 Shadowbat'));
    expect(calls.last.$1, 'showMainWindow');
    await tester.tap(find.text('退出'));
    expect(calls.last.$1, 'quit');
    expect(tester.takeException(), isNull);
  });
}
