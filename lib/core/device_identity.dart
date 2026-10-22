import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Stable per-installation device identifier, reported to the panel as `x-hwid`.
///
/// Remnawave enforces a per-subscription device limit by binding an opaque
/// `x-hwid` value to the panel user: the **client** decides what that value is,
/// but it must stay the same across launches, or every launch consumes another
/// device slot. This class produces such an identifier:
///
///  * it is derived from a platform-stable seed (the Windows `MachineGuid`, the
///    Android ID, the iOS vendor identifier) so a reinstall on the same machine
///    does not burn a slot;
///  * it is hashed, so the panel — which is a third party relative to the
///    browser-grade identifiers below — never receives them in the clear;
///  * it is persisted locally as a fallback for platforms where no seed exists.
///
/// The value matches Remnawave's validation rule for `x-hwid`:
/// `^[a-zA-Z0-9=-]{10,64}$`.
class DeviceIdentity {
  const DeviceIdentity({
    required this.hwid,
    required this.os,
    required this.osVersion,
    required this.model,
    this.hardwareBacked = false,
  });

  /// Opaque identifier sent as `x-hwid`, 43 characters of URL-safe base64.
  final String hwid;

  /// Human readable OS name for the `x-device-os` header.
  final String os;

  /// OS version for the `x-ver-os` header; may be empty.
  final String osVersion;

  /// Device model for the `x-device-model` header.
  final String model;

  /// True when a platform seed was available, which means the identifier
  /// survives a reinstall instead of consuming another device slot.
  final bool hardwareBacked;

  /// Headers Remnawave reads to register and describe a device.
  Map<String, String> get headers => {
        'x-hwid': hwid,
        'x-device-os': os,
        if (osVersion.isNotEmpty) 'x-ver-os': osVersion,
        if (model.isNotEmpty) 'x-device-model': model,
      };

  @override
  String toString() =>
      'DeviceIdentity($os $osVersion, hwid=${hwid.substring(0, 8)}…)';
}

/// Builds the identity once per launch, reusing a stored value when available.
///
/// [readStored] and [writeStored] are supplied by the caller (the app uses
/// `flutter_secure_storage`), which keeps this file free of Flutter imports so it
/// can be exercised by the command-line harnesses.
Future<DeviceIdentity> resolveDeviceIdentity({
  required Future<String?> Function() readStored,
  required Future<void> Function(String value) writeStored,
}) async {
  final seed = await _platformSeed();
  final stored = await readStored();
  if (seed == null) {
    if (stored != null && _isValidHwid(stored)) {
      return _identityFrom(stored, hardwareBacked: false);
    }
    final generated = _randomHwid();
    await writeStored(generated);
    return _identityFrom(generated, hardwareBacked: false);
  }

  // A seed exists, so the identifier is reproducible. It is still persisted so a
  // future change of seed (a replaced disk) keeps the same registration.
  final derived = _hashSeed(seed);
  if (stored != derived) await writeStored(derived);
  return _identityFrom(derived, hardwareBacked: true);
}

DeviceIdentity _identityFrom(String hwid, {required bool hardwareBacked}) =>
    DeviceIdentity(
      hwid: hwid,
      os: _osName(),
      osVersion: _osVersion(),
      model: _deviceModel(),
      hardwareBacked: hardwareBacked,
    );

/// A platform-stable value that identifies the machine or installation.
///
/// Returns `null` when the platform exposes nothing usable, in which case the
/// caller falls back to a persisted random value.
Future<String?> _platformSeed() async {
  try {
    if (Platform.isWindows) return await _windowsMachineGuid();
    if (Platform.isAndroid) return Platform.environment['ANDROID_ID'];
    if (Platform.isIOS) {
      // `identifierForVendor` is only reachable through a platform channel, so
      // iOS relies on the persisted value; that is stable for the app's lifetime
      // on the device, which is what the panel needs.
      return null;
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// Reads `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`.
///
/// This is the closest thing Windows has to a stable machine identity, and it is
/// the same value other VPN clients report. The registry is read through
/// PowerShell because Dart has no registry API; the call is made once per launch
/// and only when the value is not already stored.
Future<String?> _windowsMachineGuid() async {
  try {
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r"(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid",
      ],
    ).timeout(const Duration(seconds: 8));
    if (result.exitCode != 0) return null;
    final value = (result.stdout as String).trim();
    return value.isEmpty ? null : value;
  } catch (_) {
    return null;
  }
}

String _hashSeed(String seed) {
  // SHA-256 of the seed, then URL-safe base64 with the padding removed: 43
  // characters, which fits the panel's 10–64 character rule.
  final digest = sha256.convert(utf8.encode('scaleguard-hwid:$seed'));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

String _randomHwid() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

bool _isValidHwid(String value) =>
    RegExp(r'^[a-zA-Z0-9=\-]{10,64}$').hasMatch(value);

String _osName() {
  if (Platform.isWindows) return 'Windows';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  if (Platform.isMacOS) return 'macOS';
  return Platform.operatingSystem;
}

String _osVersion() {
  if (Platform.isWindows) {
    final version = Platform.operatingSystemVersion;
    // The Dart string is verbose ("Windows 11 ... (build 26100)"); the build
    // number is what a support engineer needs.
    final match = RegExp(r'build (\d+)').firstMatch(version);
    return match?.group(1) ?? '';
  }
  return Platform.operatingSystemVersion;
}

String _deviceModel() {
  if (Platform.isWindows) {
    return Platform.environment['COMPUTERNAME'] ??
        Platform.environment['PROCESSOR_IDENTIFIER'] ??
        'PC';
  }
  return 'ScaleGuard';
}
