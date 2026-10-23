import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/update_service.dart';
import '../theme/app_colors.dart';

/// The centred offer shown when GitHub has a newer release.
///
/// On Windows it downloads in the dialog and hands the installer over. On
/// Android the transfer belongs to a foreground service: the dialog starts it,
/// opens the "install unknown apps" permission when needed, and polls the
/// native progress. If the user leaves the app, the service keeps downloading
/// and its ongoing notification becomes the install button.
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    super.key,
    required this.info,
    required this.currentVersion,
    required this.onLater,
  });

  final UpdateInfo info;
  final String currentVersion;
  final VoidCallback onLater;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _busy = false;
  bool _downloading = false;
  bool _permissionNeeded = false;
  bool _installOpening = false;
  bool _polling = false;
  double? _progress;
  String _status = '';
  String? _error;
  Timer? _pollTimer;

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _update() async {
    if (_busy || _downloading || _installOpening) return;
    if (Platform.isAndroid) {
      if (_permissionNeeded && _progress != null && _progress! >= 1) {
        await _openInstaller();
        return;
      }
      await _startAndroidDownload();
      return;
    }
    await _startDesktopDownload();
  }

  Future<void> _startAndroidDownload() async {
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
      _permissionNeeded = false;
      _status = 'Запускаем загрузку…';
    });
    try {
      final start = await UpdateService.instance.startAndroidDownload(
        widget.info,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _downloading = true;
        _permissionNeeded = start.permissionRequested;
        _status = start.permissionRequested
            ? 'Загрузка уже идёт. Разрешите ScaleGuard установку из этого источника.'
            : 'Скачиваем обновление в фоне. Можно свернуть приложение.';
      });
      _startPolling();
      await _pollAndroid();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _downloading = false;
        _progress = null;
        _status = '';
        _error =
            'Не удалось запустить загрузку обновления. '
            'Проверьте подключение к интернету и попробуйте снова.';
      });
      debugPrint('android update start failed: $error');
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 700),
      (_) => unawaited(_pollAndroid()),
    );
  }

  Future<void> _pollAndroid() async {
    if (!mounted || _polling) return;
    _polling = true;
    try {
      final status = await UpdateService.instance.androidDownloadStatus();
      if (!mounted) return;
      if (status.isDownloading) {
        setState(() {
          _downloading = true;
          _busy = false;
          _progress = status.progress;
          _permissionNeeded = _permissionNeeded || !status.hasInstallPermission;
          _status = status.hasInstallPermission
              ? 'Скачиваем обновление в фоне. Можно свернуть приложение.'
              : 'Скачиваем обновление. Разрешите установку из этого источника.';
        });
        return;
      }
      if (status.isDone) {
        setState(() {
          _downloading = false;
          _busy = false;
          _progress = 1;
          _permissionNeeded = !status.hasInstallPermission;
          _status = status.hasInstallPermission
              ? 'Обновление скачано. Открываем установщик Android…'
              : 'Обновление скачано. Нажмите «Разрешить», чтобы открыть '
                    'настройки установки.';
        });
        if (status.hasInstallPermission && !_installOpening) {
          await _openInstaller();
        }
        return;
      }
      if (status.isFailed) {
        _pollTimer?.cancel();
        setState(() {
          _downloading = false;
          _busy = false;
          _progress = null;
          _status = '';
          _error = status.error?.isNotEmpty == true
              ? 'Не удалось скачать обновление: ${status.error}'
              : 'Не удалось скачать обновление. Проверьте подключение '
                    'к интернету и попробуйте снова.';
        });
      }
    } catch (error) {
      // A transient channel hiccup must not kill the background download.
      debugPrint('android update status failed: $error');
    } finally {
      _polling = false;
    }
  }

  Future<void> _openInstaller() async {
    if (_installOpening) return;
    setState(() {
      _installOpening = true;
      _busy = true;
      _status = 'Открываем установщик Android…';
    });
    try {
      final result = await UpdateService.instance.installAndroidDownload();
      if (!mounted) return;
      if (result == 'permission') {
        setState(() {
          _installOpening = false;
          _busy = false;
          _permissionNeeded = true;
          _status =
              'Разрешите ScaleGuard установку приложений в настройках '
              'Android. После возврата установщик откроется сам.';
        });
        _startPolling();
        return;
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _installOpening = false;
        _busy = false;
        _error =
            'Не удалось открыть установщик Android. '
            'Нажмите на уведомление об обновлении ещё раз.';
      });
      debugPrint('android update install failed: $error');
    }
  }

  Future<void> _startDesktopDownload() async {
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
      _status = 'Скачиваем обновление…';
    });
    try {
      final file = await UpdateService.instance.download(
        widget.info,
        onProgress: (received, total) {
          if (!mounted) return;
          final size = total > 0 ? total : widget.info.assetSize;
          setState(() {
            _progress = size > 0 ? (received / size).clamp(0.0, 1.0) : null;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _progress = 1;
        _status = 'Запускаем установщик…';
      });
      await UpdateService.instance.install(file);
      if (mounted) Navigator.of(context).pop();
    } on UpdatePermissionRequired {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _error = null;
        _status =
            'Разрешите ScaleGuard установку приложений в настройках Android, '
            'затем нажмите «Обновить» ещё раз.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _status = '';
        _error =
            'Не удалось скачать обновление. Проверьте подключение '
            'к интернету и попробуйте снова.';
      });
      debugPrint('update install failed: $error');
    }
  }

  String get _primaryLabel {
    if (_installOpening || _busy) return 'Обновляем…';
    if (_downloading) return 'Скачивается…';
    if (_permissionNeeded) return 'Разрешить';
    return 'Обновить';
  }

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final percent = _progress == null ? null : (_progress! * 100).round();
    final showProgress = _busy || _downloading || _installOpening;
    return PopScope(
      canPop: !_busy && !_installOpening,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 470),
          child: Container(
            padding: const EdgeInsets.fromLTRB(26, 24, 26, 20),
            decoration: BoxDecoration(
              color: c.sheet,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: c.line),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 40,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: SgColors.violet.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.system_update_alt_rounded,
                        color: SgColors.violet,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Доступно обновление',
                            style: TextStyle(
                              color: c.ink,
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'ScaleGuard ${widget.info.version}',
                            style: const TextStyle(
                              color: SgColors.violet,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  Platform.isAndroid
                      ? 'У вас установлена версия ${widget.currentVersion}. '
                            'Новая версия скачается в фоне, а уведомление '
                            'позволит установить её, даже если приложение закрыто.'
                      : 'У вас установлена версия ${widget.currentVersion}. '
                            'Новая версия загрузится и установится автоматически.',
                  style: TextStyle(color: c.muted, fontSize: 13, height: 1.45),
                ),
                if (widget.info.notes.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    'Что нового',
                    style: TextStyle(
                      color: c.ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 168),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: c.pill,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: c.line),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        widget.info.notes,
                        style: TextStyle(
                          color: c.muted,
                          fontSize: 12.5,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
                ],
                if (showProgress) ...[
                  const SizedBox(height: 18),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: _progress,
                      minHeight: 8,
                      backgroundColor: c.pill,
                      color: SgColors.violet,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    percent == null ? _status : '$_status $percent%',
                    style: TextStyle(color: c.faint, fontSize: 12),
                  ),
                ] else if (_status.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    _status,
                    style: TextStyle(
                      color: c.muted,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: SgColors.red,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: (_busy || _installOpening)
                          ? null
                          : widget.onLater,
                      style: TextButton.styleFrom(
                        foregroundColor: c.muted,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                      ),
                      child: const Text('Позже'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: (_busy || _downloading || _installOpening)
                          ? null
                          : _update,
                      style: FilledButton.styleFrom(
                        backgroundColor: SgColors.violet,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(_primaryLabel),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
