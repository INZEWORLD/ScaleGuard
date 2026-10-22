import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win32;

/// Windows Credential Manager, reached through `dart:ffi`.
///
/// The upstream `flutter_secure_storage` Windows implementation is C++ and needs
/// the ATL headers, which belong to an optional Visual Studio workload. Talking
/// to `Advapi32` directly gives the same protection — the secret is encrypted at
/// rest by the operating system and bound to the signed-in account — without
/// adding a build requirement.
class WindowsCredentialVault {
  WindowsCredentialVault({this.serviceName = 'ScaleGuard'});

  /// Prefix that namespaces our entries inside the shared user vault.
  final String serviceName;

  bool get isSupported => Platform.isWindows;

  String _target(String key) => '$serviceName:$key';

  /// A null `PWSTR`, used for the optional credential fields.
  win32.PWSTR get _noString => win32.PWSTR(nullptr);

  /// Stores or replaces [key].
  Future<void> write(String key, String value) async {
    final targetName = _target(key);
    final target = targetName.toNativeUtf16();
    final username = 'ScaleGuard'.toNativeUtf16();
    final secret = utf8.encode(value);
    final blob = calloc<Uint8>(secret.isEmpty ? 1 : secret.length);
    final credential = calloc<win32.CREDENTIAL>();
    try {
      if (secret.isNotEmpty) {
        blob.asTypedList(secret.length).setAll(0, secret);
      }
      credential.ref
        ..Flags = win32.CRED_FLAGS(0)
        ..Type = win32.CRED_TYPE_GENERIC
        ..TargetName = win32.PWSTR(target)
        ..Comment = _noString
        ..CredentialBlobSize = secret.length
        ..CredentialBlob = blob
        ..Persist = win32.CRED_PERSIST_LOCAL_MACHINE
        ..AttributeCount = 0
        ..Attributes = nullptr
        ..TargetAlias = _noString
        ..UserName = win32.PWSTR(username);

      final result = win32.CredWrite(credential, 0);
      if (!result.value) {
        throw StateError(
          'Не удалось сохранить секрет в Windows Credential Manager '
          '(код ${result.error.code})',
        );
      }
    } finally {
      calloc.free(credential);
      calloc.free(blob);
      calloc.free(target);
      calloc.free(username);
    }
  }

  /// Returns the stored secret, or `null` when the key does not exist.
  Future<String?> read(String key) async {
    final target = _target(key).toNativeUtf16();
    final credentialPtr = calloc<Pointer<win32.CREDENTIAL>>();
    try {
      final result = win32.CredRead(
        win32.PCWSTR(target),
        win32.CRED_TYPE_GENERIC,
        credentialPtr,
      );
      if (!result.value) {
        if (result.error.code == win32.ERROR_NOT_FOUND) return null;
        throw StateError(
          'Не удалось прочитать секрет из Windows Credential Manager '
          '(код ${result.error.code})',
        );
      }
      final credential = credentialPtr.value;
      try {
        final reference = credential.ref;
        final size = reference.CredentialBlobSize;
        if (size == 0 || reference.CredentialBlob == nullptr) return '';
        final bytes = reference.CredentialBlob.asTypedList(size);
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        win32.CredFree(credential.cast());
      }
    } finally {
      calloc.free(target);
      calloc.free(credentialPtr);
    }
  }

  /// Removes [key]. Removing an absent key is not an error for callers.
  Future<void> delete(String key) async {
    final target = _target(key).toNativeUtf16();
    try {
      final result = win32.CredDelete(
        win32.PCWSTR(target),
        win32.CRED_TYPE_GENERIC,
      );
      if (!result.value && result.error.code != win32.ERROR_NOT_FOUND) {
        throw StateError(
          'Не удалось удалить секрет из Windows Credential Manager '
          '(код ${result.error.code})',
        );
      }
    } finally {
      calloc.free(target);
    }
  }

  /// Enumerating the vault would expose every credential of the signed-in user,
  /// so listing is intentionally limited to an empty result. The application
  /// always knows the keys it wrote.
  Future<Map<String, String>> readAll() async => const <String, String>{};
}
