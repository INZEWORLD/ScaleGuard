import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../core/version_compare.dart';
import '../core/windows_shell.dart';
import '../widgets/update_dialog.dart';

/// One release published on GitHub.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.assetName,
    required this.assetUrl,
    required this.assetSize,
  });

  final String version;
  final String tag;
  final String notes;
  final String assetName;
  final String assetUrl;
  final int assetSize;
}

/// Raised when Android has to be allowed to install packages first.
class UpdatePermissionRequired implements Exception {
  const UpdatePermissionRequired();
}

/// The self-updater: GitHub Releases is the source of truth.
///
/// The repository layout the updater expects is deliberately the one a release
/// already has:
///   * `ScaleGuard-Setup-<version>.exe` — the Windows installer;
///   * `ScaleGuard-android.apk` — the Android package.
/// A release tagged `v1.2.3` and marked *Latest* is offered to every build older
/// than 1.2.3, which is exactly how clients built before this service existed
/// can still be upgraded by hand from the same page.
class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const MethodChannel _androidChannel = MethodChannel(
    'scaleguard/updater',
  );

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 45),
      headers: {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'ScaleGuard-Updater',
      },
    ),
  );

  GlobalKey<NavigatorState>? _navigatorKey;
  Future<void> Function()? _shutdown;
  bool Function()? _ready;
  Timer? _timer;
  bool _checking = false;
  bool _dialogOpen = false;
  String? _dismissedTag;
  DateTime? _lastCheck;

  String get currentVersion => _currentVersion;
  String _currentVersion = '';

  /// Starts the launch check and the hourly timer.
  ///
  /// [ready] keeps the first prompt from landing on the splash screen while the
  /// session is still being restored. [shutdown] is what the Windows build calls
  /// after it has handed the downloaded installer to the system: the tunnel has
  /// to go down and the single-instance port has to be released before the
  /// process disappears, otherwise the updater would replace a running binary.
  void start({
    required GlobalKey<NavigatorState> navigatorKey,
    required Future<void> Function() shutdown,
    bool Function()? ready,
  }) {
    _navigatorKey = navigatorKey;
    _shutdown = shutdown;
    _ready = ready;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(hours: 1), (_) {
      unawaited(check());
    });
    unawaited(_firstCheck());
  }

  Future<void> _firstCheck() async {
    // A launch is the busiest moment of the process: the session is restored,
    // the subscription is refreshed and the first frame is still being
    // measured. Four seconds is short enough to feel automatic and long enough
    // not to compete with that work.
    await Future<void>.delayed(const Duration(seconds: 4));
    for (var i = 0; i < 30; i++) {
      if (_ready?.call() ?? true) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    await check();
  }

  /// Asks GitHub for the latest release and offers it when it is newer.
  ///
  /// Returns the release that was found, whether or not it was newer, so the
  /// settings screen can say "у вас последняя версия" with confidence.
  Future<UpdateInfo?> check({bool manual = false}) async {
    if (_checking) return null;
    if (!manual && _lastCheck != null) {
      final age = DateTime.now().difference(_lastCheck!);
      if (age < const Duration(minutes: 30)) return null;
    }
    _checking = true;
    try {
      _currentVersion = await _readCurrentVersion();
      final response = await _dio.get<dynamic>(
        'https://api.github.com/repos/${AppConfig.updateRepo}/releases/latest',
      );
      final body = response.data;
      if (body is! Map) return null;
      final tag = (body['tag_name'] ?? '').toString();
      if (tag.isEmpty) return null;
      final version = tag.replaceFirst(RegExp(r'^[vV]'), '');
      if (!isNewerVersion(version, _currentVersion)) {
        _lastCheck = DateTime.now();
        if (manual) {
          _notice('У вас последняя версия ScaleGuard ($_currentVersion).');
        }
        return null;
      }
      final asset = _pickAsset(body['assets']);
      if (asset == null) {
        if (manual) {
          _notice('Обновление $version есть, но файл для этой платформы ещё не загружен.');
        }
        return null;
      }
      final info = UpdateInfo(
        version: version,
        tag: tag,
        notes: (body['body'] ?? '').toString().trim(),
        assetName: asset.name,
        assetUrl: asset.url,
        assetSize: asset.size,
      );
      _lastCheck = DateTime.now();
      if (!manual && _dismissedTag == tag) return info;
      _offer(info);
      return info;
    } catch (error) {
      // A failed update check is not an application error: the user is offline,
      // GitHub is rate-limiting or the release is not published yet. Manual
      // checks say so; automatic ones stay silent.
      if (manual) {
        _notice('Не удалось проверить обновления. Проверьте подключение к интернету.');
      }
      debugPrint('update check failed: $error');
      return null;
    } finally {
      _checking = false;
    }
  }

  /// The settings row calls this and expects user feedback either way.
  Future<void> checkManually(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Проверяем обновления…'),
        duration: Duration(seconds: 2),
      ),
    );
    await check(manual: true);
  }

  Future<String> _readCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '0.0.0';
    }
  }

  _Asset? _pickAsset(dynamic raw) {
    if (raw is! List) return null;
    final assets = <_Asset>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final name = (item['name'] ?? '').toString();
      final url = (item['browser_download_url'] ?? '').toString();
      final size = (item['size'] as num?)?.toInt() ?? 0;
      if (name.isEmpty || url.isEmpty) continue;
      assets.add(_Asset(name, url, size));
    }
    bool Function(_Asset) matches;
    if (Platform.isWindows) {
      matches = (a) =>
          a.name.toLowerCase().endsWith('.exe') &&
          a.name.toLowerCase().contains('setup');
    } else if (Platform.isAndroid) {
      matches = (a) => a.name.toLowerCase().endsWith('.apk');
    } else {
      return null;
    }
    for (final asset in assets) {
      if (matches(asset)) return asset;
    }
    return null;
  }

  void _offer(UpdateInfo info) {
    final context = _navigatorKey?.currentContext;
    if (context == null || _dialogOpen) return;
    _dialogOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (_) => UpdateDialog(
          info: info,
          currentVersion: _currentVersion,
          onLater: () {
            _dismissedTag = info.tag;
            _navigatorKey?.currentState?.pop();
          },
        ),
      ).whenComplete(() => _dialogOpen = false),
    );
  }

  /// Downloads the release asset and returns the file on disk.
  Future<File> download(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    final directory = await _downloadDirectory();
    final target = File(
      '${directory.path}${Platform.pathSeparator}${info.assetName}',
    );
    if (await target.exists()) {
      try {
        await target.delete();
      } catch (_) {}
    }
    await _dio.download(
      info.assetUrl,
      target.path,
      deleteOnError: true,
      onReceiveProgress: onProgress,
    );
    return target;
  }

  Future<Directory> _downloadDirectory() async {
    Directory base;
    if (Platform.isWindows) {
      base = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}ScaleGuardUpdate',
      );
    } else {
      final temp = await getTemporaryDirectory();
      base = Directory('${temp.path}${Platform.pathSeparator}updates');
    }
    if (!await base.exists()) await base.create(recursive: true);
    return base;
  }

  /// Hands the file to the platform installer.
  ///
  /// Windows: the setup accepts `--update`, waits for this process to release
  /// its files, installs and starts the new build. The application quits through
  /// [shutdown] so the tunnel is taken down and the single-instance port is
  /// freed before the binary is replaced.
  ///
  /// Android: the package installer is opened through a FileProvider. It asks
  /// for the "install unknown apps" permission on the first update; the caller
  /// shows that explanation.
  Future<void> install(File file) async {
    if (Platform.isWindows) {
      // The runner puts every child into a job object that is killed when this
      // process exits, which is what keeps the VPN core from outliving the
      // window. An updater is the one child that must survive that exit: without
      // this the setup is terminated before it can read its own payload, which
      // looks exactly like "the update downloaded and then nothing happened".
      await WindowsShell.setChildrenMayOutliveUs(true);
      await Process.start(
        file.path,
        const ['--update'],
        mode: ProcessStartMode.detached,
        workingDirectory: Directory.systemTemp.path,
      );
      // Give the installer a moment to show its window before the parent
      // disappears; a child that starts as the parent exits is fine, but a
      // visible hand-over is less alarming.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      try {
        await _shutdown?.call();
      } finally {
        exit(0);
      }
    }
    if (Platform.isAndroid) {
      final result = await _androidChannel.invokeMethod<String>(
        'installApk',
        {'path': file.path},
      );
      if (result == 'permission') throw const UpdatePermissionRequired();
      return;
    }
    throw UnsupportedError('Обновление не поддерживается на этой платформе.');
  }

  void _notice(String message) {
    final context = _navigatorKey?.currentContext;
    if (context == null) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

class _Asset {
  const _Asset(this.name, this.url, this.size);
  final String name;
  final String url;
  final int size;
}
