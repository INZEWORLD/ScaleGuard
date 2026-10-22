import '../vpn_engine.dart';
import 'mihomo_engine_base.dart';

/// Engine used on platforms the client does not ship a core for yet.
///
/// It reports a precise, actionable failure instead of pretending to connect,
/// so the UI can tell the user exactly what is missing rather than showing a
/// spinner that never resolves.
class UnsupportedVpnEngine extends MihomoEngineBase {
  UnsupportedVpnEngine({required this.platform, this.detail});

  final String platform;
  final String? detail;

  @override
  String get platformName => '$platform (ядро не поставляется)';

  @override
  bool get supportsTunMode => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestTunnelPermission() async => false;

  @override
  Future<String> writeConfig(String config) async => config;

  @override
  Future<String> launchCore({
    required String configPath,
    required int controllerPort,
    required String secret,
    required String logLevel,
  }) async {
    throw StateError(
      detail ??
          'Для платформы $platform ядро mihomo не собрано. '
              'См. docs/apple.md — сборка требует macOS и Xcode.',
    );
  }

  @override
  Future<void> onCoreStarted(EngineStartOptions options, int mixedPort) async {}

  @override
  Future<void> onBeforeCoreStop() async {}

  @override
  Future<void> shutdownCore() async {}
}
