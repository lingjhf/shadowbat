import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/repositories/shadowbat_repository.dart';
import '../domain/models/shadowbat_state.dart';

class ShadowbatViewModel extends ChangeNotifier {
  ShadowbatViewModel(this.repository) {
    _subscription = repository.watch().listen(
      (value) {
        state = value;
        loading = false;
        notifyListeners();
      },
      onError: (Object error) {
        loading = false;
        localError = error is MissingPluginException
            ? '代理后端支持 macOS 和 Windows，请使用对应桌面平台启动。'
            : _message(error);
        notifyListeners();
      },
    );
  }
  final ShadowbatRepository repository;
  late final StreamSubscription<ShadowbatState> _subscription;
  ShadowbatState state = ShadowbatState({});
  bool loading = true;
  String? localError;
  String? get error => localError ?? state.error;
  String _message(Object error) => error is PlatformException
      ? error.message ?? error.code
      : error.toString();
  Future<bool> command(String name, [Map<String, Object?>? arguments]) async {
    try {
      await repository.command(name, arguments);
      localError = null;
      return true;
    } catch (error) {
      localError = _message(error);
      return false;
    } finally {
      notifyListeners();
    }
  }

  Future<String?> password(ServerProfile profile) async {
    try {
      return await repository.command('password', {'id': profile.id})
              as String? ??
          '';
    } catch (error) {
      localError = _message(error);
      notifyListeners();
      return null;
    }
  }

  Future<void> dismissError() async {
    localError = null;
    await command('dismissError');
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
