import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// Result of one latency probe through a specific proxy.
class ProxyDelay {
  const ProxyDelay(this.name, this.delayMs);

  final String name;
  final int delayMs;

  bool get isAlive => delayMs > 0;
}

/// Live traffic counters reported by the core.
class CoreTrafficStats {
  const CoreTrafficStats({
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

  static const CoreTrafficStats zero = CoreTrafficStats(
    downloadTotalBytes: 0,
    uploadTotalBytes: 0,
    downloadBps: 0,
    uploadBps: 0,
    activeConnections: 0,
  );

  /// Throughput in Mbit/s, matching what the home screen shows.
  double get downloadMbps => downloadBps * 8 / 1000000;
}

/// Thin client for mihomo's RESTful controller.
///
/// The controller is bound to loopback and protected by a per-launch secret, so
/// it is the only control channel the Dart side needs — no FFI, no platform
/// channels, and identical behaviour on Windows and Android.
class MihomoApiClient {
  MihomoApiClient({
    required this.baseUrl,
    required this.secret,
    Dio? dio,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 12),
                // The controller answers 4xx with a JSON `message`, which the
                // caller interprets; letting Dio throw would hide the detail.
                validateStatus: (_) => true,
              ),
            );

  final String baseUrl;
  final String secret;
  final Dio _dio;

  Options get _options => Options(
        headers: {
          'Authorization': 'Bearer $secret',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.plain,
      );

  Map<String, String> _query(Map<String, dynamic> params) =>
      params.map((key, value) => MapEntry(key, '$value'));

  /// Waits until the controller accepts requests, or throws after [timeout].
  ///
  /// [failure] is polled on every attempt: an engine that runs the core as a
  /// child process reports its exit there, so a profile the core rejected turns
  /// into an immediate, readable error instead of a twenty second wait that
  /// blames the controller.
  Future<String> waitUntilReady({
    Duration timeout = const Duration(seconds: 20),
    Duration interval = const Duration(milliseconds: 250),
    String? Function()? failure,
  }) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      final reason = failure?.call();
      if (reason != null && reason.isNotEmpty) throw StateError(reason);
      try {
        final version = await fetchVersion();
        if (version.isNotEmpty) return version;
      } catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(interval);
    }
    throw StateError(
      'Ядро не ответило за ${timeout.inSeconds} с'
      '${lastError == null ? '' : ': $lastError'}',
    );
  }

  Future<String> fetchVersion() async {
    final response = await _dio.get<String>('$baseUrl/version', options: _options);
    final body = _decode(response);
    return body['version']?.toString() ?? '';
  }

  /// Returns every proxy and group known to the core, keyed by name.
  Future<Map<String, Map<String, dynamic>>> fetchProxies() async {
    final response = await _dio.get<String>('$baseUrl/proxies', options: _options);
    final body = _decode(response);
    final proxies = body['proxies'];
    if (proxies is! Map) return {};
    final result = <String, Map<String, dynamic>>{};
    proxies.forEach((key, value) {
      if (value is Map) {
        result[key.toString()] = value.map(
          (innerKey, innerValue) => MapEntry(innerKey.toString(), innerValue),
        );
      }
    });
    return result;
  }

  /// The proxy currently selected inside [groupName] (mihomo calls it `now`).
  Future<String?> currentSelection(String groupName) async {
    final response = await _dio.get<String>(
      '$baseUrl/proxies/${Uri.encodeComponent(groupName)}',
      options: _options,
    );
    final body = _decode(response);
    final now = body['now']?.toString();
    if (now == null || now.isEmpty) return null;
    return now;
  }

  /// Switches a `select` group to [targetName] and waits for it to take effect.
  Future<void> selectProxy(String groupName, String targetName) async {
    final response = await _dio.put<String>(
      '$baseUrl/proxies/${Uri.encodeComponent(groupName)}',
      data: jsonEncode({'name': targetName}),
      options: _options,
    );
    if (response.statusCode == 204 || response.statusCode == 200) return;
    throw StateError(
      'Не удалось переключить сервер: ${_errorMessage(response)}',
    );
  }

  /// Measures one proxy through the core's own stack.
  ///
  /// A zero delay means the probe failed; mihomo reports that as HTTP 503/504,
  /// which is treated as "dead" rather than as a transport error so a single
  /// broken node never aborts a whole latency sweep.
  Future<ProxyDelay> measureDelay(
    String proxyName, {
    String url = 'https://www.gstatic.com/generate_204',
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final timeoutMs = timeout.inMilliseconds.clamp(1000, 15000);
    final response = await _dio.get<String>(
      '$baseUrl/proxies/${Uri.encodeComponent(proxyName)}/delay',
      queryParameters: _query({
        'url': url,
        'timeout': timeoutMs,
        'expected': '204',
      }),
      options: _options,
    );
    if (response.statusCode == 200) {
      final body = _decode(response);
      final delay = body['delay'];
      if (delay is num && delay > 0) {
        return ProxyDelay(proxyName, delay.toInt());
      }
    }
    return ProxyDelay(proxyName, 0);
  }

  /// Latency of every member of a group, as measured by the core in one pass.
  Future<Map<String, int>> measureGroupDelay(
    String groupName, {
    String url = 'https://www.gstatic.com/generate_204',
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final response = await _dio.get<String>(
      '$baseUrl/group/${Uri.encodeComponent(groupName)}/delay',
      queryParameters: _query({
        'url': url,
        'timeout': timeout.inMilliseconds.clamp(1000, 15000),
        'expected': '204',
      }),
      options: _options,
    );
    if (response.statusCode != 200) return {};
    final body = _decode(response);
    final result = <String, int>{};
    body.forEach((key, value) {
      if (value is num) result[key.toString()] = value.toInt();
    });
    return result;
  }

  /// Cumulative counters plus the active connection count.
  Future<({int download, int upload, int connections})> fetchTotals() async {
    final response = await _dio.get<String>(
      '$baseUrl/connections',
      options: _options,
    );
    final body = _decode(response);
    final connections = body['connections'];
    return (
      download: (body['downloadTotal'] as num?)?.toInt() ?? 0,
      upload: (body['uploadTotal'] as num?)?.toInt() ?? 0,
      connections: connections is List ? connections.length : 0,
    );
  }

  /// Which proxy actually carries traffic right now, according to the core.
  Future<String?> activeProxyFromConnections(String groupName) async {
    final response = await _dio.get<String>(
      '$baseUrl/connections',
      options: _options,
    );
    final body = _decode(response);
    final connections = body['connections'];
    if (connections is! List) return null;
    for (final connection in connections) {
      if (connection is! Map) continue;
      final chains = connection['chains'];
      if (chains is List && chains.isNotEmpty) {
        return chains.first.toString();
      }
    }
    return null;
  }

  /// Replaces the running configuration. Used when the node list changes.
  Future<void> reloadConfig(String absolutePath) async {
    final response = await _dio.put<String>(
      '$baseUrl/configs',
      queryParameters: {'force': 'true'},
      data: jsonEncode({'path': absolutePath}),
      options: _options,
    );
    if (response.statusCode == 204 || response.statusCode == 200) return;
    throw StateError('Не удалось применить профиль: ${_errorMessage(response)}');
  }

  /// Applies a complete configuration passed inline as YAML.
  ///
  /// Unlike [reloadConfig] it needs no file path, so it works even where the
  /// core cannot see the config file (the Android in-process service) — which
  /// makes it the way routing rules change without dropping the tunnel.
  Future<void> applyConfigPayload(String yaml) async {
    final response = await _dio.put<String>(
      '$baseUrl/configs',
      queryParameters: {'force': 'true'},
      data: jsonEncode({'payload': yaml}),
      options: _options,
    );
    if (response.statusCode == 204 || response.statusCode == 200) return;
    throw StateError('Не удалось применить правила: ${_errorMessage(response)}');
  }

  Future<void> flushFakeIpCache() async {
    await _dio.post<String>('$baseUrl/cache/fakeip/flush', options: _options);
  }

  /// Polls cumulative counters once per second and converts them to rates.
  ///
  /// mihomo also exposes `/traffic` as a chunked stream, but polling a single
  /// snapshot endpoint keeps one code path for totals, rates and the active
  /// connection count, and it degrades gracefully on a busy controller.
  Stream<CoreTrafficStats> watchTraffic({
    Duration interval = const Duration(seconds: 1),
    bool Function()? isCancelled,
  }) {
    late StreamController<CoreTrafficStats> controller;
    Timer? timer;
    var previousDown = 0;
    var previousUp = 0;
    var started = DateTime.now();
    var streamStartedAt = DateTime.now();
    var hasBaseline = false;

    Future<void> tick() async {
      try {
        final totals = await fetchTotals();
        if (!hasBaseline) {
          hasBaseline = true;
          previousDown = totals.download;
          previousUp = totals.upload;
        }
        final elapsed = DateTime.now().difference(started).inMilliseconds;
        final divisor = elapsed <= 0 ? 1.0 : elapsed / 1000.0;
        final downBps = ((totals.download - previousDown) / divisor)
            .clamp(0, double.infinity);
        final upBps =
            ((totals.upload - previousUp) / divisor).clamp(0, double.infinity);
        previousDown = totals.download;
        previousUp = totals.upload;
        started = DateTime.now();

        if (!controller.isClosed) {
          controller.add(
            CoreTrafficStats(
              downloadTotalBytes: totals.download,
              uploadTotalBytes: totals.upload,
              downloadBps: downBps.round(),
              uploadBps: upBps.round(),
              activeConnections: totals.connections,
              uptimeSeconds:
                  DateTime.now().difference(streamStartedAt).inSeconds,
            ),
          );
        }
      } catch (_) {
        // A transient controller failure must not tear down the UI stream.
      }
      if (isCancelled?.call() ?? false) {
        await controller.close();
        return;
      }
      timer = Timer(interval, tick);
    }

    controller = StreamController<CoreTrafficStats>(
      onListen: () {
        streamStartedAt = DateTime.now();
        started = DateTime.now();
        tick();
      },
      onCancel: () {
        timer?.cancel();
        timer = null;
      },
    );
    return controller.stream;
  }

  Map<String, dynamic> _decode(Response<String> response) {
    final raw = response.data;
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  String _errorMessage(Response<String> response) {
    final body = _decode(response);
    final message = body['message']?.toString();
    if (message != null && message.isNotEmpty) return message;
    return 'HTTP ${response.statusCode}';
  }
}
