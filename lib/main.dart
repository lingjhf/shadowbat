import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'data/repositories/shadowbat_repository.dart';
import 'data/services/native_shadowbat_service.dart';
import 'ui/shadowbat_app.dart';
import 'data/windows/windows_platform.dart';
import 'data/windows/windows_repository.dart';
import 'data/windows/windows_self_test.dart';
import 'ui/shadowbat_view_model.dart';
import 'ui/tray_panel.dart';

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  if (arguments.contains('--tray-panel')) {
    runApp(const NativeTrayApp());
    return;
  }
  if (!kIsWeb &&
      defaultTargetPlatform == TargetPlatform.windows &&
      arguments.contains('--self-test')) {
    runApp(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Windows 本地隔离自检'))),
      ),
    );
    unawaited(runWindowsSelfTest(arguments, NativeWindowsPlatform()));
    return;
  }
  runApp(
    ShadowbatApp(
      model: ShadowbatViewModel(
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
            ? WindowsShadowbatRepository(NativeWindowsPlatform())
            : MacosShadowbatRepository(NativeShadowbatService()),
      ),
    ),
  );
}
