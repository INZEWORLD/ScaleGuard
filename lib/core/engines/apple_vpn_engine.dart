import 'dart:io';

import 'package:flutter/services.dart';

import '../vpn_engine.dart';
import 'mihomo_engine_base.dart';

/// Apple engine: iOS and macOS.
///
/// Apple does not allow a plain application to create a tunnel. Traffic must be
/// handled by a **Network Extension** — a `NEPacketTunnelProvider` in a separate
/// process with its own memory ceiling — so the core cannot simply be linked
/// into the Flutter binary. The Dart side therefore talks to the extension over
/// a [MethodChannel], while the extension hosts the same mihomo core and the
/// same loopback controller the other platforms use.
///
/// The channel is implemented by `ios/Runner/ScaleGuardCorePlugin.swift` and
/// `ios/ScaleGuardPacketTunnel/PacketTunnelProvider.swift`; until those are
/// built on macOS the engine reports exactly what is missing instead of failing
/// silently. See `docs/apple.md` for the build procedure.
class AppleVpnEngine extends MihomoEngineBase {
  AppleVpnEngine({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('com.scaleguard.app/core');

  final MethodChannel _channel;

  bool _pluginAvailable = true;
  bool _tunnelPrepared = false;

  @override
  String get platformName => Platform.isMacOS
      ? 'macOS (mihomo, Network Extension)'
      : 'iOS (mihomo, Network Extension)';

  @override
  bool get requiresTunnelPermission => true;

  @override
  bool get supportsTunMode => true;

  @override
  Future<void> initialize() async {
    try {
      _pluginAvailable = await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      _pluginAvailable = false;
    } on PlatformException {
      _pluginAvailable = false;
    }
  }

  @override
  Future<bool> requestTunnelPermission() async {
    if (!_pluginAvailable) return false;
    try {
      // The extension installs the VPN profile here, which is what triggers
      // the system consent prompt on iOS.
      _tunnelPrepared =
          await _channel.invokeMethod<bool>('prepareTunnel') ?? false;
      return _tunnelPrepared;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      _pluginAvailable = false;
      return false;
    }
  }

  @override
  Future<String> writeConfig(String config) async {
    // The extension owns its container: the profile travels as a string so the
    // app never writes into the extension's directory directly.
    return config;
  }

  @override
  Future<String> launchCore({
    required String configPath,
    required int controllerPort,
    required String secret,
    required String logLevel,
  }) async {
    if (!_pluginAvailable) {
      throw StateError(_missingPluginMessage);
    }
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'startCore',
      {
        'config': configPath,
        'controllerPort': controllerPort,
        'secret': secret,
        'logLevel': logLevel,
      },
    );
    final event = result == null
        ? null
        : result.map((key, value) => MapEntry(key.toString(), value));
    final baseUrl = event?['controllerUrl']?.toString();
    if (baseUrl == null || baseUrl.isEmpty) {
      throw StateError(
        event?['error']?.toString() ?? 'Расширение не вернуло адрес контроллера',
      );
    }
    return baseUrl;
  }

  @override
  Future<void> onCoreStarted(EngineStartOptions options, int mixedPort) async {
    // The packet tunnel is already up by the time the controller answers, so
    // the app process has nothing left to configure.
  }

  @override
  Future<void> onBeforeCoreStop() async {
    // Dropping the packet tunnel removes the routes and DNS settings.
  }

  @override
  Future<void> shutdownCore() async {
    if (!_pluginAvailable) return;
    try {
      await _channel.invokeMethod<void>('stopCore');
    } on MissingPluginException {
      _pluginAvailable = false;
    } on PlatformException {
      // Keep the UI responsive even if the extension already exited.
    }
  }

  @override
  Future<void> dispose() async {
    await shutdownCore();
    await super.dispose();
  }

  String get _missingPluginMessage => Platform.isMacOS
      ? 'Сетевой плагин ScaleGuard не собран. Соберите приложение на macOS — '
          'см. docs/apple.md.'
      : 'Расширение ScaleGuard Packet Tunnel недоступно: оно собирается только '
          'на macOS (Xcode) — см. docs/apple.md.';
}
