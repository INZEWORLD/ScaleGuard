import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../../services/log_service.dart';
import '../mihomo_api.dart';
import '../mihomo_config.dart';
import '../subscription_parser.dart';
import '../vpn_engine.dart';

/// Shared behaviour for every engine that drives a mihomo core.
///
/// Both the Windows sidecar process and the Android in-process service expose
/// the same RESTful controller, so state handling, latency sweeps, server
/// switching and traffic polling live here and only the core lifecycle differs.
abstract class MihomoEngineBase implements VpnCoreEngine {
  MihomoEngineBase();

  final StreamController<CoreSnapshot> _changes =
      StreamController<CoreSnapshot>.broadcast();

  CoreSnapshot _snapshot = CoreSnapshot.idle;
  MihomoApiClient? _api;
  StreamSubscription<CoreTrafficStats>? _trafficSubscription;
  Timer? _autoSelectTimer;
  List<ParsedVpnServer> _servers = const [];
  EngineStartOptions? _options;
  int? _mixedPort;
  int? _controllerPort;
  String? _secret;
  bool _disposed = false;

  @override
  CoreSnapshot get snapshot => _snapshot;

  @override
  Stream<CoreSnapshot> get changes => _changes.stream;

  MihomoApiClient? get api => _api;

  List<ParsedVpnServer> get servers => List.unmodifiable(_servers);

  /// The options the core is currently running with.
  ///
  /// Exposed to subclasses because the TUN adapter name and the mode are needed
  /// outside `start()` — for example when the adapter has to be cleaned up after
  /// the process has already gone.
  EngineStartOptions? get startOptions => _options;

  /// Path to the core binary, when the platform runs one out of process.
  ///
  /// Used by the integrity check and by the TUN driver installer, both of which
  /// have to know exactly which binary they are about to run elevated.
  String? get coreExecutablePath => null;

  List<int?> _latencies = const [];

  /// Last measured latency per server, in the same order as [servers].
  @override
  List<int?> get latencies => List.unmodifiable(_latencies);

  @override
  bool get requiresTunnelPermission => false;

  /// Mode used when the caller does not ask for a specific one.
  ///
  /// Android and iOS only have a virtual adapter, so the default is TUN;
  /// platforms that can also drive the system proxy override this to avoid
  /// requiring elevation on every launch.
  VpnTunnelMode get preferredMode => VpnTunnelMode.tun;

  /// Whether the generated profile always has to describe a tunnel.
  ///
  /// True on platforms whose proxy mode is an addition to a tunnel that exists in
  /// both modes (Android pushes the core's HTTP proxy into the network the
  /// VpnService already created): the core is handed a file descriptor either
  /// way, so it must not be given a profile that has no `tun` section.
  bool get configAlwaysTargetsTun => false;

  /// Addresses the profile puts on the core's tunnel adapter.
  ///
  /// Read before the profile is written, because the profile carries them.
  /// `null` keeps them out of the profile, which is what every platform except
  /// Windows wants: there the OS owns the interface. Windows overrides this
  /// because the core's own defaults are also every other Clash-family client's
  /// defaults, and Windows refuses to assign an address another adapter already
  /// holds ("set ipv4 address: The object already exists") — the tunnel then has
  /// no interface at all while the client shows a connection carrying nothing.
  Future<TunAddresses?> chooseTunAddresses() async => null;

  /// Why the core cannot come up, or `null` while it is still starting.
  ///
  /// Platforms that run the core as a child process override this: when the
  /// core rejects the profile it exits at once and prints the reason, which is
  /// far more useful than the controller timeout that follows.
  String? get coreStartupFailure => null;

  TunAddresses? _tunAddresses;

  // -------------------------------------------------------------------------
  // Template methods implemented per platform
  // -------------------------------------------------------------------------

  /// Writes [config] where the core will read it and returns its absolute path.
  Future<String> writeConfig(String config);

  /// Boots the core and returns the controller base URL once it answers.
  Future<String> launchCore({
    required String configPath,
    required int controllerPort,
    required String secret,
    required String logLevel,
  });

  /// Releases platform resources (child process, service binding, adapter).
  Future<void> shutdownCore();

  /// Called after the core is up so the platform can route traffic into it.
  Future<void> onCoreStarted(EngineStartOptions options, int mixedPort);

  /// Called before the core is stopped while the tunnel is still up.
  Future<void> onBeforeCoreStop();

  /// Publishes what the tunnel is doing for platforms whose status notification
  /// outlives the window — "Стокгольм · 42 мс".
  ///
  /// A notification that only says the application's name tells the user
  /// nothing they cannot already see, and on Android it is on screen for the
  /// whole session, so it has to carry the location and its latency. Platforms
  /// without such a notification simply ignore the call.
  Future<void> setTunnelSummary(String? summary) async {}

  /// A free TCP port on loopback.
  Future<int> findFreePort(int preferred) async {
    for (var port = preferred; port < preferred + 40; port++) {
      if (await _isPortFree(port)) return port;
    }
    // Fall back to an ephemeral port chosen by the OS.
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<bool> _isPortFree(int port) async {
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  Future<void> start(EngineStartOptions options) async {
    if (options.servers.isEmpty) {
      throw StateError('Нет серверов для подключения');
    }
    _emit(
      CoreSnapshot(state: CoreState.starting, message: 'Запуск ядра…'),
    );

    _options = options;
    _servers = List.unmodifiable(options.servers);
    _latencies = List<int?>.filled(_servers.length, null);
    await _stopCoreQuietly();

    try {
      final mixedPort = await findFreePort(17890);
      final controllerPort = await findFreePort(19090);
      final secret = _generateSecret();
      final tunAddresses = await chooseTunAddresses();
      _tunAddresses = tunAddresses;

      final config = MihomoConfigBuilder().build(
        MihomoConfigOptions(
          servers: _servers,
          mixedPort: mixedPort,
          controllerPort: controllerPort,
          secret: secret,
          // A platform whose proxy mode still runs a tunnel is asked for a tunnel
          // profile in both modes; the mode itself stays untouched for the UI.
          mode: configAlwaysTargetsTun ? VpnTunnelMode.tun : options.mode,
          logLevel: options.logLevel,
          tunDeviceName: options.tunDeviceName,
          tunAddresses: tunAddresses,
          enableIpv6: options.enableIpv6,
          // Automatic selection stays silent: the pool excludes Russian
          // locations and the tolerance keeps the core from trading places
          // between equivalent nodes.
          autoSelectPolicy: AutoSelectPolicy(
            ignoreRussian: options.ignoreRussianLocations,
            intervalSeconds: options.autoSelectIntervalSeconds,
          ),
          gameMode: options.gameMode,
          bypassDomains: options.bypassDomains,
          ruDirect: options.ruDirect,
        ),
      );

      _mixedPort = mixedPort;
      _controllerPort = controllerPort;
      _secret = secret;

      final configPath = await writeConfig(config);
      final baseUrl = await launchCore(
        configPath: configPath,
        controllerPort: controllerPort,
        secret: secret,
        logLevel: options.logLevel,
      );
      // The controller address the profile announces and the one the client
      // polls have to be the same port; when they are not, every request fails
      // with "connection refused" for a port nothing listens on.
      LogService.instance.log(
        'engine',
        'ports: mixed=$mixedPort controller=$controllerPort, '
            'controller url: $baseUrl',
      );

      final api = MihomoApiClient(baseUrl: baseUrl, secret: secret);
      final version =
          await api.waitUntilReady(failure: () => coreStartupFailure);
      _api = api;

      await onCoreStarted(options, mixedPort);

      _emit(
        CoreSnapshot(
          state: CoreState.running,
          coreVersion: version,
          activeProxy: await _resolveActiveProxy(),
          mode: options.mode.name,
          mixedPort: mixedPort,
          tunDevice: options.mode == VpnTunnelMode.tun
              ? options.tunDeviceName
              : null,
        ),
      );

      _startTrafficWatch(api);
      _startAutoSelect();
      // A first sweep makes the server list useful immediately instead of
      // showing dashes until the core's own interval elapses.
      unawaited(measureAllServers().catchError((_) => <ServerHealth>[]));
    } catch (error) {
      await _stopCoreQuietly();
      _emit(
        CoreSnapshot(state: CoreState.failed, message: _describe(error)),
      );
      rethrow;
    }
  }

  /// Takes over a core that is already running instead of starting another.
  ///
  /// Used on Android: the tunnel lives in a foreground service that outlives the
  /// window, so a relaunch must not build a second core over a working one. The
  /// controller is asked for its version first — a core that is gone makes this
  /// return `false`, and the caller starts the tunnel normally.
  Future<bool> attach({
    required String baseUrl,
    required String secret,
    required int mixedPort,
    required EngineStartOptions options,
  }) async {
    final api = MihomoApiClient(baseUrl: baseUrl, secret: secret);
    try {
      // The record of a running tunnel can outlive the core by a moment — a
      // revoked VPN, a battery kill, a network change. Waiting the full connect
      // timeout for a port that answers "connection refused" turns every
      // relaunch into a ten-second splash, so the probe is short: a controller
      // that is still binding accepts a request within it.
      final version = await api.waitUntilReady(
        timeout: const Duration(milliseconds: 1600),
      );
      _options = options;
      _servers = List.unmodifiable(options.servers);
      _latencies = List<int?>.filled(_servers.length, null);
      _api = api;
      _mixedPort = mixedPort > 0 ? mixedPort : null;
      _secret = secret;
      _emit(
        CoreSnapshot(
          state: CoreState.running,
          coreVersion: version,
          activeProxy: await _resolveActiveProxy(),
          mode: options.mode.name,
          mixedPort: _mixedPort,
          tunDevice: options.tunDeviceName,
        ),
      );
      _startTrafficWatch(api);
      _startAutoSelect();
      unawaited(measureAllServers().catchError((_) => <ServerHealth>[]));
      return true;
    } catch (error) {
      // A stale "running" state with a dead core: nothing to take over.
      LogService.instance.log(
        'engine',
        'attach to the running core failed: $error',
      );
      return false;
    }
  }

  @override
  Future<void> stop() async {
    if (_snapshot.state == CoreState.idle) return;
    _emit(CoreSnapshot(state: CoreState.stopping, message: 'Отключение…'));
    try {
      await onBeforeCoreStop();
    } catch (_) {}
    await _stopCoreQuietly();
    _emit(CoreSnapshot.idle);
  }

  Future<void> _stopCoreQuietly() async {
    _autoSelectTimer?.cancel();
    _autoSelectTimer = null;
    await _trafficSubscription?.cancel();
    _trafficSubscription = null;
    _api = null;
    try {
      await shutdownCore();
    } catch (_) {}
  }

  @override
  Future<bool> isCoreResponsive() async {
    final api = _api;
    if (api == null) return false;
    try {
      final version = await api
          .fetchVersion()
          .timeout(const Duration(seconds: 4));
      return version.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Reports that the core process disappeared without a `stop()` request.
  ///
  /// The platform engine calls this from its process-exit handler. Cancelling
  /// the watchers and surfacing a failure is what stops the UI from claiming a
  /// working tunnel over a dead core — the socket the counters arrive on can
  /// stay open for a while, so nothing else would notice. `VpnService` listens
  /// for this and rebuilds the tunnel.
  void reportCoreCrash(int exitCode, {String? detail}) {
    if (_disposed) return;
    final wasActive = _snapshot.state == CoreState.running ||
        _snapshot.state == CoreState.starting;
    _autoSelectTimer?.cancel();
    _autoSelectTimer = null;
    unawaited(_trafficSubscription?.cancel());
    _trafficSubscription = null;
    _api = null;
    if (!wasActive) return;
    final suffix = (detail == null || detail.isEmpty) ? '' : ' — $detail';
    _emit(
      CoreSnapshot(
        state: CoreState.failed,
        message: 'Ядро неожиданно завершилось (код $exitCode)$suffix',
      ),
    );
  }

  void _startTrafficWatch(MihomoApiClient api) {
    _trafficSubscription = api.watchTraffic().listen(
      (stats) {
        if (_disposed) return;
        _emit(
          CoreSnapshot(
            state: _snapshot.state,
            message: _snapshot.message,
            coreVersion: _snapshot.coreVersion,
            activeProxy: _snapshot.activeProxy,
            mode: _snapshot.mode,
            mixedPort: _snapshot.mixedPort,
            tunDevice: _snapshot.tunDevice,
          ),
          traffic: TrafficSnapshot(
            downloadBps: stats.downloadBps,
            uploadBps: stats.uploadBps,
            downloadTotalBytes: stats.downloadTotalBytes,
            uploadTotalBytes: stats.uploadTotalBytes,
            activeConnections: stats.activeConnections,
            uptimeSeconds: stats.uptimeSeconds,
          ),
        );
      },
      onError: (_) {},
    );
  }

  /// Latest traffic counters, refreshed once per second while running.
  TrafficSnapshot traffic = TrafficSnapshot.zero;

  void _startAutoSelect() {
    _autoSelectTimer?.cancel();
    final options = _options;
    if (options == null) return;
    // Keep the UI's latency column fresh independently of the core's own
    // url-test interval, which may be much longer.
    _autoSelectTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_snapshot.state != CoreState.running) return;
      unawaited(measureAllServers().catchError((_) => <ServerHealth>[]));
    });
  }

  // -------------------------------------------------------------------------
  // Server operations
  // -------------------------------------------------------------------------

  @override
  Future<List<ServerHealth>> measureAllServers() async {
    final api = _api;
    if (api == null || _servers.isEmpty) return const [];

    // Probing the whole group in one request lets the core reuse its own
    // connection pool and avoids one HTTP round trip per node.
    final groupDelays = await api.measureGroupDelay(MihomoGroupNames.auto);
    final active = await _resolveActiveProxy();

    final health = <ServerHealth>[];
    final updated = List<int?>.filled(_servers.length, null);
    for (var index = 0; index < _servers.length; index++) {
      final name = _servers[index].proxy['name'] as String;
      final delay = groupDelays[name] ?? 0;
      updated[index] = delay > 0 ? delay : -1;
      health.add(
        ServerHealth(name: name, delayMs: delay, isActive: name == active),
      );
    }
    _latencies = updated;
    _emit(
      CoreSnapshot(
        state: _snapshot.state,
        message: _snapshot.message,
        coreVersion: _snapshot.coreVersion,
        activeProxy: active,
        mode: _snapshot.mode,
        mixedPort: _snapshot.mixedPort,
        tunDevice: _snapshot.tunDevice,
      ),
    );
    return health;
  }

  @override
  Future<int?> measureServer(String name) async {
    final api = _api;
    if (api == null || name.isEmpty) return null;
    final index = _servers.indexWhere((entry) => entry.proxy['name'] == name);
    if (index < 0) return null;
    try {
      final delay = await api.measureDelay(name);
      final value = delay.delayMs > 0 ? delay.delayMs : -1;
      if (index < _latencies.length) {
        _latencies[index] = value;
      }
      return value > 0 ? value : null;
    } catch (_) {
      // A failed probe is not a broken tunnel: the next tick tries again.
      return null;
    }
  }

  @override
  Future<String?> selectFastestServer() async {
    final api = _api;
    if (api == null) return null;
    // Handing control back to AUTO lets the core pick the fastest node using
    // its own measurements, which is exactly the "auto" behaviour the UI
    // promises.
    await api.selectProxy(MihomoGroupNames.select, MihomoGroupNames.auto);
    final active = await api.currentSelection(MihomoGroupNames.auto);
    _updateActiveProxy(active);
    return active;
  }

  @override
  Future<void> selectProxy(String proxyName) async {
    final api = _api;
    if (api == null) throw StateError('Ядро не запущено');
    await api.selectProxy(MihomoGroupNames.select, proxyName);
    _updateActiveProxy(proxyName);
  }

  @override
  Future<String?> activeProxy() => _resolveActiveProxy();

  Future<String?> _resolveActiveProxy() async {
    final api = _api;
    if (api == null) return null;
    try {
      final selected = await api.currentSelection(MihomoGroupNames.select);
      if (selected == null) return null;
      if (selected == MihomoGroupNames.auto ||
          selected == MihomoGroupNames.fallback) {
        return await api.currentSelection(selected) ?? selected;
      }
      return selected;
    } catch (_) {
      return null;
    }
  }

  void _updateActiveProxy(String? name) {
    if (name == null || name == _snapshot.activeProxy) return;
    _emit(
      CoreSnapshot(
        state: _snapshot.state,
        message: _snapshot.message,
        coreVersion: _snapshot.coreVersion,
        activeProxy: name,
        mode: _snapshot.mode,
        mixedPort: _snapshot.mixedPort,
        tunDevice: _snapshot.tunDevice,
      ),
    );
  }

  @override
  Future<bool> refreshServers(List<ParsedVpnServer> servers) async {
    if (servers.isEmpty) return false;
    _servers = List.unmodifiable(servers);
    _latencies = List<int?>.filled(_servers.length, null);
    if (_snapshot.state != CoreState.running) return false;
    // The node list can be swapped without dropping the tunnel: the core reloads
    // the whole profile, so a connection that is already established keeps the
    // route it started with and new ones see the added or removed nodes. That is
    // what makes a scheduled refresh safe in the middle of a game.
    return _reapplyRouting();
  }

  @override
  Future<void> updateServers(List<ParsedVpnServer> servers) async {
    _servers = List.unmodifiable(servers);
    if (_snapshot.state != CoreState.running) return;
    // A full restart is the only portable way to swap the node list: the
    // controller's reload endpoint needs a file path, which the Android
    // in-process core does not expose.
    final options = _options;
    if (options == null) return;
    await start(
      EngineStartOptions(
        servers: servers,
        mode: options.mode,
        bypassLocalNetworks: options.bypassLocalNetworks,
        logLevel: options.logLevel,
        enableIpv6: options.enableIpv6,
        tunDeviceName: options.tunDeviceName,
        autoSelectIntervalSeconds: options.autoSelectIntervalSeconds,
        ignoreRussianLocations: options.ignoreRussianLocations,
        gameMode: options.gameMode,
        bypassDomains: options.bypassDomains,
        ruDirect: options.ruDirect,
      ),
    );
  }

  /// Regenerates the profile with new routing flags and applies it live.
  ///
  /// The config is pushed through the controller as an inline payload, so no
  /// core restart happens: established connections keep their route and only
  /// new ones follow the new rules. The regenerated file is also written to
  /// disk so a later restart stays consistent.
  ///
  /// Every argument is optional: omitting one keeps the value the engine was
  /// started with, which is what lets a caller change a single switch without
  /// having to carry the rest of the settings around.
  Future<bool> applyRoutingRules({
    bool? gameMode,
    List<String>? bypassDomains,
    bool? ruDirect,
  }) async {
    final options = _options;
    if (options == null) return false;
    final next = EngineStartOptions(
      servers: _servers,
      mode: options.mode,
      bypassLocalNetworks: options.bypassLocalNetworks,
      logLevel: options.logLevel,
      enableIpv6: options.enableIpv6,
      tunDeviceName: options.tunDeviceName,
      autoSelectIntervalSeconds: options.autoSelectIntervalSeconds,
      ignoreRussianLocations: options.ignoreRussianLocations,
      gameMode: gameMode ?? options.gameMode,
      bypassDomains: bypassDomains ?? options.bypassDomains,
      ruDirect: ruDirect ?? options.ruDirect,
    );
    _options = next;

    final api = _api;
    final port = _mixedPort;
    final controllerPort = _controllerPort;
    final secret = _secret;
    if (api == null ||
        _snapshot.state != CoreState.running ||
        port == null ||
        controllerPort == null ||
        secret == null) {
      LogService.instance.log(
        'engine',
        'routing reload skipped: the core is not running',
      );
      return false;
    }

    final config = MihomoConfigBuilder().build(
      MihomoConfigOptions(
        servers: _servers,
        mixedPort: port,
        controllerPort: controllerPort,
        secret: secret,
        mode: configAlwaysTargetsTun ? VpnTunnelMode.tun : next.mode,
        logLevel: next.logLevel,
        tunDeviceName: next.tunDeviceName,
        tunAddresses: _tunAddresses,
        enableIpv6: next.enableIpv6,
        autoSelectPolicy: AutoSelectPolicy(
          ignoreRussian: next.ignoreRussianLocations,
          intervalSeconds: next.autoSelectIntervalSeconds,
        ),
        gameMode: next.gameMode,
        bypassDomains: next.bypassDomains,
        ruDirect: next.ruDirect,
      ),
    );
    final path = await writeConfig(config);
    LogService.instance.log(
      'engine',
      'routing reload: ${next.bypassDomains.length} domain(s), '
          'game=${next.gameMode}, russianDirect=${next.ruDirect}',
    );
    try {
      await api.applyConfigPayload(config);
      LogService.instance.log(
        'engine',
        'routing reload: applied to the running core',
      );
    } catch (error) {
      // Older cores accept only the file-based reload.
      LogService.instance.log(
        'engine',
        'routing reload: inline payload rejected ($error), reloading file',
      );
      try {
        await api.reloadConfig(path);
        LogService.instance.log('engine', 'routing reload: applied from $path');
      } catch (reloadError) {
        // Some builds expose a read-only controller: the Android in-process
        // core answers "405 Method Not Allowed" to every write on /configs.
        // There is no portable live path left, so the tunnel is rebuilt with
        // the regenerated profile — the setting has to take effect even at the
        // cost of dropping established connections for a second.
        LogService.instance.log(
          'engine',
          'routing reload: controller is read-only ($reloadError), restarting '
              'the core',
        );
        await start(next);
      }
    }
    return true;
  }

  /// Reapplies the flags already stored on this engine, keeping them as they
  /// are. Used after the node list is replaced, which must not reset routing.
  Future<bool> _reapplyRouting() => applyRoutingRules();

  @override
  Stream<CoreTrafficStatsView> watchTraffic() async* {
    yield CoreTrafficStatsView(
      downloadTotalBytes: traffic.downloadTotalBytes,
      uploadTotalBytes: traffic.uploadTotalBytes,
      downloadBps: traffic.downloadBps,
      uploadBps: traffic.uploadBps,
      activeConnections: traffic.activeConnections,
      uptimeSeconds: traffic.uptimeSeconds,
    );
    yield* changes
        .where((snapshot) => _disposed == false)
        .map(
          (_) => CoreTrafficStatsView(
            downloadTotalBytes: traffic.downloadTotalBytes,
            uploadTotalBytes: traffic.uploadTotalBytes,
            downloadBps: traffic.downloadBps,
            uploadBps: traffic.uploadBps,
            activeConnections: traffic.activeConnections,
            uptimeSeconds: traffic.uptimeSeconds,
          ),
        );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _stopCoreQuietly();
    await _changes.close();
  }

  // -------------------------------------------------------------------------
  // helpers
  // -------------------------------------------------------------------------

  void _emit(CoreSnapshot snapshot, {TrafficSnapshot? traffic}) {
    _snapshot = snapshot;
    if (traffic != null) this.traffic = traffic;
    if (!_changes.isClosed) _changes.add(snapshot);
  }

  String _describe(Object error) {
    if (error is StateError) return error.message;
    if (error is SocketException) return 'Сеть недоступна: ${error.message}';
    return error.toString();
  }

  /// A per-launch secret for the loopback controller.
  ///
  /// The controller is reachable from any local process, so an unguessable
  /// secret is what stops another application (or a browser page via a
  /// fetch/WebSocket) from reconfiguring the tunnel.
  String _generateSecret() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

/// Instantaneous and cumulative counters surfaced to the UI.
class TrafficSnapshot {
  const TrafficSnapshot({
    required this.downloadBps,
    required this.uploadBps,
    required this.downloadTotalBytes,
    required this.uploadTotalBytes,
    required this.activeConnections,
    required this.uptimeSeconds,
  });

  final int downloadBps;
  final int uploadBps;
  final int downloadTotalBytes;
  final int uploadTotalBytes;
  final int activeConnections;
  final int uptimeSeconds;

  static const TrafficSnapshot zero = TrafficSnapshot(
    downloadBps: 0,
    uploadBps: 0,
    downloadTotalBytes: 0,
    uploadTotalBytes: 0,
    activeConnections: 0,
    uptimeSeconds: 0,
  );
}
