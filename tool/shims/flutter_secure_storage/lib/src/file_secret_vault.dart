import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Secrets stored in a JSON file that only the current user can read.
///
/// Used on platforms where the application does not build the upstream
/// `flutter_secure_storage` native implementation. On Android and iOS the file
/// lives in the application's own private directory, which the operating system
/// already restricts to this application; on desktop the user's own profile
/// directory holds it, and an explicit ACL is added where that is possible.
class FileSecretVault {
  FileSecretVault({String? directory}) : _explicitDirectory = directory;

  /// A directory the caller named. Only the development harness uses this.
  final String? _explicitDirectory;

  /// Where the file really goes.
  ///
  /// Resolved once per process: every call to the surrounding package builds a
  /// new vault, and asking the platform for a directory on each read and write
  /// would turn a simple preference into a channel round-trip.
  static Future<String>? _sharedDirectory;

  Map<String, String>? _cache;

  static const String _folderName = 'ScaleGuard';
  static const String _fileName = 'secrets.json';

  Future<String> _directory() {
    final explicit = _explicitDirectory;
    if (explicit != null) return Future<String>.value(explicit);
    return _sharedDirectory ??= _resolveDefaultDirectory();
  }

  /// Picks the first directory this application is actually allowed to write to.
  ///
  /// Android has no `APPDATA`: the variable is unset, and the fallback that was
  /// used here — the current directory — is the read-only filesystem root, so
  /// every write ended in `Creation failed, path = '//ScaleGuard'`. That single
  /// failure is what broke sign-in: the token could never be saved, whether it
  /// arrived from a password, a QR code or Yandex. `path_provider` hands back
  /// the application's private directory instead, which is writable and
  /// survives updates.
  static Future<String> _resolveDefaultDirectory() async {
    final candidates = <String>[];

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final support = await getApplicationSupportDirectory();
        if (support.path.trim().isNotEmpty) candidates.add(support.path);
      } catch (_) {
        // No platform channel (a test, or a stripped build): fall through to
        // the temporary directory, which is still writable.
      }
    }

    for (final key in const ['APPDATA', 'LOCALAPPDATA', 'HOME', 'USERPROFILE']) {
      final value = Platform.environment[key];
      if (value != null && value.trim().isNotEmpty) {
        candidates.add(value);
      }
    }
    candidates.add(Directory.systemTemp.path);

    for (final base in candidates) {
      final path = '$base${Platform.pathSeparator}$_folderName';
      try {
        final directory = Directory(path);
        if (!directory.existsSync()) directory.createSync(recursive: true);
        return path;
      } catch (_) {
        continue;
      }
    }
    return '${Directory.systemTemp.path}${Platform.pathSeparator}$_folderName';
  }

  Future<File> _file() async =>
      File('${await _directory()}${Platform.pathSeparator}$_fileName');

  Future<Map<String, String>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    try {
      final file = await _file();
      if (!file.existsSync()) return _cache = <String, String>{};
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return _cache = decoded.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      }
    } catch (_) {
      // A corrupt file must not lock the user out of the application.
    }
    return _cache = <String, String>{};
  }

  Future<void> _persist(Map<String, String> values) async {
    final directory = Directory(await _directory());
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    final file = await _file();
    await file.writeAsString(jsonEncode(values), flush: true);
    await _restrictPermissions(file);
  }

  /// Best-effort hardening: keep the file readable only by its owner.
  Future<void> _restrictPermissions(File file) async {
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', file.path]);
      } catch (_) {}
      return;
    }
    try {
      final user = Platform.environment['USERNAME'];
      if (user == null || user.isEmpty) return;
      await Process.run('icacls', [
        file.path,
        '/inheritance:r',
        '/grant:r',
        '$user:F',
      ]);
    } catch (_) {
      // Hardening is best effort and must never break a login.
    }
  }

  Future<void> write(String key, String value) async {
    final values = Map<String, String>.from(await _load());
    values[key] = value;
    await _persist(values);
  }

  Future<String?> read(String key) async {
    final values = await _load();
    return values[key];
  }

  Future<void> delete(String key) async {
    final values = Map<String, String>.from(await _load());
    if (values.remove(key) == null) return;
    await _persist(values);
  }

  Future<Map<String, String>> readAll() async =>
      Map<String, String>.from(await _load());

  Future<void> deleteAll() async {
    _cache = <String, String>{};
    final file = await _file();
    if (file.existsSync()) {
      await file.delete();
    }
  }
}
