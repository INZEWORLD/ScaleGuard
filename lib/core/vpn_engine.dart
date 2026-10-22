import '../core/subscription_parser.dart';

/// How the platform hands traffic to the core.
enum VpnTunnelMode {
  /// Local HTTP/SOCKS server plus the Windows system proxy setting.
  /// No administrator rights, but only WinINet-aware apps are covered.
  systemProxy,

  /// Virtual network adapter (Wintun on Windows, VpnService on Android).
  /// Covers every application; needs elevation on Windows.
  tun,
}

/// Lifecycle phases reported by an engine.
enum CoreState {
  /// Nothing is running.
  idle,

  /// The core process/service is coming up.
  starting,

  /// The core is up and the tunnel is carrying traffic.
  running,

  /// The core was asked to stop.
  stopping,

  /// The last operation failed; [CoreSnapshot.message] carries the reason.
  failed,
}

/// Immutable view of the engine, safe to hand to widgets.
class CoreSnapshot {
  const CoreSnapshot({
    required this.state,
    this.message,
    this.coreVersion,
    this.activeProxy,
    this.mode,
    this.mixedPort,
    this.tunDevice,
  });

  final CoreState state;
  final String? message;
  final String? coreVersion;
  final String? activeProxy;
  final String? mode;
  final int? mixedPort;
  final String? tunDevice;

  bool get isRunning => state == CoreState.running;
  bool get isBusy => state == CoreState.starting || state == CoreState.stopping;

  static const CoreSnapshot idle = CoreSnapshot(state: CoreState.idle);
}

/// Every `/api/sub/<shortUuid>` URL has exactly this shape, so when the website
/// API hands out a link with a non-mihomo path (a custom prefix, a `singbox`
/// template, …) the client can request the mihomo profile that belongs with it.
String deriveMihomoSubscriptionUrl(
  String subscriptionUrl, {
  String clientType = 'mihomo',
}) {
  final trimmed = subscriptionUrl.trim();
  if (trimmed.isEmpty) return trimmed;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return trimmed;
  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
  if (segments.isEmpty) return trimmed;
  final last = segments.last.toLowerCase();
  if (const {
    'mihomo',
    'clash',
    'stash',
    'singbox',
    'json',
    'v2ray-json',
  }.contains(last)) {
    return trimmed;
  }
  return uri.replace(pathSegments: [...segments, clientType]).toString();
}

/// The two addresses the core puts on its own tunnel adapter.
///
/// Only platforms where the core owns the interface need these: elsewhere the
/// operating system hands the core an already-configured file descriptor. They
/// exist as one value because a tunnel is useless without both — Windows refuses
/// a start whose IPv4 or IPv6 address another adapter already holds.
class TunAddresses {
  const TunAddresses({required this.v4, required this.v6});

  final String v4;
  final String v6;

  @override
  String toString() => 'tun $v4, $v6';
}

/// Everything an engine needs to bring a profile up.
class EngineStartOptions {
  const EngineStartOptions({
    required this.servers,
    required this.mode,
    this.bypassLocalNetworks = true,
    this.logLevel = 'warning',
    this.enableIpv6 = false,
    this.tunDeviceName = 'ScaleGuard',
    this.autoSelectIntervalSeconds = 180,
    this.ignoreRussianLocations = true,
    this.gameMode = false,
    this.bypassDomains = const <String>[],
    this.ruDirect = true,
  });

  final List<ParsedVpnServer> servers;
  final VpnTunnelMode mode;
  final bool bypassLocalNetworks;
  final String logLevel;
  final bool enableIpv6;
  final String tunDeviceName;

  /// How often the core re-probes the automatic pool.
  final int autoSelectIntervalSeconds;

  /// Keeps Russian locations out of the automatic pool. They stay selectable by
  /// hand, but the client must never route traffic through them on its own.
  final bool ignoreRussianLocations;

  /// Game mode: games connect directly, everything else stays proxied.
  final bool gameMode;

  /// Domains the user added by hand, already normalised by
  /// `parseBypassDomains`; they always leave over the real connection.
  final List<String> bypassDomains;

  /// Keeps Russian sites — and with them the banking and government apps that
  /// check the exit address — on the user's own connection.
  final bool ruDirect;
}

/// A discovered server plus its last measured latency.
class ServerHealth {
  const ServerHealth({
    required this.name,
    required this.delayMs,
    this.isActive = false,
  });

  final String name;
  final int delayMs;
  final bool isActive;

  bool get isReachable => delayMs > 0;
}

/// Contract implemented once per platform.
///
/// * Windows — a bundled `mihomo.exe` sidecar driven over its RESTful API.
/// * Android — the same core compiled into the app as a `VpnService`.
/// * Apple   — a Network Extension hosting the core (see `docs/apple.md`).
///
/// Keeping this surface small is what lets one UI serve every platform.
abstract class VpnCoreEngine {
  /// Prepares platform resources. Must be idempotent.
  Future<void> initialize();

  /// Asks for whatever the OS requires before a tunnel may be created.
  /// Returns `true` when the tunnel may proceed.
  Future<bool> requestTunnelPermission();

  /// True when the OS needs an interactive consent dialog (Android VPN prompt).
  bool get requiresTunnelPermission;

  /// True when the platform can take over all traffic (TUN) rather than only
  /// the system proxy.
  bool get supportsTunMode;

  /// Human readable platform name for diagnostics.
  String get platformName;

  /// Starts the core with [options] and resolves once traffic can flow.
  Future<void> start(EngineStartOptions options);

  /// Stops the core and releases the adapter, listeners and ports.
  Future<void> stop();

  /// Replaces the node list without tearing the engine down when possible.
  Future<void> updateServers(List<ParsedVpnServer> servers);

  /// Replaces the node list and applies it to a running tunnel when it can.
  ///
  /// A scheduled subscription refresh must not interrupt a game or a call, so
  /// the new profile is pushed through the controller instead of restarting the
  /// core. Returns `true` when the running tunnel adopted the list.
  Future<bool> refreshServers(List<ParsedVpnServer> servers) async {
    await updateServers(servers);
    return false;
  }

  /// The proxy the core currently considers active, or `null`.
  Future<String?> activeProxy();

  /// Switches the manual selector to [proxyName].
  Future<void> selectProxy(String proxyName);

  /// Measures every configured node through the core's own stack.
  Future<List<ServerHealth>> measureAllServers();

  /// Latency of one node, measured through the core's own stack.
  ///
  /// A sweep answers "which node is fastest" and costs a request for every node;
  /// this answers "how is the connection I am using doing" for exactly one. The
  /// live ping in the monitoring card needs that second question, and asking it
  /// is what gives a session a reading even when the user never opened the
  /// location list. `null` means the node did not answer.
  Future<int?> measureServer(String name) async => null;

  /// Lets the core pick the fastest node on its own and returns its name.
  Future<String?> selectFastestServer();

  /// Cumulative and instantaneous counters.
  Stream<CoreTrafficStatsView> watchTraffic();

  /// Current snapshot; engines push updates through [changes].
  CoreSnapshot get snapshot;

  /// Asks the core whether it is still answering.
  ///
  /// The traffic stream is a websocket and can stay open for a while after the
  /// process behind it died, so counters alone cannot tell a healthy tunnel from
  /// a dead one. This is the cheap round-trip that can.
  Future<bool> isCoreResponsive();

  /// Emits on every state change.
  Stream<CoreSnapshot> get changes;

  List<int?> get latencies => const [];

  /// Frees everything, including any child process.
  Future<void> dispose();
}

/// Platform-independent traffic view (mirrors the API client's counters).
class CoreTrafficStatsView {
  const CoreTrafficStatsView({
    required this.downloadTotalBytes,
    required this.uploadTotalBytes,
    required this.downloadBps,
    required this.uploadBps,
    required this.activeConnections,
    this.uptimeSeconds = 0,
  });

  final int downloadTotalBytes;
  final int uploadTotalBytes;
  final int downloadBps;
  final int uploadBps;
  final int activeConnections;
  final int uptimeSeconds;

  static const CoreTrafficStatsView zero = CoreTrafficStatsView(
    downloadTotalBytes: 0,
    uploadTotalBytes: 0,
    downloadBps: 0,
    uploadBps: 0,
    activeConnections: 0,
  );
}
