import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/brand_icons.dart';
import '../widgets/legal_links.dart';
import '../widgets/qr_login_actions.dart';
import '../widgets/qr_login_panel.dart';
import '../widgets/reveal.dart';
import 'email_auth_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _intro;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 820),
    )..forward();
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = SgColors.of(context);
    final yandexOn = state.authConfig?.yandexEnabled != false;
    final telegramOn = state.authConfig?.telegramEnabled != false;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const AuroraBackdrop(),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 44,
                    ),
                    child: Column(
                      children: [
                        SizedBox(height: constraints.maxHeight * 0.04),
                        Reveal(
                          controller: _intro,
                          begin: 0,
                          end: 0.5,
                          offset: 18,
                          child: const BrandMark(size: 86),
                        ),
                        const SizedBox(height: 20),
                        Reveal(
                          controller: _intro,
                          begin: 0.08,
                          end: 0.5,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [AppColors.blue, AppColors.teal],
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Text(
                              'SCALEGUARD',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.1,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Reveal(
                          controller: _intro,
                          begin: 0.14,
                          end: 0.58,
                          child: Text(
                            'Стабильное соединение\nдля любых задач',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: c.ink,
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              height: 1.18,
                              letterSpacing: -0.4,
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
                        Reveal(
                          controller: _intro,
                          begin: 0.22,
                          end: 0.68,
                          child: PressScale(
                            child: _AuthPill(
                              icon: const YandexBrandIcon(size: 26),
                              label: yandexOn
                                  ? 'Войти через Яндекс'
                                  : 'Яндекс пока недоступен',
                              busy: state.yandexPending,
                              enabled: yandexOn && !state.busy,
                              onTap: () => state.loginWithYandex(),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Reveal(
                          controller: _intro,
                          begin: 0.28,
                          end: 0.74,
                          child: PressScale(
                            child: _AuthPill(
                              icon: const TelegramBrandIcon(size: 26),
                              label: state.telegramPending
                                  ? 'Ждём подтверждение в боте'
                                  : telegramOn
                                      ? 'Войти через Telegram'
                                      : 'Telegram пока недоступен',
                              busy: state.telegramPending,
                              enabled: telegramOn && !state.busy,
                              onTap: () => state.startTelegramLogin(),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Reveal(
                          controller: _intro,
                          begin: 0.34,
                          end: 0.8,
                          child: PressScale(
                            child: _AuthPill(
                              icon: const MailBrandIcon(size: 26),
                              label: 'Войти по почте',
                              enabled: !state.busy,
                              onTap: () => _openEmailAuth(context),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Reveal(
                          controller: _intro,
                          begin: 0.38,
                          end: 0.88,
                          child: const QrLoginButtons(authScreen: true),
                        ),
                        // The code appears right here rather than in a new
                        // screen: it is an option next to the others, and a
                        // dialog would be one more thing to dismiss after the
                        // sign-in it produces.
                        if (state.qrSession != null) ...[
                          const SizedBox(height: 14),
                          QrLoginPanel(onClose: state.hideQrLogin),
                        ],
                        AnimatedSize(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          child: Column(
                            children: [
                              if (state.telegramPending ||
                                  state.yandexPending) ...[
                                const SizedBox(height: 14),
                                TextButton(
                                  onPressed: state.cancelExternalAuth,
                                  child: Text(
                                    state.telegramPending
                                        ? 'Отменить ожидание Telegram'
                                        : 'Отменить ожидание Яндекса',
                                  ),
                                ),
                              ],
                              if (state.error != null) ...[
                                const SizedBox(height: 12),
                                Text(
                                  state.error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: SgColors.red,
                                    fontSize: 13,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                              if (state.info != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  state.info!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: SgColors.green,
                                    fontSize: 13,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        const LegalLinks(compact: true),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _openEmailAuth(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const EmailAuthScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
      ),
    );
  }
}

class _AuthPill extends StatelessWidget {
  const _AuthPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.enabled = true,
  });

  final Widget icon;
  final String label;
  final VoidCallback onTap;
  final bool busy;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled || busy ? 1 : 0.55,
      child: Material(
        color: c.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: c.line),
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(22),
          child: SizedBox(
            height: 58,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: busy
                        ? const Padding(
                            padding: EdgeInsets.all(3),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: SgColors.blue,
                            ),
                          )
                        : Center(child: icon),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        label,
                        key: ValueKey(label),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
