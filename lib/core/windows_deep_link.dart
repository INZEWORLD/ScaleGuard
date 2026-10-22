import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Registers the `scaleguard://` URL scheme with Windows.
///
/// The desktop login flows (Yandex OAuth, and any future web flow) finish by
/// redirecting the browser to `scaleguard://oauth?oauth_token=…`. On mobile the
/// operating system knows which application owns that scheme because it is
/// declared in the manifest; on Windows nothing knows unless an installer writes
/// it, so without this the browser shows an error and the user never gets back
/// into the application with their token.
///
/// Entries go under `HKCU\Software\Classes`, which is per-user and therefore
/// needs no elevation. The registration is written on every launch, which also
/// repairs a stale path after the application is moved.
class WindowsDeepLinkRegistration {
  WindowsDeepLinkRegistration({
    this.scheme = 'scaleguard',
    this.description = 'ScaleGuard',
  });

  /// Scheme to claim, without the `://`.
  final String scheme;

  /// Friendly name Windows shows when asking the user to confirm.
  final String description;

  bool get isSupported => Platform.isWindows;

  /// Returns `true` when the scheme now points at this executable.
  Future<bool> ensureRegistered({String? executablePath}) async {
    if (!isSupported) return false;
    final executable = executablePath ?? Platform.resolvedExecutable;
    if (executable.isEmpty) return false;

    final script = '''
\$ErrorActionPreference = 'Stop'
\$scheme = 'HKCU:\\Software\\Classes\\$scheme'
New-Item -Path \$scheme -Force | Out-Null
Set-ItemProperty -Path \$scheme -Name '(default)' -Value 'URL:$description Protocol'
Set-ItemProperty -Path \$scheme -Name 'URL Protocol' -Value ''
New-Item -Path "\$scheme\\DefaultIcon" -Force | Out-Null
Set-ItemProperty -Path "\$scheme\\DefaultIcon" -Name '(default)' -Value '$executable,0'
New-Item -Path "\$scheme\\shell\\open\\command" -Force | Out-Null
Set-ItemProperty -Path "\$scheme\\shell\\open\\command" -Name '(default)' -Value '"$executable" "%1"'
'ok'
''';

    try {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'scaleguard-deeplink.ps1',
      );
      // A UTF-8 BOM is what makes PowerShell read the file as UTF-8; the script
      // contains only ASCII, but the executable path may not.
      await file.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(script)]);
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          file.path,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      await file.delete().catchError((_) => file);
      if (result.exitCode != 0) {
        lastError = (result.stderr as String).trim();
        return false;
      }
      lastError = null;
      return true;
    } catch (error) {
      lastError = error.toString();
      return false;
    }
  }

  /// Reads back the registered command, which is how a stale registration after
  /// an application move is detected.
  Future<String?> registeredCommand() async {
    if (!isSupported) return null;
    final script = '''
\$key = 'HKCU:\\Software\\Classes\\$scheme\\shell\\open\\command'
if (Test-Path \$key) { (Get-ItemProperty -Path \$key).'(default)' } else { '' }
''';
    try {
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'scaleguard-deeplink-read.ps1',
      );
      await file.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(script)]);
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        file.path,
      ]);
      await file.delete().catchError((_) => file);
      if (result.exitCode != 0) return null;
      final value = (result.stdout as String).trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// Diagnostic detail from the most recent failed call.
  String? lastError;
}

/// Prevents a second application window when Windows relaunches the
/// executable — most often right after an OAuth login, when the browser
/// activates `scaleguard://…`.
///
/// The registered launch command is `"<exe>" "%1"`, so every protocol
/// activation starts a new process. That new process must not run the full
/// application: it would open a second window and keep the token to itself.
/// The gate claims a loopback port for the lifetime of the primary instance; a
/// secondary launch fails to bind, hands its URL (if any) to the primary over
/// that port and exits before any window is created.
class WindowsSingleInstanceGate {
  WindowsSingleInstanceGate._();

  /// Loopback port reserved for the ScaleGuard instance handshake.
  static const int handshakePort = 45973;

  static const String _schemePrefix = 'scaleguard:';

  static final StreamController<String> _incomingLinks =
      StreamController<String>.broadcast();

  static ServerSocket? _server;
  static String? _launchUri;

  /// Protocol URLs forwarded to this instance by secondary launches.
  static Stream<String> get incomingLinks => _incomingLinks.stream;

  /// The protocol URL this process itself was started with, if any.
  static String? consumeLaunchUri() {
    final value = _launchUri;
    _launchUri = null;
    return value;
  }

  /// Claims the handshake port. Returns `false` when another ScaleGuard
  /// instance answered, in which case the caller must exit without showing a
  /// window.
  static Future<bool> start(List<String> args) async {
    if (!Platform.isWindows) return true;
    _launchUri = _extractUri(args);
    return _claim();
  }

  /// Claims the handshake port after [release], leaving the launch URI alone.
  ///
  /// Used by the instance that released the port for a replacement and then
  /// found out that none arrived: it is still the window on screen, so it has to
  /// be the one holding the port again — otherwise the next double click would
  /// open a second window next to it.
  static Future<bool> reclaim() async {
    if (!Platform.isWindows) return true;
    return _claim();
  }

  static Future<bool> _claim() async {
    try {
      _server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        handshakePort,
      );
      _server!.listen(_forwardClient, onError: (_) {});
      return true;
    } catch (_) {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          handshakePort,
          timeout: const Duration(milliseconds: 800),
        );
        socket.write(_launchUri ?? '');
        await socket.flush();
        socket.destroy();
      } catch (_) {}
      return false;
    }
  }

  /// Releases the handshake port so a replacement process can claim it.
  ///
  /// Used right before this instance restarts itself elevated: the elevated copy
  /// has to be able to bind the port, otherwise it would find it taken, treat
  /// itself as a duplicate and exit without ever showing a window.
  static Future<void> release() async {
    final server = _server;
    _server = null;
    if (server == null) return;
    try {
      await server.close();
    } catch (_) {}
  }

  /// Whether another instance is listening for launches.
  ///
  /// Used after asking the helper task to start an elevated copy: that copy
  /// becoming the primary instance is the only proof that the request was
  /// honoured. Without the check a task Windows declined to start would look like
  /// a success while the user is left with no window at all.
  static Future<bool> isHeldByAnotherInstance({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!Platform.isWindows) return false;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          handshakePort,
          timeout: const Duration(milliseconds: 600),
        );
        // No payload on purpose: the listener treats an empty line as "no URL"
        // and only forwards protocol links.
        socket.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    return false;
  }

  static String? _extractUri(List<String> args) {
    for (final arg in args) {
      // Surrounding quotes are stripped defensively: a protocol handler is a
      // registry value somebody else may have written, and a stray pair of
      // quotes would otherwise hide the link from every check below.
      var trimmed = arg.trim();
      if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
        trimmed = trimmed.substring(1, trimmed.length - 1).trim();
      }
      if (trimmed.startsWith(_schemePrefix)) return trimmed;
    }
    return null;
  }

  /// The protocol URL this process was started with, read from its arguments.
  ///
  /// Exposed because the launcher has to look at it *before* the elevation
  /// decision: a browser activation arrives at a process that is about to be
  /// replaced, and a URL discovered afterwards is a URL already lost.
  static String? launchUriFrom(List<String> args) => _extractUri(args);

  /// Hands [uri] to the instance that already owns the handshake port.
  ///
  /// Returns `false` when nothing answered — the application is not running, or
  /// it is on its way down — and the caller then owns the URL and has to see it
  /// through itself. Returns `true` only after the payload has been written to a
  /// socket the running instance accepted, so a `true` never means "probably".
  static Future<bool> forwardToRunningInstance(
    String uri, {
    Duration timeout = const Duration(milliseconds: 800),
    int attempts = 3,
  }) async {
    if (!Platform.isWindows) return false;
    final trimmed = uri.trim();
    if (!trimmed.startsWith(_schemePrefix)) return false;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          handshakePort,
          timeout: timeout,
        );
        socket.write(trimmed);
        await socket.flush();
        socket.destroy();
        return true;
      } catch (_) {
        // A refused connection arrives instantly, so retrying costs almost
        // nothing; it exists to close the window in which a running instance is
        // between two of its own operations and a lone attempt would see it as
        // absent — which would send the user's login down the cold-start path
        // instead of into the window they are looking at.
        if (attempt + 1 < attempts) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    }
    return false;
  }

  static void _forwardClient(Socket socket) {
    final chunks = <String>[];
    socket.cast<List<int>>().transform(utf8.decoder).listen(
      chunks.add,
      onDone: () {
        socket.destroy();
        final raw = chunks.join().trim();
        // An empty payload is a plain double launch: nothing to forward, the
        // duplicate instance just exits.
        if (raw.isEmpty || !raw.startsWith(_schemePrefix)) return;
        // The running instance is about to act on this link, so a copy the
        // caller may have parked on disk is now both useless and a replay risk.
        unawaited(WindowsPendingDeepLink.clear());
        _incomingLinks.add(raw);
      },
      onError: (_) => socket.destroy(),
      cancelOnError: true,
    );
  }
}

/// A protocol URL left behind for the instance that is about to start.
///
/// The link has to survive the elevation hand-off. When "always run as
/// administrator" is on, the browser's process does not become the application
/// at all: it asks the helper task to start an elevated copy, and a scheduled
/// task has one fixed command line that cannot carry the browser's argument.
/// Writing the URL to a file the replacement reads on its way up is what keeps a
/// Yandex login from silently evaporating at exactly that moment.
///
/// The file lives next to the other per-user state, in a directory the elevated
/// copy can reach because the task runs as the same interactive user.
class WindowsPendingDeepLink {
  WindowsPendingDeepLink._();

  /// A link older than this is treated as abandoned.
  ///
  /// OAuth tokens are short-lived and a stale file would otherwise be replayed
  /// on every later start, failing a login the user has long since finished.
  static const Duration maxAge = Duration(minutes: 10);

  /// Directory used instead of the real per-user state folder.
  ///
  /// Present so a test can exercise the round trip without touching the file a
  /// real login may be parked in; nothing in the application ever sets it.
  static String? directoryOverride;

  static Future<File?> _file() async {
    final override = directoryOverride;
    final base = override ?? Platform.environment['APPDATA']?.trim();
    final root = base != null && base.isNotEmpty
        ? Directory(
            override != null ? base : '$base${Platform.pathSeparator}ScaleGuard',
          )
        : Directory(
            '${Directory.systemTemp.path}${Platform.pathSeparator}ScaleGuard',
          );
    try {
      await root.create(recursive: true);
    } catch (_) {
      return null;
    }
    return File('${root.path}${Platform.pathSeparator}pending-deep-link.txt');
  }

  /// Saves [uri] for the instance that starts next.
  static Future<bool> store(String uri) async {
    if (!Platform.isWindows) return false;
    final trimmed = uri.trim();
    if (trimmed.isEmpty) return false;
    final file = await _file();
    if (file == null) return false;
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      await file.writeAsString('$stamp\n$trimmed', flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Reads the saved link, deleting it in the same breath so it is used once.
  static Future<String?> consume() async {
    if (!Platform.isWindows) return null;
    final file = await _file();
    if (file == null || !file.existsSync()) return null;
    try {
      final raw = await file.readAsString();
      await file.delete();
      final separator = raw.indexOf('\n');
      if (separator <= 0) return null;
      final stamp = int.tryParse(raw.substring(0, separator).trim());
      final uri = raw.substring(separator + 1).trim();
      if (stamp == null || uri.isEmpty) return null;
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(stamp),
      );
      if (age.isNegative || age > maxAge) return null;
      return uri;
    } catch (_) {
      return null;
    }
  }

  /// Drops a saved link without using it.
  ///
  /// Called once a link has been delivered over the handshake port: the running
  /// instance is the one that acts on it, so leaving a copy on disk would only
  /// risk replaying it on a later start.
  static Future<void> clear() async {
    if (!Platform.isWindows) return;
    final file = await _file();
    if (file == null) return;
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // Nothing to do: [consume] ignores a stale file anyway.
    }
  }
}
