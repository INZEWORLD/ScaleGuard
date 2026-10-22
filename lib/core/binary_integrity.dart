import 'dart:io';

import 'package:crypto/crypto.dart';

/// One file covered by the manifest.
class IntegrityEntry {
  const IntegrityEntry({
    required this.name,
    required this.expected,
    required this.actual,
    required this.present,
  });

  final String name;
  final String expected;
  final String? actual;
  final bool present;

  bool get matches => present && actual == expected;
}

/// Outcome of checking the bundled binaries against their manifest.
enum IntegrityStatus {
  /// Every listed file is present and matches its digest.
  verified,

  /// No manifest next to the core — an installation that predates the check.
  /// Reported, but never a reason to refuse to start.
  manifestMissing,

  /// At least one file is missing or does not match its digest.
  mismatch,

  /// The check could not run (not Windows, unreadable files).
  unavailable,
}

class IntegrityReport {
  const IntegrityReport(this.status, this.entries, [this.message]);

  const IntegrityReport.unavailable([String? message])
      : status = IntegrityStatus.unavailable,
        entries = const <IntegrityEntry>[],
        message = message;

  final IntegrityStatus status;
  final List<IntegrityEntry> entries;
  final String? message;

  bool get isMismatch => status == IntegrityStatus.mismatch;

  /// Human-readable summary for the settings screen and the log.
  String get summary {
    switch (status) {
      case IntegrityStatus.verified:
        return 'Ядро и сетевой драйвер совпадают с контрольными суммами';
      case IntegrityStatus.manifestMissing:
        return 'Контрольные суммы не найдены — проверка не выполнялась';
      case IntegrityStatus.mismatch:
        final broken = entries.where((entry) => !entry.matches);
        return 'Проверка целостности не пройдена: '
            '${broken.map((entry) => entry.name).join(', ')}';
      case IntegrityStatus.unavailable:
        return message ?? 'Проверка целостности недоступна';
    }
  }
}

/// Verifies the bundled core against the digests recorded at build time.
///
/// The core is launched with an administrator token, so a swapped or truncated
/// `mihomo.exe` is the most direct way for anything that can write to the
/// application directory to gain those rights. A manifest next to the binaries
/// cannot make that impossible — whoever replaced the binary could replace the
/// manifest too — but it does turn a silent substitution into a visible,
/// blocking error, and it catches the far more common case of a corrupted or
/// half-copied file.
///
/// Regenerate the manifest with `dart run tool/write_core_manifest.dart` after
/// changing either binary.
class BinaryIntegrity {
  const BinaryIntegrity();

  /// Digest file, in `sha256sum` format.
  static const String manifestName = 'SHA256SUMS';

  Future<IntegrityReport> verifyDirectory(Directory directory) async {
    if (!Platform.isWindows) return const IntegrityReport.unavailable();
    try {
      final manifest = File(
        '${directory.path}${Platform.pathSeparator}$manifestName',
      );
      if (!manifest.existsSync()) {
        return const IntegrityReport(IntegrityStatus.manifestMissing, []);
      }
      final entries = <IntegrityEntry>[];
      for (final line in await manifest.readAsLines()) {
        final parsed = _parseLine(line);
        if (parsed == null) continue;
        final file = File('${directory.path}${Platform.pathSeparator}${parsed.$2}');
        if (!file.existsSync()) {
          entries.add(
            IntegrityEntry(
              name: parsed.$2,
              expected: parsed.$1,
              actual: null,
              present: false,
            ),
          );
          continue;
        }
        entries.add(
          IntegrityEntry(
            name: parsed.$2,
            expected: parsed.$1,
            actual: await _digest(file),
            present: true,
          ),
        );
      }
      if (entries.isEmpty) {
        return const IntegrityReport(IntegrityStatus.manifestMissing, []);
      }
      final ok = entries.every((entry) => entry.matches);
      return IntegrityReport(
        ok ? IntegrityStatus.verified : IntegrityStatus.mismatch,
        entries,
      );
    } catch (error) {
      return IntegrityReport.unavailable(error.toString());
    }
  }

  /// `sha256sum` line: 64 hex characters, two spaces, the file name.
  (String, String)? _parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return null;
    final separator = trimmed.indexOf(RegExp(r'\s+'));
    if (separator <= 0) return null;
    final digest = trimmed.substring(0, separator).toLowerCase();
    final name = trimmed.substring(separator).trim().replaceFirst('*', '');
    if (digest.length != 64 || !RegExp(r'^[0-9a-f]+$').hasMatch(digest)) {
      return null;
    }
    if (name.isEmpty) return null;
    return (digest, name);
  }

  /// Streams the file so a large core binary never has to be held in memory.
  Future<String> _digest(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// Builds the manifest content for [files] that exist.
  static Future<String> buildManifest(List<File> files) async {
    final lines = <String>[];
    for (final file in files) {
      if (!file.existsSync()) continue;
      final digest = await sha256.bind(file.openRead()).first;
      lines.add('${digest.toString()}  ${_basename(file.path)}');
    }
    return lines.join('\n');
  }

  static String _basename(String path) {
    final index = path.lastIndexOf(RegExp(r'[\\/]'));
    return index < 0 ? path : path.substring(index + 1);
  }
}
