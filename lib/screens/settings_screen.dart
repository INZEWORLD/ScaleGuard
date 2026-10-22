import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../services/update_service.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/qr_login_actions.dart';
import 'app_settings_screen.dart';
import 'connection_settings_screen.dart';
import 'privacy_policy_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = SgColors.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (!embedded) const AuroraBackdrop(),
          SafeArea(
            bottom: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 108),
              children: [
                if (!embedded)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.arrow_back_rounded, color: c.ink),
                    ),
                  ),
                Text(
                  'Настройки',
                  style: TextStyle(color: c.ink, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -0.8),
                ),
                const SizedBox(height: 16),
                _Card(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              state.user?.email ?? 'ScaleGuard',
                              style: TextStyle(color: c.ink, fontWeight: FontWeight.w800, fontSize: 16),
                            ),
                            const SizedBox(height: 4),
                            Text('Аккаунт', style: TextStyle(color: c.faint, fontSize: 13)),
                          ],
                        ),
                      ),
                      if (state.tunnel?.hasActiveSubscription == true)
                        Text(
                          'Активен до ${state.vpn.formatExpiry(state.tunnel?.expireAt)}',
                          style: const TextStyle(
                            color: SgColors.violet,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.3,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Card(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Column(
                    children: [
                      _NavTile(
                        icon: Icons.settings_outlined,
                        title: 'Настройки приложения',
                        subtitle: 'Автозапуск, уведомления, разрешения и оформление',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AppSettingsScreen(),
                          ),
                        ),
                      ),
                      _NavTile(
                        icon: Icons.tune_rounded,
                        title: 'Настройка подключения',
                        subtitle: 'Режим работы, игровой профиль и свои домены',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ConnectionSettingsScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Card(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Column(
                    children: [
                      _LinkTile(
                        icon: Icons.support_agent_rounded,
                        title: 'Поддержка в Telegram',
                        subtitle: 'Поможем с подключением, оплатой и подпиской',
                        url: AppConfig.supportUrl,
                      ),
                      _LinkTile(
                        icon: Icons.campaign_outlined,
                        title: 'Наш Telegram-канал',
                        subtitle: 'Новости, новые локации и акции',
                        url: AppConfig.telegramChannelUrl,
                      ),
                      _LinkTile(
                        icon: Icons.forum_outlined,
                        title: 'Наш Discord',
                        subtitle: 'Сообщество: общение и помощь участников',
                        url: AppConfig.discordUrl,
                      ),
                      _LinkTile(
                        icon: Icons.description_outlined,
                        title: 'Условия использования',
                        subtitle: 'Правила сервиса, тарифы и оплата',
                        url: AppConfig.termsUrl,
                      ),
                      _LinkTile(
                        icon: Icons.privacy_tip_outlined,
                        title: 'Политика конфиденциальности',
                        subtitle: 'Какие данные храним и зачем',
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyScreen()),
                          );
                        },
                      ),
                      const _UpdateTile(),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                        leading: const Icon(Icons.logout_rounded, color: SgColors.red),
                        title: const Text('Выйти', style: TextStyle(color: SgColors.red)),
                        subtitle: const Text(
                          'Отключит доступ на этом устройстве',
                          style: TextStyle(fontSize: 12),
                        ),
                        onTap: () async {
                          if (Navigator.of(context).canPop()) {
                            Navigator.pop(context);
                          }
                          await state.logout();
                        },
                      ),
                      // Signing in on another device without a password, from
                      // the account that is already open here.
                      const Divider(height: 22),
                      const QrLoginButtons(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Version row and the manual half of the self-updater.
///
/// The timer already checks on launch and every hour; this is for the user who
/// asked *now* and wants to see an answer instead of waiting for the next pass.
class _UpdateTile extends StatelessWidget {
  const _UpdateTile();

  static final Future<PackageInfo> _package = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return FutureBuilder<PackageInfo>(
      future: _package,
      builder: (context, snapshot) {
        final version = snapshot.data?.version ?? '…';
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Icon(Icons.system_update_alt_rounded, color: c.ink),
          title: Text(
            'Версия ScaleGuard $version',
            style: TextStyle(color: c.ink, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            'Проверить обновления',
            style: TextStyle(color: c.faint, fontSize: 12),
          ),
          trailing: Icon(Icons.chevron_right_rounded, color: c.muted),
          onTap: () => UpdateService.instance.checkManually(context),
        );
      },
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: SgColors.blue.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: SgColors.blue, size: 20),
      ),
      title: Text(
        title,
        style: TextStyle(color: c.ink, fontWeight: FontWeight.w800, fontSize: 15),
      ),
      subtitle: Text(subtitle, style: TextStyle(color: c.faint, fontSize: 12)),
      trailing: Icon(Icons.chevron_right_rounded, color: c.muted),
      onTap: onTap,
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding = const EdgeInsets.all(16)});
  final Widget child;

  /// The horizontal inset is smaller on the cards that hold list rows: the row's
  /// own highlight is painted across the whole tile, and the 4 px narrower inset
  /// keeps it from looking like a button floating in the middle of the card.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Material(
      color: c.sheet,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.line),
        ),
        child: child,
      ),
    );
  }
}

/// A row that leaves the application: support, channels, legal pages.
class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.url,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? url;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, color: c.ink),
      title: Text(title, style: TextStyle(color: c.ink, fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle, style: TextStyle(color: c.faint, fontSize: 12)),
      trailing: Icon(
        url == null ? Icons.chevron_right_rounded : Icons.open_in_new_rounded,
        size: 16,
        color: c.muted,
      ),
      onTap: onTap ??
          () => launchUrl(
                Uri.parse(url!),
                mode: LaunchMode.externalApplication,
              ),
    );
  }
}
