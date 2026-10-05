import 'package:flutter/services.dart';

typedef WindowsAction = Future<void> Function(
  String name,
  Map<String, Object?> args,
);

abstract interface class WindowsPlatform {
  Future<Object?> invoke(String name, [Map<String, Object?>? args]);
  void setActionHandler(WindowsAction handler);
}

class NativeWindowsPlatform implements WindowsPlatform {
  static const channel = MethodChannel('com.lingj.shadowbat/windows');
  @override
  Future<Object?> invoke(String name, [Map<String, Object?>? args]) =>
      channel.invokeMethod<Object?>(name, args);
  @override
  void setActionHandler(WindowsAction handler) => channel.setMethodCallHandler(
    (call) => handler(
      call.method,
      Map<String, Object?>.from(call.arguments as Map? ?? {}),
    ),
  );
}
