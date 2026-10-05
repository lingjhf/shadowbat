import 'package:flutter/services.dart';

class NativeShadowbatService {
  static const _commands = MethodChannel('com.lingj.shadowbat/commands');
  static const _events = EventChannel('com.lingj.shadowbat/state');
  Stream<Map<String, dynamic>> watch() => _events.receiveBroadcastStream().map(
    (event) => Map<String, dynamic>.from(event as Map),
  );
  Future<Object?> command(String name, [Map<String, Object?>? arguments]) =>
      _commands.invokeMethod<Object?>(name, arguments);
}
