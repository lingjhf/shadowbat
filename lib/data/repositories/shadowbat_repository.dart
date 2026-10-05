import '../../domain/models/shadowbat_state.dart';
import '../services/native_shadowbat_service.dart';

abstract interface class ShadowbatRepository {
  Stream<ShadowbatState> watch();
  Future<Object?> command(String name, [Map<String, Object?>? arguments]);
}

class MacosShadowbatRepository implements ShadowbatRepository {
  MacosShadowbatRepository(this.service);
  final NativeShadowbatService service;
  @override
  Stream<ShadowbatState> watch() => service.watch().map(ShadowbatState.new);
  @override
  Future<Object?> command(String name, [Map<String, Object?>? arguments]) =>
      service.command(name, arguments);
}
