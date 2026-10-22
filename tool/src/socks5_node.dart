import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A minimal SOCKS5 server that forwards TCP connections.
///
/// It plays the part of the VPN node: if the core really routes traffic through
/// the selected proxy, the request has to arrive here. Both authentication modes
/// are accepted, matching whichever one the client offers, because mihomo's
/// SOCKS5 client asks for "no authentication" unless credentials are configured.
class Socks5Node {
  Socks5Node._(this._server);

  final ServerSocket _server;

  /// How many CONNECT requests were accepted; the tunnel assertion uses this.
  int forwarded = 0;

  /// Destinations the node was asked to reach, as `host:port`.
  ///
  /// The assertion uses this to prove *where* the traffic was sent, which is how
  /// the harness verifies that the request really traversed the proxy rather
  /// than depending on reaching a host on the public internet.
  final List<String> destinations = <String>[];

  /// Optional rewrite: `host:port` -> `host:port`.
  ///
  /// A node in a test has no business dialling the internet, so the harness maps
  /// the hostname the client asked for onto a local server. The rewrite is
  /// reported through [destinations], which keeps the evidence honest: the test
  /// still sees the name the core resolved.
  Map<String, String> rewriteRules = <String, String>{};

  int get port => _server.port;

  static const String username = 'scaleguard';
  static const String password = 'test-node-secret';

  static Future<Socks5Node> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final node = Socks5Node._(server);
    server.listen(node._handle, onError: (_) {});
    return node;
  }

  Future<void> _handle(Socket client) async {
    final reader = _BufferedReader(client);
    try {
      final greeting = await reader.read(2);
      final methods = await reader.read(greeting[1]);
      final wantsNone = methods.contains(0x00);
      final wantsPassword = methods.contains(0x02);
      if (!wantsNone && !wantsPassword) {
        client.add([0x05, 0xFF]);
        client.destroy();
        return;
      }
      final method = wantsNone ? 0x00 : 0x02;
      client.add([0x05, method]);

      if (method == 0x02) {
        final authHead = await reader.read(2);
        if (authHead[0] != 0x01) {
          client.destroy();
          return;
        }
        final user = utf8.decode(await reader.read(authHead[1]));
        final passwordLength = (await reader.read(1))[0];
        final suppliedPassword = utf8.decode(await reader.read(passwordLength));
        if (user != username || suppliedPassword != password) {
          client.add([0x01, 0x01]);
          client.destroy();
          return;
        }
        client.add([0x01, 0x00]);
      }

      final head = await reader.read(4);
      if (head[1] != 0x01) {
        // Only CONNECT is supported.
        client.add([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        client.destroy();
        return;
      }

      final String host;
      switch (head[3]) {
        case 0x01:
          host = (await reader.read(4)).join('.');
        case 0x03:
          host = utf8.decode(await reader.read((await reader.read(1))[0]));
        case 0x04:
          host = (await reader.read(16))
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join(':');
        default:
          client.destroy();
          return;
      }
      final portBytes = await reader.read(2);
      final port = (portBytes[0] << 8) | portBytes[1];

      final requested = '$host:$port';
      destinations.add(requested);
      final rewritten = rewriteRules[requested];
      final dialHost = rewritten == null ? host : rewritten.split(':').first;
      final dialPort =
          rewritten == null ? port : int.parse(rewritten.split(':').last);

      final upstream = await Socket.connect(
        dialHost,
        dialPort,
        timeout: const Duration(seconds: 10),
      );
      forwarded++;
      // Success reply with a zeroed bound address.
      client.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);

      // Relay in both directions. The client socket is already subscribed by
      // [_BufferedReader] — a socket cannot be listened to twice — so the reader
      // owns that direction and only needs to forward what it receives.
      final upstreamSubscription = upstream.listen(
        client.add,
        onDone: () {
          client.destroy();
          reader.close();
        },
        onError: (_) {
          client.destroy();
          reader.close();
        },
        cancelOnError: true,
      );
      await reader.relayTo(upstream);
      await upstreamSubscription.cancel();
    } catch (error) {
      // Reported rather than swallowed: a failing test double must explain
      // itself, otherwise the harness looks like a client bug.
      // ignore: avoid_print
      print('  [node] connection failed: $error');
      try {
        client.destroy();
      } catch (_) {}
    }
  }

  Future<void> stop() => _server.close();
}

/// Buffered reader that never discards bytes already pulled off the socket, which
/// matters because SOCKS5 clients pipeline their stages.
class _BufferedReader {
  _BufferedReader(this._socket) {
    _subscription = _socket.listen(
      (chunk) {
        _deliver(chunk);
        _wake();
      },
      onError: (Object error) {
        _error = error;
        final end = _onEnd;
        if (end != null) {
          end();
        } else {
          _wake();
        }
      },
      onDone: () {
        _closed = true;
        final end = _onEnd;
        if (end != null) {
          end();
        } else {
          _wake();
        }
      },
      cancelOnError: false,
    );
  }

  final Socket _socket;
  final List<int> _buffer = <int>[];
  late final StreamSubscription<List<int>> _subscription;
  Completer<void>? _waiter;
  Object? _error;
  bool _closed = false;

  /// Forwards everything the client sends to [upstream] until either side ends.
  ///
  /// This reuses the subscription created in the constructor instead of calling
  /// `listen` again, which a `Socket` does not allow.
  Future<void> relayTo(Socket upstream) async {
    final pending = List<int>.from(_buffer);
    _buffer.clear();
    if (pending.isNotEmpty) upstream.add(pending);

    final done = Completer<void>();
    _onData = (chunk) => upstream.add(chunk);
    _onEnd = () {
      upstream.destroy();
      if (!done.isCompleted) done.complete();
    };
    if (_closed || _error != null) {
      _onEnd?.call();
    }
    await done.future;
  }

  /// Detaches from the socket; the relay direction is finished.
  Future<void> close() async {
    _onEnd = null;
    await _subscription.cancel();
  }

  void Function(List<int> chunk)? _onData;
  void Function()? _onEnd;

  void _deliver(List<int> chunk) {
    final handler = _onData;
    if (handler != null) {
      handler(chunk);
      return;
    }
    _buffer.addAll(chunk);
  }

  void _wake() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<List<int>> read(int count) async {
    while (_buffer.length < count) {
      if (_error != null) throw _error!;
      if (_closed) throw StateError('socket closed while reading');
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }
}
