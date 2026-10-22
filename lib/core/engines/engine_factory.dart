import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'android_vpn_engine.dart';
import 'apple_vpn_engine.dart';
import 'mihomo_engine_base.dart';
import 'unsupported_vpn_engine.dart';
import 'windows_vpn_engine.dart';

/// Creates the engine that matches the platform this binary runs on.
///
/// The rest of the application only ever sees [MihomoEngineBase], which is why
/// one UI can drive three very different tunnel implementations.
///
/// This is the only place that knows about Flutter's directory services: the
/// engines themselves stay free of Flutter imports so they can be driven from a
/// plain Dart entry point (see `tool/e2e_tunnel.dart`).
Future<MihomoEngineBase> createPlatformEngine() async {
  if (Platform.isWindows) {
    return WindowsVpnEngine(dataDirectory: await _windowsCoreDirectory());
  }
  if (Platform.isAndroid) return AndroidVpnEngine();
  if (Platform.isIOS || Platform.isMacOS) return AppleVpnEngine();
  if (Platform.isLinux) return UnsupportedVpnEngine(platform: 'Linux');
  return UnsupportedVpnEngine(platform: Platform.operatingSystem);
}

/// Per-user directory for the generated profile and the core's own files.
///
/// `path_provider` is authoritative, but it depends on the Flutter engine being
/// bound; when it is not (a headless run, a test, a misconfigured startup) the
/// engine falls back to `%APPDATA%\ScaleGuard\core` rather than failing to
/// connect at all.
Future<Directory?> _windowsCoreDirectory() async {
  try {
    final base = await getApplicationSupportDirectory();
    final directory = Directory('${base.path}${Platform.pathSeparator}core');
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    return directory;
  } catch (_) {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    return Directory(
      '$appData${Platform.pathSeparator}ScaleGuard'
      '${Platform.pathSeparator}core',
    );
  }
}
