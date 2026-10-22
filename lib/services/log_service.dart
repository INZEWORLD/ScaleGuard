import 'dart:io';

class LogService {
  LogService._();

  static final LogService instance = LogService._();

  static const int _maxFileBytes = 2 * 1024 * 1024;

  File? _file;
  File? _fallback;
  bool _enabled = false;
  bool _fellBack = false;

  bool get enabled => _enabled;
  String? get filePath => _file?.path;

  void configure({
    required String path,
    String? fallbackPath,
    required bool enabled,
  }) {
    _enabled = false;
    _file = null;
    _fellBack = false;
    _fallback = fallbackPath == null ? null : File(fallbackPath);
    final primary = File(path);
    if (_prepare(primary)) {
      _file = primary;
    } else {
      final fallback = _fallback;
      if (fallback == null || !_prepare(fallback)) return;
      _file = fallback;
      _fellBack = true;
    }
    _enabled = enabled;
    if (enabled) {
      _write('log', 'logging started -> ${_file!.path}');
    }
  }

  void setEnabled(bool value) {
    if (_file == null || _enabled == value) return;
    _enabled = value;
    _write('log', value ? 'logging enabled' : 'logging disabled');
  }

  void log(String source, String message) {
    if (!_enabled) return;
    _write(source, message);
  }

  bool _prepare(File file) {
    try {
      final parent = file.parent;
      if (!parent.existsSync()) {
        parent.createSync(recursive: true);
      }
      if (file.existsSync() && file.lengthSync() > _maxFileBytes) {
        final rotated = File('${file.path}.1');
        if (rotated.existsSync()) rotated.deleteSync();
        file.renameSync(rotated.path);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void _write(String source, String message) {
    final file = _file;
    if (file == null) return;
    final line = '${DateTime.now().toIso8601String()} [$source] $message';
    try {
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      final fallback = _fallback;
      if (fallback != null &&
          !_fellBack &&
          fallback.path != file.path &&
          _prepare(fallback)) {
        _fellBack = true;
        _file = fallback;
        try {
          fallback.writeAsStringSync('$line\n',
              mode: FileMode.append, flush: true);
          return;
        } catch (_) {}
      }
      _enabled = false;
      _file = null;
    }
  }
}
