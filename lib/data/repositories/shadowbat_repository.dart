import '../../domain/models/shadowbat_state.dart';
import '../services/native_shadowbat_service.dart';
import '../services/routing_resolver.dart';
import '../../domain/routing/routing_settings.dart';

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
  Future<Object?> command(String name, [Map<String, Object?>? arguments]) {
    if (name == 'resolveRoutingTarget') {
      return resolveRoutingTarget(arguments!['target'] as String);
    }
    if (name == 'saveRouting') {
      return service.command(
        name,
        RoutingSettings.fromMap(Map<String, dynamic>.from(arguments!))
            .directOnly()
            .toMap(),
      );
    }
    return service.command(name, arguments);
  }
}
