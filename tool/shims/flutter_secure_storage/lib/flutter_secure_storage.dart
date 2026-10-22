/// Dependency-substituted stand-in for `package:flutter_secure_storage`.
///
/// ScaleGuard replaces the upstream package because its Windows implementation
/// is written in C++ and requires the ATL headers from an optional Visual Studio
/// workload. This package offers the same Dart API and keeps secrets protected
/// with no extra build requirement:
///
///  * **Windows** — the Windows Credential Manager, through `dart:ffi`, so the
///    secret is encrypted by the operating system and bound to the account.
///  * **Other platforms** — a JSON file that is restricted to the current user
///    and lives in the per-user application data directory.
///
/// The application only uses `read`, `write` and `delete`, so those are the
/// methods implemented here; anything else throws [UnsupportedError] rather
/// than silently doing nothing.
library;

import 'dart:io';

import 'src/file_secret_vault.dart';
import 'src/windows_credential_vault.dart';

/// Android-specific options.
class AndroidOptions {
  const AndroidOptions({
    this.encryptedSharedPreferences = true,
    this.resetOnError = false,
  });

  final bool encryptedSharedPreferences;
  final bool resetOnError;
}

/// iOS/macOS-specific options.
class IOSOptions {
  const IOSOptions({this.accessibility, this.accountName});
  final Object? accessibility;
  final String? accountName;
}

/// Windows-specific options.
class WindowsOptions {
  const WindowsOptions({this.useBackwardCompatibility = false});
  final bool useBackwardCompatibility;
}

/// Linux-specific options.
class LinuxOptions {
  const LinuxOptions();
}

/// Web-specific options.
class WebOptions {
  const WebOptions();
}

/// The subset of the upstream API the application relies on.
class FlutterSecureStorage {
  const FlutterSecureStorage({
    this.aOptions,
    this.iOptions,
    this.wOptions,
    this.lOptions,
    this.webOptions,
  });

  final AndroidOptions? aOptions;
  final IOSOptions? iOptions;
  final WindowsOptions? wOptions;
  final LinuxOptions? lOptions;
  final WebOptions? webOptions;

  WindowsCredentialVault? get _windows =>
      Platform.isWindows ? WindowsCredentialVault() : null;

  FileSecretVault? get _file =>
      Platform.isWindows ? null : FileSecretVault();

  Future<void> write({
    required String key,
    required String? value,
    AndroidOptions? aOptions,
    IOSOptions? iOptions,
    WindowsOptions? wOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
  }) async {
    if (value == null) {
      await delete(key: key);
      return;
    }
    final windows = _windows;
    if (windows != null) return windows.write(key, value);
    return _file!.write(key, value);
  }

  Future<String?> read({
    required String key,
    AndroidOptions? aOptions,
    IOSOptions? iOptions,
    WindowsOptions? wOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
  }) async {
    final windows = _windows;
    if (windows != null) return windows.read(key);
    return _file!.read(key);
  }

  Future<void> delete({
    required String key,
    AndroidOptions? aOptions,
    IOSOptions? iOptions,
    WindowsOptions? wOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
  }) async {
    final windows = _windows;
    if (windows != null) return windows.delete(key);
    return _file!.delete(key);
  }

  Future<Map<String, String>> readAll({
    AndroidOptions? aOptions,
    IOSOptions? iOptions,
    WindowsOptions? wOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
  }) async {
    final windows = _windows;
    if (windows != null) return windows.readAll();
    return _file!.readAll();
  }

  Future<void> deleteAll({
    AndroidOptions? aOptions,
    IOSOptions? iOptions,
    WindowsOptions? wOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
  }) async {
    final windows = _windows;
    if (windows != null) {
      throw UnsupportedError(
        'Удаление всех секретов не поддерживается: хранилище Windows содержит '
        'записи других приложений.',
      );
    }
    return _file!.deleteAll();
  }

  Future<bool> containsKey({
    required String key,
    AndroidOptions? aOptions,
    IOSOptions? iOptions,
    WindowsOptions? wOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
  }) async =>
      (await read(key: key)) != null;
}
