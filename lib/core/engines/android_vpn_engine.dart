import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../services/log_service.dart';
import '../vpn_engine.dart';
import 'mihomo_engine_base.dart';

/// Android engine: the core is the in-process native library behind a
/// `VpnService`, driven from Dart over a [MethodChannel].
///
/// Android has no separate core process, so the "controller" is a loopback HTTP
/// listener that the native side starts, and the standard [MethodChannel] is
/// used only for the operations that genuinely belong to the platform:
/// requesting the VPN consent dialog, installing the profile and tearing the
/// service down. Every piece of VPN logic (server list, latency, selection,
/// traffic) still comes from the shared mihomo controller, which is what keeps
/// the UI identical across platforms.
class AndroidVpnEngine extends MihomoEngineBase {
  AndroidVpnEngine({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('com.scaleguard.app/core');

  final MethodChannel _channel;

  bool _nativeAvailable = true;

  /// Last summary handed to [setTunnelSummary], carried into `startCore` so the
  /// very first notification already shows the location instead of appearing
  /// bare and being corrected a second later.
  String? _tunnelSummary;

  @override
  String get platformName => 'Android (mihomo, VpnService)';

  /// Android always requires the user to accept the system VPN prompt.
  @override
  bool get requiresTunnelPermission => true;

  /// The VpnService is established in both modes: "system proxy" only adds the
  /// core's HTTP proxy to the network that is already there, so the profile has
  /// to stay a tunnel profile — the native side creates its TUN from the file
  /// descriptor it receives and expects the config to describe one.
  @override
  bool get configAlwaysTargetsTun => true;

  /// The native service owns the TUN file descriptor, so a virtual adapter is
  /// the only mode; there is no system-proxy concept to fall back to.
  @override
  bool get supportsTunMode => true;

  @override
  Future<void> initialize() async {
    try {
      await _channel.invokeMethod<bool>('isSupported');
      _nativeAvailable = true;
    } on MissingPluginException {
      _nativeAvailable = false;
    } on PlatformException {
      _nativeAvailable = false;
    }
  }

  @override
  Future<bool> requestTunnelPermission() async {
    if (!_nativeAvailable) return false;
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      _nativeAvailable = false;
      return false;
    }
  }

  @override
  Future<String> writeConfig(String config) async {
    // The native service owns its private directory: the profile is handed over
    // as a string so the file never has to pass through the app sandbox.
    return config;
  }

  @override
  Future<String> launchCore({
    required String configPath,
    required int controllerPort,
    required String secret,
    required String logLevel,
  }) async {
    if (!_nativeAvailable) {
      throw StateError(
        'Нативное ядро недоступно. Пересоберите приложение: '
        'модуль mihomo-service не зарегистрирован.',
      );
    }
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'startCore',
      {
        'config': configPath,
        'controllerUrl': 'http://127.0.0.1:$controllerPort',
        'controllerPort': controllerPort,
        'secret': secret,
        'logLevel': logLevel,
        // Both modes keep the VpnService: the service decides from this whether
        // applications should also be handed the core's HTTP proxy.
        'mode': startOptions?.mode.name ?? 'tun',
        if (_tunnelSummary != null && _tunnelSummary!.isNotEmpty)
          'notificationText': _tunnelSummary,
      },
    );
    final event = result == null
        ? null
        : result.map((key, value) => MapEntry(key.toString(), value));
    LogService.instance.log('engine', 'native start result: $event');
    final baseUrl = event?['controllerUrl']?.toString();
    if (baseUrl == null || baseUrl.isEmpty) {
      throw StateError(
        event?['error']?.toString() ?? 'Нативное ядро не вернуло адрес контроллера',
      );
    }
    return baseUrl;
  }

  @override
  Future<void> onCoreStarted(EngineStartOptions options, int mixedPort) async {
    // Traffic capture is owned by the VpnService, which the native side has
    // already established by the time the controller answers; the only thing
    // left is telling Android which DNS server and routes to use, which the
    // service derives from the profile it received.
  }

  @override
  Future<void> onBeforeCoreStop() async {
    // Nothing to restore on Android: closing the tunnel drops the routes.
  }

  /// Loads the native core ahead of the first connect, so pressing "Подключить"
  /// does not have to pay for process creation and library mapping.
  Future<void> warmUp() async {
    if (!_nativeAvailable) return;
    try {
      await _channel.invokeMethod<bool>('warmUp');
    } on PlatformException {
      // A warm-up that does not happen only costs time.
    } on MissingPluginException {
      _nativeAvailable = false;
    }
  }

  /// The tunnel the native service is running or restoring, if there is one.
  ///
  /// Closing the window does not stop the tunnel, and neither does a relaunch:
  /// this is how the new window finds the core that is still up.
  Future<AndroidRunningTunnel?> runningTunnel() async {
    if (!_nativeAvailable) return null;
    try {
      final map =
          await _channel.invokeMapMethod<String, dynamic>('tunnelStatus');
      if (map == null) return null;
      final state = '${map['state'] ?? ''}';
      if (state != 'running' && state != 'starting') return null;
      final port = (map['controllerPort'] as num?)?.toInt() ?? 0;
      if (port <= 0) return null;
      return AndroidRunningTunnel(
        state: state,
        baseUrl: 'http://127.0.0.1:$port',
        secret: '${map['secret'] ?? ''}',
        mixedPort: (map['mixedPort'] as num?)?.toInt() ?? 0,
        startedAtMillis: (map['startedAt'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      _nativeAvailable = false;
      return null;
    }
  }

  @override
  Future<void> setTunnelSummary(String? summary) async {
    if (summary == _tunnelSummary) return;
    _tunnelSummary = summary;
    if (!_nativeAvailable || summary == null || summary.isEmpty) return;
    if (!snapshot.isRunning) return; // Carried into the next startCore instead.
    try {
      await _channel.invokeMethod<void>('updateNotification', {'text': summary});
    } on PlatformException {
      // A notification that lags behind is cosmetic; the tunnel is not.
    } on MissingPluginException {
      _nativeAvailable = false;
    }
  }

  @override
  Future<void> shutdownCore() async {
    if (!_nativeAvailable) return;
    try {
      await _channel.invokeMethod<void>('stopCore');
    } on MissingPluginException {
      _nativeAvailable = false;
    } on PlatformException {
      // A stop failure must not leave the UI stuck in "disconnecting".
    }
  }

  /// Reads the native service's own traffic counters.
  ///
  /// The mihomo controller is not always reachable from the app process on
  /// Android (the service may run in a separate process), so the service
  /// exposes its counters directly; when it does not, the base class's
  /// controller polling is used instead.
  Future<Map<String, dynamic>?> fetchNativeStats() async {
    if (!_nativeAvailable) return null;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('stats');
      if (result == null) return null;
      return result.map((key, value) => MapEntry(key.toString(), value));
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    await shutdownCore();
    await super.dispose();
  }

  /// True when at least one network interface currently has an address, which
  /// is how the UI explains "no internet" separately from "no VPN".
  static Future<bool> hasNetwork() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      return interfaces.any((interface) => interface.addresses.isNotEmpty);
    } catch (_) {
      return false;
    }
  }
}

/// A tunnel that the native service is running right now.
///
/// Carries exactly what the Dart side needs to reattach: where the controller
/// listens and the secret it expects.
class AndroidRunningTunnel {
  const AndroidRunningTunnel({
    required this.state,
    required this.baseUrl,
    required this.secret,
    required this.mixedPort,
    required this.startedAtMillis,
  });

  /// `running`, or `starting` while a sticky restart is bringing the core back.
  final String state;
  final String baseUrl;
  final String secret;
  final int mixedPort;
  final int startedAtMillis;
}
