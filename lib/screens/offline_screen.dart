import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';

/// Shown when the last launch could not reach the server at all.
///
/// A request that never left the device is not evidence that the password is
/// wrong, so the sign-in screen is the wrong answer: it invites the user to
/// retype credentials they may not even need. This page says what actually
/// happened and offers a retry, plus the cached-node escape hatch when the
/// account API is down but the subscription servers are still reachable.
class OfflineScreen extends StatefulWidget {
  const OfflineScreen({super.key});

  @override
  State<OfflineScreen> createState() => _OfflineScreenState();
}

class _OfflineScreenState extends State<OfflineScreen> {
  bool _retrying = false;
  bool _enteringOffline = false;

  bool get _busy => _retrying || _enteringOffline;

  Future<void> _retry() async {
    if (_busy) return;
    setState(() => _retrying = true);
    try {
      await context.read<AppState>().retryConnection();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _enterOffline() async {
    if (_busy) return;
    final state = context.read<AppState>();
    setState(() => _enteringOffline = true);
    try {
      final entered = await state.enterOfflineMode();
      if (!entered && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              state.error ?? 'Нет сохранённых серверов для офлайн-режима.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _enteringOffline = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = SgColors.of(context);
    final canGoOffline = state.canUseOfflineMode;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const AuroraBackdrop(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const BrandMark(size: 84),
                      const SizedBox(height: 28),
                      Container(
                        width: 68,
                        height: 68,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              SgColors.red,
                              SgColors.red.withValues(alpha: 0.72),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: SgColors.red.withValues(alpha: 0.35),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.wifi_off_rounded,
                          size: 32,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Нет подключения',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: c.ink,
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.6,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Не удалось связаться с сервером ScaleGuard. '
                        'Интернет может работать — проблема на стороне '
                        'сервиса. Если сессия уже сохранена, можно продолжить '
                        'с последними загруженными серверами.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: c.muted,
                          fontSize: 13.5,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 26),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton(
                          onPressed: _busy ? null : _retry,
                          style: FilledButton.styleFrom(
                            backgroundColor: SgColors.blue,
                            disabledBackgroundColor: SgColors.blue.withValues(
                              alpha: 0.5,
                            ),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: _retrying
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                )
                              : const Text(
                                  'Повторить',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: OutlinedButton.icon(
                          onPressed: canGoOffline && !_busy
                              ? _enterOffline
                              : null,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: SgColors.violet,
                            disabledForegroundColor: c.faint,
                            side: BorderSide(
                              color: canGoOffline
                                  ? SgColors.violet.withValues(alpha: 0.55)
                                  : c.line,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          icon: _enteringOffline
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      SgColors.violet,
                                    ),
                                  ),
                                )
                              : const Icon(Icons.cloud_off_rounded, size: 20),
                          label: const Text(
                            'Офлайн-режим',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        canGoOffline
                            ? 'Подключение к сохранённым серверам, даже если '
                                  'сервер аккаунта недоступен. Тарифы и покупки '
                                  'временно не работают.'
                            : 'Офлайн-режим станет доступен после одного '
                                  'успешного входа и загрузки списка серверов.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.faint, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
