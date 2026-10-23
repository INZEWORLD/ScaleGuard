import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../core/device_identity.dart';
import '../core/engines/android_vpn_engine.dart';
import '../core/engines/engine_factory.dart';
import '../core/engines/mihomo_engine_base.dart';
import '../core/mihomo_config.dart';
import '../core/server_naming.dart';
import '../core/subscription_parser.dart';
import '../core/vpn_engine.dart';
import '../models/models.dart';
import 'log_service.dart';

/// Connection state as the UI understands it.
enum VpnConnectionState { disconnected, connecting, connected, error }

/// One sample of the live counters shown on the home screen.
class VpnSpeedStats {
  final int downloadBytesPerSec;
  final int uploadBytesPerSec;
  final int pingMs;
  final DateTime timestamp;

  VpnSpeedStats({
    required this.downloadBytesPerSec,
    required this.uploadBytesPerSec,
    required this.pingMs,
    required this.timestamp,
  });
}

/// The single VPN façade used by the whole application.
///
/// It owns one platform [MihomoEngineBase], turns a Remnawave subscription URL
/// into mihomo proxies, keeps the fastest server selected and republishes the
/// core's counters in the shape the widgets already expect.
class VpnService {
  VpnService({
    MihomoEngineBase? engine,
    void Function(VpnConnectionState state, String? message)? onStatusChanged,
  }) : onStatusChanged = onStatusChanged ?? ((_, __) {}) {
    if (engine != null) {
      _adoptEngine(engine);
    }
    // The platform engine is resolved asynchronously: on Windows it needs the
    // per-user directory, and `createPlatformEngine` prefers Flutter's path
    // provider over its fallback. Callers that must not race it (tests) pass an
    // engine explicitly, or await [initialize] before connecting.
    _engineReady = _resolveEngine(engine);
  }

  MihomoEngineBase? _engine;
  late final Future<void> _engineReady;
  StreamSubscription<CoreSnapshot>? _engineSubscription;

  Future<void> _resolveEngine(MihomoEngineBase? provided) async {
    if (provided != null) return;
    final engine = await createPlatformEngine();
    _adoptEngine(engine);
  }

  void _adoptEngine(MihomoEngineBase engine) {
    _engine = engine;
    _engineSubscription?.cancel();
    _engineSubscription = engine.changes.listen(_handleEngineSnapshot);
  }

  /// The active engine. Only valid after [initialize] has completed.
  MihomoEngineBase get _activeEngine {
    final engine = _engine;
    if (engine == null) {
      throw StateError('Движок ещё не инициализирован');
    }
    return engine;
  }

  void Function(VpnConnectionState state, String? message) onStatusChanged;
  void Function(VpnSpeedStats stats)? onSpeedStats;

  /// Called when the core moved the tunnel to another node by itself, so the UI
  /// can say so instead of silently changing the exit country.
  void Function(String remark)? onAutoLocationChange;

  /// Set for something the user should see even while the window is hidden — a
  /// node that stopped answering, a switch the client made on the user's behalf.
  /// Separate from [onAutoLocationChange] because these are not all location
  /// changes, and rewording them as one would hide what actually happened.
  void Function(String message)? onNotice;

  VpnConnectionState _state = VpnConnectionState.disconnected;
  String? _lastError;
  List<VpnServerProfile> _profiles = [];
  int _selectedIndex = 0;
  final List<int?> _serverLatencies = [];

  final List<int> _windowDownloadBps = [];
  bool _autoSelectEnabled = true;
  bool _gameModeEnabled = false;
  List<String> _bypassDomains = const <String>[];
  bool _ruDirectEnabled = true;

  int _currentDownloadBps = 0;
  int _currentUploadBps = 0;
  int _currentPingMs = 0;
  int _downloadTotalBytes = 0;
  int _uploadTotalBytes = 0;
  int _activeConnections = 0;
  int _uptimeSeconds = 0;

  Timer? _statsTimer;
  Timer? _autoSwitchTimer;
  bool _switching = false;
  DateTime _lastFailoverAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastFailoverSweepAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _activeNodeFailures = 0;
  bool _pingingServers = false;
  bool _starting = false;
  bool _disposed = false;

  Timer? _recoveryTimer;
  Timer? _recoveryResetTimer;
  int _recoveryAttempts = 0;
  bool _recovering = false;
  int _unresponsiveChecks = 0;
  int _statsTicks = 0;

  /// How many automatic restarts follow a core crash before the client gives up
  /// and asks the user to reconnect by hand.
  static const int _maxRecoveryAttempts = 4;

  /// A tunnel that stays up this long after a restart is considered healthy, and
  /// the restart budget is refilled.
  static const Duration _recoveryStability = Duration(seconds: 45);

  /// Consecutive failed liveness checks that mean "the core is gone" rather than
  /// "the controller was briefly busy".
  static const int _unresponsiveLimit = 3;

  /// Every Nth stats tick performs the liveness round-trip, so the counters
  /// stay snappy while a dead core is still noticed within seconds.
  static const int _livenessTickInterval = 5;

  /// How often the UI refreshes counters and re-evaluates auto switching.
  static const int _statsIntervalSec = 2;

  /// A location change within this window of a manual pick is attributed to the
  /// user, not to the core's automatic selection.
  static const Duration _userSelectionGrace = Duration(seconds: 8);

  /// Consecutive failed probes of the active node before it counts as dead.
  ///
  /// One failed probe is a transient — the tunnel was busy, the probe's target
  /// was unreachable for a moment, the node was rate-limiting. Three in a row is
  /// a node that stopped answering, and waiting any longer means the user sits in
  /// front of a tunnel that is silently doing nothing.
  static const int _deadNodeFailures = 3;

  /// Minimum time between two automatic switches, so one flapping node cannot
  /// turn into a switch storm.
  static const Duration _failoverCooldown = Duration(seconds: 20);

  /// Minimum time between two measurement passes triggered by a failover.
  static const Duration _failoverSweepCooldown = Duration(minutes: 1);

  DateTime _lastUserSelectionAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _isRecentUserSelection =>
      DateTime.now().difference(_lastUserSelectionAt) < _userSelectionGrace;

  /// Below this sustained throughput an *idle* tunnel is reconnected, which
  /// recovers from a silently dropped session.
  static const int _reconnectOnLowDownloadBps = 96 * 1024;

  /// Name of the core-side group that performs automatic selection.
  static const String autoGroupName = MihomoGroupNames.auto;

  VpnConnectionState get state => _state;
  String? get lastError => _lastError;
  List<VpnServerProfile> get profiles => List.unmodifiable(_profiles);
  int get selectedIndex => _selectedIndex;

  /// Puts a node list loaded from the offline cache back into service.
  ///
  /// The core has not started yet at this point, so there is nothing to push
  /// into mihomo: the next connect builds its configuration from exactly the
  /// same list a fresh subscription response would have produced.
  void restoreProfiles(
    List<VpnServerProfile> profiles, {
    String? selectedRemark,
  }) {
    _profiles = List<VpnServerProfile>.of(profiles);
    _serverLatencies
      ..clear()
      ..addAll(List<int?>.filled(_profiles.length, null));
    final match = selectedRemark == null
        ? -1
        : _profiles.indexWhere((profile) => profile.remark == selectedRemark);
    _selectedIndex = match >= 0 ? match : 0;
  }

  /// Drops the cached subscription together with the signed-in account.
  void clearProfiles() {
    _profiles = [];
    _serverLatencies.clear();
    _selectedIndex = 0;
    _subscriptionMetadata = null;
  }
  List<int?> get serverLatencies => List.unmodifiable(_serverLatencies);
  int get currentPingMs => _currentPingMs;
  int get downloadTotalBytes => _downloadTotalBytes;
  int get uploadTotalBytes => _uploadTotalBytes;
  int get activeConnections => _activeConnections;
  int get uptimeSeconds => _uptimeSeconds;
  bool get autoSelectEnabled => _autoSelectEnabled;
  bool get gameModeEnabled => _gameModeEnabled;

  // These three are read by the settings screen before the engine has finished
  // resolving, so they answer conservatively instead of throwing.
  bool get requiresSystemPermission =>
      _engine?.requiresTunnelPermission ?? false;
  bool get supportsTunMode => _engine?.supportsTunMode ?? false;
  String get platformName => _engine?.platformName ?? '…';

  /// Which server the core actually carries traffic through.
  String? get activeProxyName => _engine?.snapshot.activeProxy;

  /// Path to the bundled core binary, when the platform runs one out of process.
  String? get coreExecutablePath => _engine?.coreExecutablePath;

  /// Version string of the running core, or `null` when it is stopped.
  String? get coreVersion => _engine?.snapshot.coreVersion;

  /// Mode the tunnel was started in (`systemProxy` or `tun`).
  String? get tunnelMode => _engine?.snapshot.mode;

  Future<void> initialize() async {
    await _engineReady;
    await _activeEngine.initialize();
  }

  /// Android and iOS show a system consent dialog; Windows never does.
  Future<bool> requestSystemPermission() async {
    await _engineReady;
    await _activeEngine.initialize();
    return _activeEngine.requestTunnelPermission();
  }

  // ---------------------------------------------------------------------------
  // Subscription handling
  // ---------------------------------------------------------------------------

  /// Downloads a Remnawave subscription and normalises it into mihomo proxies.
  ///
  /// Remnawave picks the response format from the request, and a self-hosted
  /// panel may be deployed without the "mihomo" template registered. The client
  /// therefore tries several strategies in order — explicit client type, mihomo
  /// User-Agent, then whatever the plain URL returns — and accepts YAML,
  /// base64 share links or Xray/sing-box JSON from any of them.
  ///
  /// [device] is used for the HWID headers that make the panel's per-subscription
  /// device limit work; without it the panel neither counts nor limits devices.
  Future<List<VpnServerProfile>> loadProfilesFromSubscription(
    String url, {
    DeviceIdentity? device,
  }) async {
    if (url.trim().isEmpty) {
      throw ArgumentError('Subscription URL пуст');
    }

    final baseUri = Uri.parse(url.trim());
    final strategies = <_SubscriptionRequest>[
      // 1. Force the mihomo template: the richest response, and the only one
      //    that carries Reality/Vision fields exactly as the panel generated
      //    them.
      _SubscriptionRequest(
        uri: Uri.parse(deriveMihomoSubscriptionUrl(url)),
        userAgent: _mihomoUserAgent,
        accept: 'text/yaml, application/json, text/plain, */*',
        label: 'clientType=mihomo',
      ),
      // 2. Announce mihomo instead of forcing the path, for panels that map
      //    clients by User-Agent only.
      _SubscriptionRequest(
        uri: baseUri,
        userAgent: _mihomoUserAgent,
        accept: 'text/yaml, application/json, text/plain, */*',
        label: 'User-Agent=mihomo',
      ),
      // 3. Last resort: let the panel answer with its fallback format, which is
      //    normally base64 Xray share links.
      _SubscriptionRequest(
        uri: baseUri,
        userAgent: _fallbackUserAgent,
        accept: 'text/plain, application/json, */*',
        label: 'fallback',
      ),
    ];

    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
        followRedirects: true,
        responseType: ResponseType.plain,
        // The panel answers 404 when an HWID is required but missing, and 4xx
        // otherwise; keeping the body lets the caller explain the real reason
        // instead of reporting a generic network failure.
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    final failures = <String>[];
    Response<String>? response;
    List<ParsedVpnServer> parsed = const [];

    for (final strategy in strategies) {
      final attempt = await _trySubscription(
        dio,
        strategy,
        device: device,
        fallbackBaseUri: baseUri,
      );
      if (attempt.body.trim().isEmpty) {
        // A 200 with an empty body is what a broken subscription backend looks
        // like (the panel service itself is up, the generator is not). It is
        // worth distinguishing from "no servers", so it is reported verbatim.
        failures.add('${strategy.label}: пустой ответ');
        continue;
      }
      final servers = parseSubscriptionBodyOrEmpty(attempt.body);
      if (servers.isEmpty) {
        failures.add('${strategy.label}: нет распознанных серверов');
        continue;
      }
      response = attempt.response;
      parsed = servers;
      break;
    }

    if (parsed.isEmpty || response == null) {
      throw StateError(_subscriptionFailureMessage(failures.join('; ')));
    }

    _subscriptionMetadata = SubscriptionMetadata.fromHeaders(
      response.headers.map.map((key, value) => MapEntry(key, value.join(','))),
    );

    _profiles = parsed
        .map(
          (server) => VpnServerProfile(
            remark: server.remark,
            configJson: jsonEncode(server.proxy),
            protocol: server.protocol,
            server: server.server,
            port: server.port,
            countryCode: server.countryCode,
            proxy: server.proxy,
          ),
        )
        .toList();

    _serverLatencies
      ..clear()
      ..addAll(List<int?>.filled(_profiles.length, null));

    // Keep the user's current choice across a profile refresh when the node is
    // still present; otherwise fall back to the first entry.
    final previous = _selectedIndex >= 0 && _selectedIndex < _profiles.length
        ? _profiles[_selectedIndex].remark
        : null;
    final matching = previous == null
        ? -1
        : _profiles.indexWhere((profile) => profile.remark == previous);
    _selectedIndex = matching >= 0 ? matching : 0;

    return _profiles;
  }

  /// Metadata advertised by the subscription response (title, traffic, expiry).
  SubscriptionMetadata? _subscriptionMetadata;
  SubscriptionMetadata? get subscriptionMetadata => _subscriptionMetadata;

  List<ParsedVpnServer> _parsedServers() => _profiles
      .map(
        (profile) => ParsedVpnServer(
          remark: profile.remark,
          protocol: profile.protocol,
          server: profile.server,
          port: profile.port,
          proxy: profile.proxy,
          countryCode: profile.countryCode,
        ),
      )
      .toList();

  /// User-Agent that makes Remnawave answer with its native mihomo profile.
  static const String _mihomoUserAgent = 'mihomo/1.19.32';

  /// User-Agent for the last-resort attempt, which asks the panel for whatever
  /// fallback format it has configured (normally base64 Xray share links).
  static const String _fallbackUserAgent = 'v2rayNG/1.10.11';

  /// One attempt at downloading the subscription.
  Future<_SubscriptionAttempt> _trySubscription(
    Dio dio,
    _SubscriptionRequest request, {
    required DeviceIdentity? device,
    required Uri fallbackBaseUri,
  }) async {
    try {
      final response = await dio.get<String>(
        request.uri.toString(),
        options: Options(
          headers: {
            'User-Agent': request.userAgent,
            'Accept': request.accept,
            // The HWID headers are what bind this installation to the panel
            // user. Without them Remnawave neither counts nor limits devices,
            // which is why a client that omits them silently ignores the
            // subscription's device limit.
            ...?device?.headers,
          },
        ),
      );

      final status = response.statusCode ?? 0;
      final body = (response.data ?? '').trim();

      if (status == 404) {
        // Remnawave answers 404 when the device limit is on and no `x-hwid` was
        // sent, and also when the short UUID is unknown.
        return _SubscriptionAttempt(
          response: response,
          body: '',
          note: device == null
              ? 'HTTP 404: подписка не найдена'
              : 'HTTP 404: превышен лимит устройств или подписка не найдена',
        );
      }
      if (status == 403) {
        return _SubscriptionAttempt(
          response: response,
          body: '',
          note: 'HTTP 403: подписка отозвана или истекла',
        );
      }
      if (status != 200) {
        return _SubscriptionAttempt(
          response: response,
          body: '',
          note: 'HTTP $status',
        );
      }
      return _SubscriptionAttempt(response: response, body: body);
    } catch (error) {
      return _SubscriptionAttempt(
        response: null,
        body: '',
        note: _describe(error),
      );
    }
  }

  /// Turns the collected per-strategy notes into one actionable message.
  ///
  /// The user cannot fix a server-side problem, so the message says what is
  /// wrong and who can fix it, rather than echoing an HTTP code alone.
  String _subscriptionFailureMessage(String details) {
    final empty = details.contains('пустой ответ');
    if (empty) {
      return 'Сервер подписки отвечает, но отдаёт пустой профиль. '
          'Обычно это значит, что на стороне панели не запущен сервис подписки '
          '(remnawave-subscription-page) или для пользователя не настроены хосты. '
          'Подробности: $details';
    }
    return 'Не удалось получить список серверов. Подробности: $details';
  }

  // ---------------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------------

  /// Starts the tunnel.
  ///
  /// [mode] defaults to the system proxy on platforms that support it, because
  /// it needs no elevation; TUN is used where it is the only option (Android,
  /// iOS) or when the user asked for full coverage.
  Future<void> connect({VpnTunnelMode? mode}) async {
    if (_starting) return;
    _starting = true;
    try {
      // The platform engine may still be resolving on Windows, where it needs
      // the per-user directory before the core can be launched.
      await _engineReady;
      if (_profiles.isEmpty) {
        throw StateError('Профиль Remnawave не загружен');
      }
      _setState(VpnConnectionState.connecting, null);

      final effectiveMode = mode ?? _activeEngine.preferredMode;
      LogService.instance.log(
        'vpn',
        'connect: mode=${effectiveMode.name}, servers=${_profiles.length}, '
            'autoSelect=$_autoSelectEnabled, gameMode=$_gameModeEnabled',
      );
      final started = _activeEngine.start(_buildStartOptions(effectiveMode));
      await started;

      // Honour the user's explicit pick; otherwise let the core choose.
      if (_autoSelectEnabled) {
        await _activeEngine.selectFastestServer();
      } else if (_selectedIndex < _profiles.length) {
        await _activeEngine.selectProxy(_profiles[_selectedIndex].remark);
      }

      _setState(VpnConnectionState.connected, null);
      LogService.instance.log('vpn', 'connected (mode: ${effectiveMode.name})');
      _startStatsMonitoring();
    } catch (error) {
      LogService.instance.log('vpn', 'connect failed: ${_describe(error)}');
      _setState(VpnConnectionState.error, _describe(error));
      rethrow;
    } finally {
      _starting = false;
    }
  }

  /// The options every start uses, shared with [adoptRunningTunnel] so an
  /// adopted tunnel is described exactly like a fresh one.
  EngineStartOptions _buildStartOptions(VpnTunnelMode mode) => EngineStartOptions(
    servers: _parsedServers(),
    mode: mode,
    logLevel: 'warning',
    autoSelectIntervalSeconds: _autoSelectEnabled ? 60 : 0,
    gameMode: _gameModeEnabled,
    bypassDomains: _bypassDomains,
    ruDirect: _ruDirectEnabled,
  );

  /// Loads the native core ahead of the first connect (Android only).
  Future<void> warmUp() async {
    if (!Platform.isAndroid) return;
    await _engineReady;
    final engine = _activeEngine;
    if (engine is AndroidVpnEngine) await engine.warmUp();
  }

  /// Takes over a tunnel that outlived the window.  ///
  /// Android keeps the tunnel in a foreground service, so after the window is
  /// closed and reopened the core is often still carrying traffic. Building a
  /// second core over it is what made a relaunch show "connecting" for a long
  /// time and then report a tunnel that was not there: the old core was killed
  /// underneath the new one. This attaches the interface to the core that is
  /// already up. Returns `true` when there was one.
  Future<bool> adoptRunningTunnel({VpnTunnelMode? mode}) async {
    if (!Platform.isAndroid) return false;
    if (_state == VpnConnectionState.connected) return true;
    if (_profiles.isEmpty) return false;
    await _engineReady;
    final engine = _activeEngine;
    if (engine is! AndroidVpnEngine) return false;
    var running = await engine.runningTunnel();
    if (running == null) return false;
    // A sticky restart is still bringing the core back: waiting for it is far
    // cheaper than starting a second one over it.
    for (var i = 0; i < 10 && running != null && running.state == 'starting'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      running = await engine.runningTunnel();
    }
    if (running == null || running.state != 'running') return false;
    final adopted = await engine.attach(
      baseUrl: running.baseUrl,
      secret: running.secret,
      mixedPort: running.mixedPort,
      options: _buildStartOptions(mode ?? _activeEngine.preferredMode),
    );
    if (!adopted) return false;
    LogService.instance.log(
      'vpn',
      'adopted the tunnel that was already running '
          '(${running.baseUrl}, mixed ${running.mixedPort})',
    );
    await _syncSelectionFromCore();
    _setState(VpnConnectionState.connected, null);
    _startStatsMonitoring();
    return true;
  }

  Future<void> disconnect() async {
    LogService.instance.log('vpn', 'disconnect');
    _cancelRecovery();
    _stopStatsMonitoring();
    _switching = false;
    await _engineReady;
    await _activeEngine.stop();
    _resetCounters();
    _setState(VpnConnectionState.disconnected, null);
  }

  void dispose() {
    _disposed = true;
    _stopStatsMonitoring();
    _engineSubscription?.cancel();
    _engineSubscription = null;
    // The engine may still be resolving; disposing it once it exists is what
    // releases the child process and restores the system proxy.
    unawaited(_engineReady.then((_) => _engine?.dispose()));
  }

  // ---------------------------------------------------------------------------
  // Server selection
  // ---------------------------------------------------------------------------

  void selectProfile(int index) {
    if (index >= 0 && index < _profiles.length) {
      _selectedIndex = index;
    }
  }

  /// Turns engine-driven selection on or off.
  ///
  /// `true` hands the choice to mihomo's automatic group; `false` pins the
  /// server the user picked. Neither case restarts the tunnel: the change is a
  /// selector switch inside the running core, so established connections finish
  /// on the route they started with and only new ones move. That is what makes
  /// automatic selection safe mid-game or mid-call.
  Future<void> setAutoSelect(bool enabled) async {
    _autoSelectEnabled = enabled;
    if (_state != VpnConnectionState.connected) return;
    if (enabled) {
      await _activeEngine.selectFastestServer();
      await _syncSelectionFromCore();
    } else if (_selectedIndex < _profiles.length) {
      await _activeEngine.selectProxy(_profiles[_selectedIndex].remark);
    }
  }

  /// Pins the tunnel to [index] and leaves automatic mode.
  ///
  /// The switch happens inside the running core, so nothing is torn down.
  Future<void> selectServer(int index) async {
    if (index < 0 || index >= _profiles.length) return;
    _lastUserSelectionAt = DateTime.now();
    _selectedIndex = index;
    _autoSelectEnabled = false;
    if (_state == VpnConnectionState.connected) {
      await _activeEngine.selectProxy(_profiles[index].remark);
      _publishTunnelSummary();
    }
  }

  /// Stores the routing flags and applies them to a running tunnel.
  ///
  /// While disconnected the flags simply wait for the next start; while
  /// connected the profile is regenerated and pushed through the controller, so
  /// the rules change without dropping the tunnel or the system proxy. That is
  /// what makes a saved bypass list take effect immediately.
  Future<void> setRoutingMode({
    bool? gameMode,
    List<String>? bypassDomains,
    bool? ruDirect,
  }) async {
    if (gameMode != null) _gameModeEnabled = gameMode;
    if (bypassDomains != null) _bypassDomains = List.unmodifiable(bypassDomains);
    if (ruDirect != null) _ruDirectEnabled = ruDirect;
    if (_state != VpnConnectionState.connected) return;
    await _engineReady;
    try {
      await _activeEngine.applyRoutingRules(
        gameMode: _gameModeEnabled,
        bypassDomains: _bypassDomains,
        ruDirect: _ruDirectEnabled,
      );
    } catch (error) {
      // A failed live reload must not tear the tunnel down; the next start
      // picks the flags up from the fields above anyway.
      LogService.instance.log('vpn', 'routing reload failed: $error');
    }
  }

  /// Adopts whatever the core currently considers best.
  ///
  /// Used after a latency sweep while the tunnel is up: the core has already
  /// switched (or decided not to), and this only mirrors the decision into the
  /// UI so the highlighted row matches reality.
  Future<void> applyBestServerSelection() async {
    if (_state != VpnConnectionState.connected) return;
    if (_autoSelectEnabled) {
      await _syncSelectionFromCore();
    } else if (_selectedIndex < _profiles.length) {
      await _activeEngine.selectProxy(_profiles[_selectedIndex].remark);
    }
  }

  /// Hands a freshly downloaded node list to a running tunnel.
  ///
  /// The scheduled subscription check must not interrupt a game or a call, so
  /// the new profile goes through the core's controller instead of a restart.
  /// Returns `true` when the running tunnel adopted it.
  Future<bool> adoptRefreshedServers() async {
    if (_profiles.isEmpty) return false;
    if (_state != VpnConnectionState.connected) return false;
    await _engineReady;
    try {
      return await _activeEngine.refreshServers(_parsedServers());
    } catch (_) {
      // Losing a live refresh is not a reason to drop the tunnel: the list in
      // memory is already updated and the next connect picks it up.
      return false;
    }
  }

  /// Mirrors the core's active proxy into [selectedIndex].
  Future<void> _syncSelectionFromCore() async {
    final active = await _activeEngine.activeProxy();
    if (active == null || active.isEmpty) return;
    final index = _profiles.indexWhere((profile) => profile.remark == active);
    if (index >= 0 && index != _selectedIndex) {
      _selectedIndex = index;
      onStatusChanged(_state, _lastError);
    }
  }

  /// Measures every server and adopts the fastest one.
  Future<int> selectFastestServer() async {
    // Measuring does not disturb the tunnel; only the selection changes.
    final health = await _activeEngine.measureAllServers();
    _recordLatencies(health);
    final active = await _activeEngine.selectFastestServer();
    if (active != null) {
      final index = _profiles.indexWhere((profile) => profile.remark == active);
      if (index >= 0) _selectedIndex = index;
    }
    return _selectedIndex;
  }

  /// Stores a latency sweep into [serverLatencies] and returns the best index.
  int _recordLatencies(List<ServerHealth> health) {
    for (var index = 0; index < _serverLatencies.length; index++) {
      _serverLatencies[index] = null;
    }
    var bestIndex = _selectedIndex;
    var bestLatency = 1 << 31;
    for (final entry in health) {
      final index =
          _profiles.indexWhere((profile) => profile.remark == entry.name);
      if (index < 0) continue;
      _serverLatencies[index] = entry.delayMs > 0 ? entry.delayMs : -1;
      if (entry.delayMs > 0 && entry.delayMs < bestLatency) {
        bestLatency = entry.delayMs;
        bestIndex = index;
      }
    }
    return bestIndex;
  }

  /// Sweeps every node and, when idle, preselects the fastest one so the next
  /// connect is immediate.
  Future<void> pingAllServersAndAutoSelect({
    bool Function()? cancelled,
    void Function()? onTick,
  }) async {
    if (_profiles.isEmpty || _pingingServers) return;
    _pingingServers = true;
    try {
      var health = const <ServerHealth>[];
      try {
        health = await _activeEngine.measureAllServers();
      } catch (_) {
        // The engine may not be resolved yet; the direct probe below still
        // gives the user numbers.
        health = const <ServerHealth>[];
      }
      if (health.isEmpty) {
        // No running core (tunnel down): probe the nodes straight from the
        // app, otherwise "Обновить" would do nothing until the first connect.
        health = await _measureDirectLatency();
      }
      if (health.isEmpty) {
        onTick?.call();
        return;
      }
      final bestIndex = _recordLatencies(health);
      // Never move the user's selection while the tunnel is up: the switch is
      // performed by the core's own group, and mirroring it here would make the
      // highlighted row jump under the user's finger.
      if (_state != VpnConnectionState.connected && _autoSelectEnabled) {
        // Automatic selection must never land on a Russian location, matching
        // the core-side AUTO pool that excludes them.
        var best = -1;
        var bestDelay = 1 << 31;
        for (final entry in health) {
          if (entry.delayMs <= 0) continue;
          final index = _profiles
              .indexWhere((profile) => profile.remark == entry.name);
          if (index < 0 || isRussianLocation(_profiles[index].remark)) {
            continue;
          }
          if (entry.delayMs < bestDelay) {
            bestDelay = entry.delayMs;
            best = index;
          }
        }
        _selectedIndex = best >= 0 ? best : bestIndex;
      }
      onStatusChanged(_state, _lastError);
      onTick?.call();
    } finally {
      _pingingServers = false;
    }
    _failoverIfActiveNodeDead();
  }

  /// TCP handshake time to [host]:[port], used when the core is not running.
  ///
  /// It is not identical to the core's unified-delay measured through the exit,
  /// but it ranks locations sensibly and proves reachability without a tunnel.
  Future<int> _tcpPing(String host, int port) async {
    final watch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 2),
      );
      watch.stop();
      socket.destroy();
      return watch.elapsedMilliseconds;
    } catch (_) {
      return 0;
    }
  }

  /// Measures every profile directly from the app, no tunnel required.
  Future<List<ServerHealth>> _measureDirectLatency() async {
    final probes = _profiles.map((profile) async {
      final ms = await _tcpPing(profile.server, profile.port);
      return ServerHealth(name: profile.remark, delayMs: ms);
    });
    return Future.wait(probes);
  }

  Future<int?> measureDelay(int index) async {
    if (index < 0 || index >= _profiles.length) return null;
    final health = await _activeEngine.measureAllServers();
    for (final entry in health) {
      if (entry.name == _profiles[index].remark) {
        final delay = entry.delayMs > 0 ? entry.delayMs : -1;
        if (index < _serverLatencies.length) _serverLatencies[index] = delay;
        return delay > 0 ? delay : null;
      }
    }
    return null;
  }

  /// Latency of the node the tunnel currently exits through.
  ///
  /// Called from the statistics loop rather than only from a sweep, because the
  /// sweep that runs on connect races the fresh tunnel and can come back empty:
  /// a client that connects without ever opening the location list would then
  /// show a dash for the whole session. Re-reading it also keeps the number
  /// honest over a long session, which is what a ping reading is for.
  Future<int?> measureActiveLatency() async {
    if (_disposed || _state != VpnConnectionState.connected) return null;
    final active = _activeEngine.snapshot.activeProxy;
    if (active == null || active.isEmpty) return null;
    final index = _profiles.indexWhere((profile) => profile.remark == active);
    int? value;
    try {
      value = await _activeEngine.measureServer(active);
    } catch (_) {
      value = null;
    }
    if (_disposed || _state != VpnConnectionState.connected) return null;
    if (value != null && value > 0) {
      _activeNodeFailures = 0;
      _currentPingMs = value;
      if (index >= 0 && index < _serverLatencies.length) {
        _serverLatencies[index] = value;
      }
      return value;
    }
    // A miss is only evidence of a dead node when it repeats. The count is kept
    // here rather than in the statistics loop because this is where the probe
    // happens, and the loop is what acts on the verdict.
    _activeNodeFailures++;
    if (_activeNodeFailures >= _deadNodeFailures && index >= 0) {
      if (index < _serverLatencies.length) _serverLatencies[index] = -1;
    }
    return null;
  }

  /// Statistics ticks between two probes of the active node.
  static const int _latencyTickInterval = 3;

  /// `host:port` for the server row subtitle.
  String? extractHostPort(int index) {
    if (index < 0 || index >= _profiles.length) return null;
    final profile = _profiles[index];
    if (profile.server.isEmpty) return null;
    return '${profile.server}:${profile.port}';
  }

  // ---------------------------------------------------------------------------
  // Statistics
  // ---------------------------------------------------------------------------

  void _startStatsMonitoring() {
    _stopStatsMonitoring();
    _windowDownloadBps.clear();
    _statsTicks = 0;
    _unresponsiveChecks = 0;
    _statsTimer = Timer.periodic(
      const Duration(seconds: _statsIntervalSec),
      (_) => _onStatsTick(),
    );
    unawaited(_onStatsTick());
  }

  void _stopStatsMonitoring() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _autoSwitchTimer?.cancel();
    _autoSwitchTimer = null;
  }

  Future<void> _onStatsTick() async {
    if (_disposed || _state != VpnConnectionState.connected) return;
    try {
      final tick = ++_statsTicks;
      // `_activeEngine.traffic` is refreshed by the engine's own one-second poll, so
      // this tick only mirrors it and measures the active server's latency.
      final snapshot = _activeEngine.traffic;
      _currentDownloadBps = snapshot.downloadBps;
      _currentUploadBps = snapshot.uploadBps;
      _downloadTotalBytes = snapshot.downloadTotalBytes;
      _uploadTotalBytes = snapshot.uploadTotalBytes;
      _activeConnections = snapshot.activeConnections;
      _uptimeSeconds = snapshot.uptimeSeconds;

      _windowDownloadBps.add(_currentDownloadBps);
      if (_windowDownloadBps.length > 30) _windowDownloadBps.removeAt(0);

      final active = _activeEngine.snapshot.activeProxy;
      if (active != null) {
        final index = _profiles.indexWhere((profile) => profile.remark == active);
        if (index >= 0) {
          final moved = index != _selectedIndex;
          _selectedIndex = index;
          final delay = _serverLatencies[index];
          if (delay != null && delay > 0) _currentPingMs = delay;
          // A change the user just made is not news; only the core's own
          // decisions are worth a banner.
          if (moved && !_isRecentUserSelection) {
            onAutoLocationChange?.call(_profiles[index].remark);
          }
        }
      }

      // The latency the card shows has to come from the tunnel that is actually
      // up. The sweep started on connect fills every node, but it races the
      // fresh tunnel, and a client that connected without opening the location
      // list could otherwise sit on a dash for the whole session. Re-reading it
      // also keeps the number honest over a long session, which is exactly what
      // "ping" is supposed to tell the user.
      //
      // A node that has already been judged dead is not probed on every tick —
      // that would be a request every two seconds at something that answers
      // nothing — but the interval keeps checking, so a node that comes back is
      // picked up again.
      final unmeasured =
          _currentPingMs <= 0 && _activeNodeFailures < _deadNodeFailures;
      if (unmeasured || tick % _latencyTickInterval == 0) {
        await measureActiveLatency();
      }

      _emitSpeedStats();
      _publishTunnelSummary();
      _maybeReconnectOnLowThroughput();
      _failoverIfActiveNodeDead();

      // The websocket the counters arrive on outlives its process for a while,
      // so a dead core would otherwise keep showing the last values forever. A
      // cheap round-trip every few ticks is what tells the two apart.
      if (tick % _livenessTickInterval == 0 &&
          !_switching &&
          !_recovering) {
        final responsive = await _activeEngine.isCoreResponsive();
        if (_disposed || _state != VpnConnectionState.connected) return;
        if (responsive) {
          _unresponsiveChecks = 0;
        } else if (++_unresponsiveChecks >= _unresponsiveLimit) {
          _unresponsiveChecks = 0;
          LogService.instance.log(
            'vpn',
            'core stopped answering the controller; rebuilding the tunnel',
          );
          _stopStatsMonitoring();
          _setState(VpnConnectionState.error, 'Ядро перестало отвечать');
          _scheduleCoreRecovery('контроллер не отвечает');
        }
      }
    } catch (_) {
      // A statistics failure must never tear the tunnel down.
    }
  }

  void _maybeReconnectOnLowThroughput() {
    if (_state != VpnConnectionState.connected || _switching || _disposed) {
      return;
    }
    if (_windowDownloadBps.length < 15) return;
    final lowCount =
        _windowDownloadBps.where((value) => value < _reconnectOnLowDownloadBps).length;
    // Only an *idle* tunnel is reconnected: a slow download is not evidence of
    // a broken one, and reconnecting mid-transfer would be worse than waiting.
    if (lowCount != _windowDownloadBps.length) return;
    if (_activeConnections > 0) return;
    _windowDownloadBps.clear();
    unawaited(_trySeamlessReconnect(reason: 'low_throughput'));
  }

  /// Moves the tunnel off a node that stopped answering.
  ///
  /// This runs for a manually picked location as well as in automatic mode: a
  /// location that dies mid-session leaves the tunnel silent, and waiting for the
  /// user to notice is not a feature. The switch happens inside the core, so
  /// established connections are not torn down, and the change is announced
  /// instead of being applied behind the user's back.
  void _failoverIfActiveNodeDead() {
    if (_state != VpnConnectionState.connected ||
        _switching ||
        _disposed ||
        _pingingServers) {
      return;
    }
    if (DateTime.now().difference(_lastFailoverAt) < _failoverCooldown) {
      return;
    }
    final active = _activeEngine.snapshot.activeProxy;
    if (active == null) return;
    final index = _profiles.indexWhere((profile) => profile.remark == active);
    if (index < 0 || index >= _serverLatencies.length) return;
    // -1 means the node was proven unreachable, by a sweep or by repeated probes;
    // null means it was never measured, so acting on it would be a guess.
    if (_serverLatencies[index] != -1) return;
    _lastFailoverAt = DateTime.now();
    unawaited(_switchAwayFromDeadNode(index));
  }

  Future<void> _switchAwayFromDeadNode(int deadIndex) async {
    final dead = _profiles[deadIndex].remark;
    var target = _bestHealthyIndex(excluding: deadIndex);
    if (target == null &&
        DateTime.now().difference(_lastFailoverSweepAt) > _failoverSweepCooldown) {
      // Nothing has a reading — a session that started without a sweep. One
      // measurement pass is worth the wait here, because without it there is no
      // candidate to move to at all. It is rate-limited so an outage that takes
      // every node down does not turn into a sweep every twenty seconds.
      _lastFailoverSweepAt = DateTime.now();
      try {
        _recordLatencies(await _activeEngine.measureAllServers());
      } catch (_) {}
      target = _bestHealthyIndex(excluding: deadIndex);
    }
    if (target == null) {
      onNotice?.call(
        'Узел «$dead» не отвечает, замена не найдена. Проверьте соединение.',
      );
      return;
    }
    try {
      await _activeEngine.selectProxy(_profiles[target].remark);
    } catch (error) {
      LogService.instance.log('vpn', 'failover switch failed: $error');
      return;
    }
    _activeNodeFailures = 0;
    _selectedIndex = target;
    // The client chose this node, so the automatic flag no longer describes what
    // is happening; the user can hand control back from the location list.
    _autoSelectEnabled = false;
    _lastUserSelectionAt = DateTime.fromMillisecondsSinceEpoch(0);
    _currentPingMs = _serverLatencies[target] ?? 0;
    LogService.instance.log(
      'vpn',
      'failover: «$dead» -> «${_profiles[target].remark}»',
    );
    onNotice?.call(
      'Узел «$dead» не отвечает — переключено на «${_profiles[target].remark}»',
    );
    onStatusChanged(_state, _lastError);
  }

  /// Fastest node with a known-good reading, ignoring [excluding].
  int? _bestHealthyIndex({int? excluding}) {
    int? best;
    int? bestValue;
    final limit = _profiles.length < _serverLatencies.length
        ? _profiles.length
        : _serverLatencies.length;
    for (var i = 0; i < limit; i++) {
      if (i == excluding) continue;
      final value = _serverLatencies[i];
      if (value == null || value <= 0) continue;
      if (bestValue == null || value < bestValue) {
        bestValue = value;
        best = i;
      }
    }
    return best;
  }

  /// Recovers a stalled tunnel without restarting it.
  ///
  /// The core's own health checker re-probes every node on its interval; asking
  /// it to re-run the selection is enough to move traffic to a healthier node.
  /// A full core restart is the last resort, because it drops the tunnel and the
  /// system proxy setting with it.
  Future<void> _trySeamlessReconnect({String? reason}) async {
    if (_switching || _disposed) return;
    _switching = true;
    try {
      if (_autoSelectEnabled) {
        // Hands control back to the automatic group, which re-applies its
        // health-checked choice; in-flight connections are unaffected.
        await _activeEngine.selectFastestServer();
        await _syncSelectionFromCore();
        return;
      }
      if (_selectedIndex < 0 || _selectedIndex >= _profiles.length) return;
      await _activeEngine.selectProxy(_profiles[_selectedIndex].remark);
    } catch (error) {
      // Only a genuine core failure justifies a restart.
      LogService.instance.log(
        'vpn',
        'seamless select failed (${_describe(error)}); restarting core',
      );
      try {
        final mode = _activeEngine.snapshot.mode == VpnTunnelMode.tun.name
            ? VpnTunnelMode.tun
            : VpnTunnelMode.systemProxy;
        await _activeEngine.start(
          EngineStartOptions(
            servers: _parsedServers(),
            mode: mode,
            autoSelectIntervalSeconds: _autoSelectEnabled ? 60 : 0,
            gameMode: _gameModeEnabled,
            bypassDomains: _bypassDomains,
            ruDirect: _ruDirectEnabled,
          ),
        );
      } catch (restartError) {
        LogService.instance.log('vpn', 'core restart failed: $restartError');
        _setState(
          VpnConnectionState.error,
          'Автовосстановление не удалось: ${_describe(restartError)}',
        );
      }
    } finally {
      _switching = false;
    }
  }

  void _emitSpeedStats() {
    onSpeedStats?.call(
      VpnSpeedStats(
        downloadBytesPerSec: _currentDownloadBps,
        uploadBytesPerSec: _currentUploadBps,
        pingMs: _currentPingMs,
        timestamp: DateTime.now(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Engine plumbing
  // ---------------------------------------------------------------------------

  void _handleEngineSnapshot(CoreSnapshot snapshot) {
    if (_disposed) return;
    switch (snapshot.state) {
      case CoreState.starting:
        _setState(VpnConnectionState.connecting, null);
      case CoreState.running:
        if (_state != VpnConnectionState.connected) {
          _setState(VpnConnectionState.connected, null);
          if (_state == VpnConnectionState.connected &&
              _statsTimer == null) {
            _startStatsMonitoring();
          }
        }
      case CoreState.stopping:
        _setState(VpnConnectionState.connecting, 'Отключение…');
      case CoreState.idle:
        _stopStatsMonitoring();
        _resetCounters();
        _setState(VpnConnectionState.disconnected, null);
      case CoreState.failed:
        // Only a tunnel that had actually come up is worth rebuilding
        // automatically: a start that failed on its own (a missing adapter, a
        // missing driver) would fail the same way four more times, and the
        // message the core produced is what the user needs to see instead.
        final hadTunnel = _state == VpnConnectionState.connected;
        _stopStatsMonitoring();
        _setState(VpnConnectionState.error, snapshot.message);
        if (hadTunnel) {
          _scheduleCoreRecovery(snapshot.message ?? 'ядро остановилось');
        }
    }
  }

  /// Cancels a pending restart, so a manual disconnect is never undone a second
  /// later by an automatic reconnect.
  void _cancelRecovery() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _recoveryResetTimer?.cancel();
    _recoveryResetTimer = null;
    _recoveryAttempts = 0;
    _recovering = false;
    _unresponsiveChecks = 0;
  }

  /// Rebuilds the tunnel after the core died or stopped answering.
  ///
  /// The restart is automatic, exponential and bounded: a one-off crash costs a
  /// couple of seconds, while a core that cannot start at all stops after
  /// [_maxRecoveryAttempts] and leaves the user with an error they can act on
  /// instead of an endless loop.
  void _scheduleCoreRecovery(String reason) {
    if (_disposed || _recovering || _starting || _recoveryTimer != null) return;
    if (_recoveryAttempts >= _maxRecoveryAttempts) {
      _setState(
        VpnConnectionState.error,
        'Не удалось восстановить соединение после сбоя ядра. '
        'Подключитесь заново.',
      );
      return;
    }
    _recoveryAttempts++;
    final delay = Duration(seconds: 1 << (_recoveryAttempts - 1));
    LogService.instance.log(
      'vpn',
      'core recovery #$_recoveryAttempts in ${delay.inSeconds}s ($reason)',
    );
    _setState(VpnConnectionState.connecting, 'Восстановление соединения…');
    _recoveryTimer = Timer(delay, () async {
      _recoveryTimer = null;
      if (_disposed) return;
      _recovering = true;
      try {
        await _activeEngine.stop().catchError((Object _) {});
        await connect();
        _armRecoveryReset();
        LogService.instance.log('vpn', 'core recovered automatically');
      } catch (error) {
        LogService.instance.log(
          'vpn',
          'core recovery failed: ${_describe(error)}',
        );
        _recovering = false;
        _scheduleCoreRecovery('предыдущая попытка не удалась');
        return;
      }
      _recovering = false;
    });
  }

  /// Refills the restart budget once a recovered tunnel has proven stable.
  void _armRecoveryReset() {
    _recoveryResetTimer?.cancel();
    _recoveryResetTimer = Timer(_recoveryStability, () {
      if (_state != VpnConnectionState.connected) return;
      _recoveryAttempts = 0;
    });
  }

  void _resetCounters() {
    _currentDownloadBps = 0;
    _currentUploadBps = 0;
    _currentPingMs = 0;
    _downloadTotalBytes = 0;
    _uploadTotalBytes = 0;
    _activeConnections = 0;
    _uptimeSeconds = 0;
    _windowDownloadBps.clear();
    _emitSpeedStats();
  }

  void _setState(VpnConnectionState next, String? message) {
    _state = next;
    _lastError = next == VpnConnectionState.error ? message : null;
    _publishTunnelSummary();
    onStatusChanged(next, message);
  }

  /// Mirrors what the tunnel is doing into the platform's status notification.
  ///
  /// Only Android has one, and it is on screen for the entire session — after
  /// the user swipes the window away, it is the only place the location and its
  /// latency are visible at all. The engine drops a repeated summary, so calling
  /// this on every state change and statistics tick costs nothing.
  void _publishTunnelSummary() {
    if (_engine == null) return;
    if (_profiles.isEmpty) return;
    if (_selectedIndex < 0 || _selectedIndex >= _profiles.length) return;
    final label = locationLabel(_profiles[_selectedIndex].remark);
    if (label.isEmpty) return;
    final ping = _selectedIndex < _serverLatencies.length
        ? _serverLatencies[_selectedIndex]
        : null;
    final String summary;
    if (_state == VpnConnectionState.connected) {
      summary = ping != null && ping > 0 ? '$label · $ping мс' : label;
    } else if (_state == VpnConnectionState.connecting) {
      summary = '$label · подключение…';
    } else {
      summary = label;
    }
    unawaited(_activeEngine.setTunnelSummary(summary));
  }

  String _describe(Object error) {
    if (error is StateError) return error.message;
    if (error is DioException) {
      return error.message ?? 'Ошибка сети';
    }
    return error.toString();
  }

  // ---------------------------------------------------------------------------
  // Formatting helpers used by the widgets
  // ---------------------------------------------------------------------------

  /// Public exit IP as seen from the internet; used to prove the tunnel works.
  ///
  /// While the tunnel is up the request is pinned to the local mixed port, so
  /// the monitoring card shows the address the world sees from the VPN exit
  /// rather than the provider's direct one (Dart ignores the WinINet proxy).
  Future<String?> fetchExternalIp() async {
    final client = HttpClient();
    try {
      if (_state == VpnConnectionState.connected) {
        final port = _activeEngine.snapshot.mixedPort;
        if (port != null && port > 0) {
          client.findProxy = (uri) => 'PROXY 127.0.0.1:$port';
        }
      }
      client.connectionTimeout = const Duration(seconds: 6);
      final request = await client
          .getUrl(Uri.parse('https://api.ipify.org?format=json'))
          .timeout(const Duration(seconds: 8));
      final response = await request.close().timeout(const Duration(seconds: 8));
      final data = await response.transform(utf8.decoder).join();
      final match = RegExp(r'"ip"\s*:\s*"([^"]+)"').firstMatch(data);
      return match?.group(1);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  String formatTraffic(num? bytes) {
    if (bytes == null) return '—';
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(2)} GB';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  String formatSpeed(int? bytesPerSec) {
    if (bytesPerSec == null || bytesPerSec <= 0) return '0 КБ/с';
    final mbps = bytesPerSec * 8 / 1000000;
    if (mbps >= 1) return '${mbps.toStringAsFixed(1)} Мбит/с';
    final kbps = bytesPerSec / 1024;
    if (kbps >= 1) return '${kbps.toStringAsFixed(0)} КБ/с';
    return '$bytesPerSec Б/с';
  }

  String formatExpiry(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return '${dt.day.toString().padLeft(2, '0')}.'
        '${dt.month.toString().padLeft(2, '0')}.${dt.year}';
  }

  /// Human readable uptime of the current session.
  String formatUptime(int seconds) {
    if (seconds <= 0) return '—';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${secs.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}';
  }

  // ---------------------------------------------------------------------------
  // Legacy static helpers kept for compatibility with existing call sites
  // ---------------------------------------------------------------------------

  /// Options bag mirroring the native `VpnOptions` model.
  ///
  /// The engine builds the live profile itself, so the real port and in-tunnel
  /// DNS address are chosen per run; these are the defaults the native side
  /// falls back to when a key is absent, and they must stay in sync with
  /// `android/service/.../models/VpnOptions.kt`.
  static Map<String, dynamic> buildNativeBridgeOptions() => const {
        'enable': true,
        'port': 7890,
        'dnsServerAddress': '',
        'ipv4': true,
        'ipv6': false,
      };
}

/// One way of asking the panel for a profile.
///
/// Remnawave selects the response format from the URL path segment and the
/// `User-Agent`, and a self-hosted panel may have only some templates
/// configured, so several requests are attempted in order.
class _SubscriptionRequest {
  const _SubscriptionRequest({
    required this.uri,
    required this.userAgent,
    required this.accept,
    required this.label,
  });

  final Uri uri;
  final String userAgent;
  final String accept;

  /// Short name used in diagnostics.
  final String label;
}

/// Outcome of a single attempt.
class _SubscriptionAttempt {
  const _SubscriptionAttempt({
    required this.response,
    required this.body,
    this.note,
  });

  final Response<String>? response;
  final String body;

  /// Why the attempt produced no body, when that is the case.
  final String? note;
}