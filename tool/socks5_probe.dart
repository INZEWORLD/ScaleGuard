// Diagnostic for the SOCKS5 node used by `tool/e2e_tunnel.dart`.
//
// The end-to-end run depends on this server being a correct SOCKS5 endpoint, so
// it is verified on its own before any mihomo involvement:
//
//   dart run tool/socks5_probe.dart
//
// It starts the node, performs a real SOCKS5 negotiation through it, and reports
// exactly which step fails. This is what distinguishes "the test node is broken"
// from "the core cannot reach the node".
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'test_doubles.dart';

Future<void> main() async {
  final node = await Socks5Node.start();
  print('node listening on 127.0.0.1:${node.port}');

  // The destination is a local server, not a host on the internet: the probe
  // must verify the SOCKS5 relay, not the machine's outbound connectivity (which
  // is often owned by another VPN client during development).
  final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  target.listen((request) async {
    request.response
      ..statusCode = 200
      ..write('probe-ok');
    await request.response.close();
  });
  print('target listening on 127.0.0.1:${target.port}');

  var failures = 0;
  for (final mode in ['no-auth', 'user-pass']) {
    print('\n--- $mode ---');
    try {
      final body = await _probe(
        node.port,
        target.port,
        withCredentials: mode == 'user-pass',
      );
      print('  relay works, body="$body"');
    } catch (error) {
      failures++;
      print('  FAILED: $error');
    }
  }

  await target.close(force: true);
  await node.stop();
  print('\n${failures == 0 ? "PASSED" : "FAILED ($failures)"}');
  exit(failures == 0 ? 0 : 1);
}

Future<String> _probe(
  int port,
  int targetPort, {
  required bool withCredentials,
}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final reader = _Reader(socket);

  // Greeting: version 5, one method.
  socket.add([0x05, 0x01, withCredentials ? 0x02 : 0x00]);
  final chosen = await reader.read(2);
  if (chosen[0] != 0x05) throw StateError('bad version reply: $chosen');
  print('  greeting reply: method=0x${chosen[1].toRadixString(16)}');
  if (withCredentials) {
    if (chosen[1] != 0x02) throw StateError('server did not request user/pass');
    final user = utf8.encode(Socks5Node.username);
    final password = utf8.encode(Socks5Node.password);
    socket.add([0x01, user.length, ...user, password.length, ...password]);
    final auth = await reader.read(2);
    print('  auth reply: status=0x${auth[1].toRadixString(16)}');
    if (auth[1] != 0x00) throw StateError('authentication rejected');
  } else if (chosen[1] != 0x00) {
    throw StateError('server did not accept no-auth');
  }

  // CONNECT to the local target using a numeric IP, so the probe itself needs no
  // DNS resolution.
  socket.add([
    0x05, 0x01, 0x00, 0x01,
    127, 0, 0, 1,
    (targetPort >> 8) & 0xFF, targetPort & 0xFF,
  ]);
  final reply = await reader.read(10);
  print('  connect reply: rep=0x${reply[1].toRadixString(16)}');
  if (reply[1] != 0x00) {
    throw StateError('connect rejected with 0x${reply[1].toRadixString(16)}');
  }

  // A real HTTP round trip proves the relay pipe works in both directions.
  socket.add(
    utf8.encode('GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n'),
  );
  // The response arrives in several chunks (status line, headers, body), so the
  // probe reads until the body marker shows up rather than assuming one packet.
  final buffer = StringBuffer();
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!buffer.toString().contains('probe-ok') &&
      DateTime.now().isBefore(deadline)) {
    final chunk = await reader.readSome(timeout: const Duration(seconds: 2));
    if (chunk.isEmpty) continue;
    buffer.write(utf8.decode(chunk));
  }
  socket.destroy();
  final text = buffer.toString();
  if (!text.contains('probe-ok')) {
    throw StateError('unexpected response: ${text.split("\r\n").first}');
  }
  return text.split('\r\n').first;
}

/// Minimal buffered reader that keeps leftover bytes.
class _Reader {
  _Reader(this._socket) {
    _subscription = _socket.listen(
      (chunk) {
        _buffer.addAll(chunk);
        final waiter = _waiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      },
      onError: (Object error) {
        _error = error;
        final waiter = _waiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      },
      onDone: () {
        _closed = true;
        final waiter = _waiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      },
    );
  }

  final Socket _socket;
  final List<int> _buffer = <int>[];
  late final StreamSubscription<List<int>> _subscription;
  Completer<void>? _waiter;
  Object? _error;
  bool _closed = false;

  Future<List<int>> read(int count) async {
    while (_buffer.length < count) {
      if (_error != null) throw _error!;
      if (_closed) throw StateError('closed while reading $count bytes');
      _waiter = Completer<void>();
      await _waiter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw StateError('timeout waiting for $count bytes '
            '(have ${_buffer.length})'),
      );
    }
    final result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }

  Future<List<int>> readSome({required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (_buffer.isEmpty) {
      if (_closed) break;
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) break;
      _waiter = Completer<void>();
      await _waiter!.future.timeout(remaining, onTimeout: () {});
    }
    final result = List<int>.from(_buffer);
    _buffer.clear();
    return result;
  }
}
