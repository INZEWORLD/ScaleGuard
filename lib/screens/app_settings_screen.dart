import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/binary_integrity.dart';
import '../core/android_background.dart';
import '../core/windows_tun.dart';
import '../services/log_service.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';

class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = SgColors.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const AuroraBackdrop(),
          SafeArea(
            bottom: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.arrow_back_rounded, color: c.ink),
                  ),
                ),
                Text(
                  'Настройки приложения',
                  style: TextStyle(
                    color: c.ink,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Оформление, запуск и служебные проверки. Эти настройки не '
                  'меняют то, как работает подключение.',
                  style: TextStyle(color: c.faint, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 16),
                _Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Тема',
                        style: TextStyle(
                          color: c.ink,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Как выглядит приложение. На работу подключения не влияет.',
                        style: TextStyle(color: c.faint, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      _ThemeTile(
                        label: 'Светлая',
                        subtitle: 'Всегда светлое оформление',
                        icon: Icons.light_mode_outlined,
                        selected: state.themeMode == ThemeMode.light,
                        onTap: () => state.setThemeMode(ThemeMode.light),
                      ),
                      _ThemeTile(
                        label: 'Тёмная',
                        subtitle: 'Всегда тёмное оформление',
                        icon: Icons.dark_mode_outlined,
                        selected: state.themeMode == ThemeMode.dark,
                        onTap: () => state.setThemeMode(ThemeMode.dark),
                      ),
                      _ThemeTile(
                        label: 'Как в системе',
                        subtitle: 'Так же, как остальные приложения на телефоне',
                        icon: Icons.smartphone_outlined,
                        selected: state.themeMode == ThemeMode.system,
                        onTap: () => state.setThemeMode(ThemeMode.system),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Card(
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: SgColors.blue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.power_settings_new_rounded,
                          color: SgColors.blue,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Подключаться при запуске',
                              style: TextStyle(
                                color: c.ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Если включено, приложение сразу подключится к '
                              'выбранной локации. Если выключено — только по '
                              'кнопке на главном экране.',
                              style: TextStyle(color: c.faint, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: state.autoConnectOnLaunch,
                        onChanged: state.setAutoConnectOnLaunch,
                      ),
                    ],
                  ),
                ),
                if (Platform.isWindows) ...[
                  const SizedBox(height: 12),
                  _Card(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: SgColors.violet.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              alignment: Alignment.center,
                              child: const Icon(
                                Icons.admin_panel_settings_rounded,
                                color: SgColors.violet,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Запускать от имени администратора',
                                    style: TextStyle(
                                      color: c.ink,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Нужно для полного режима, когда через канал '
                                    'идёт весь трафик. Windows спросит '
                                    'подтверждение при запуске.',
                                    style: TextStyle(
                                      color: c.faint,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: state.runAsAdmin,
                              onChanged: state.setRunAsAdmin,
                            ),
                          ],
                        ),
                        // The restart lives here, next to the switch that needs
                        // it — and only while the switch says something the
                        // running process is not: the preference reaches the
                        // process on a fresh start, so before the restart the
                        // row is the explanation of what the switch just did.
                        // Once the two agree there is nothing to explain.
                        if (state.elevated != state.runAsAdmin) ...[
                          const SizedBox(height: 12),
                          Divider(height: 1, color: c.line),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(
                                Icons.restart_alt_rounded,
                                size: 18,
                                color: SgColors.teal,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  state.runAsAdmin
                                      ? 'Перезапуск применит права администратора'
                                      : 'Перезапуск вернёт обычный режим',
                                  style: const TextStyle(
                                    color: SgColors.teal,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: state.busy
                                    ? null
                                    : () => state.restartApplication(),
                                child: const Text('Перезапустить'),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                if (Platform.isWindows) ...[
                  const SizedBox(height: 12),
                  _Card(
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: SgColors.teal.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.rocket_launch_rounded,
                            color: SgColors.teal,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Запускать вместе с Windows',
                                style: TextStyle(
                                  color: c.ink,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Приложение запустится само после входа в '
                                'Windows. Подключение при этом не включается — '
                                'для него есть отдельная настройка выше.',
                                style: TextStyle(color: c.faint, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: state.autostartEnabled,
                          onChanged: state.setAutostart,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Card(
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: SgColors.violet.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.minimize_rounded,
                            color: SgColors.violet,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Сворачивать в трей при закрытии',
                                style: TextStyle(
                                  color: c.ink,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Окно скроется в трей (значок рядом с часами), '
                                'а соединение останется включённым. Вернуть '
                                'окно — кликом по значку.',
                                style: TextStyle(color: c.faint, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: state.closeToTray,
                          onChanged: state.setCloseToTray,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Windows only, and not merely as a label: the mechanism is a
                  // Windows Firewall setting, and a switch that silently does
                  // nothing is worse than no switch.
                  if (Platform.isWindows) ...[
                    _SwitchCard(
                      icon: state.killSwitchActive
                          ? Icons.lock_rounded
                          : Icons.lock_open_rounded,
                      color: state.killSwitchActive
                          ? SgColors.green
                          : SgColors.violet,
                      title: 'Kill switch',
                      subtitle: _killSwitchSubtitle(state),
                      value: state.killSwitchEnabled,
                      onChanged: state.setKillSwitch,
                    ),
                    if (state.killSwitchActive) ...[
                      const SizedBox(height: 12),
                      _StatusCard(
                        icon: Icons.gpp_maybe_rounded,
                        color: SgColors.green,
                        title: 'Трафик под защитой',
                        subtitle:
                            'Всё, что не идёт в туннель, сейчас заблокировано',
                        actionLabel: 'Снять блокировку',
                        onAction: state.releaseKillSwitchNow,
                      ),
                    ],
                    const SizedBox(height: 12),
                  ],
                  _StatusCard(
                    icon: Icons.memory_rounded,
                    color: state.tunDriver == TunDriverStatus.driverMissing
                        ? SgColors.red
                        : SgColors.green,
                    title: 'Драйвер TUN',
                    subtitle: switch (state.tunDriver) {
                      TunDriverStatus.ready =>
                        'Установлен. Программы направляют трафик в канал '
                            'целиком, без настройки прокси',
                      TunDriverStatus.driverMissing =>
                        'Не найден — полный режим недоступен, работает только '
                            'системный прокси',
                      TunDriverStatus.unknown =>
                        'Состояние определить не удалось. Нажмите «Проверить»',
                    },
                    actionLabel: state.tunDriver == TunDriverStatus.driverMissing
                        ? 'Установить'
                        : null,
                    onAction: state.tunDriver == TunDriverStatus.driverMissing
                        ? state.installTunDriver
                        : null,
                    busy: state.tunDriverInstalling,
                  ),
                  const SizedBox(height: 12),
                  _StatusCard(
                    icon: Icons.verified_user_rounded,
                    color: switch (state.integrity.status) {
                      IntegrityStatus.verified => SgColors.green,
                      IntegrityStatus.mismatch => SgColors.red,
                      _ => c.muted,
                    },
                    title: 'Целостность файлов',
                    subtitle: state.integrity.summary,
                    actionLabel: 'Проверить',
                    onAction: state.verifyCoreIntegrity,
                  ),
                  if (state.subscriptionCheckInterval != null) ...[
                    const SizedBox(height: 12),
                    _StatusCard(
                      icon: Icons.update_rounded,
                      color: SgColors.blue,
                      title: 'Обновление подписки',
                      subtitle: 'Приложение само проверяет срок подписки каждые '
                          '${state.subscriptionCheckInterval!.inHours} ч '
                          '(интервал задаёт сервер)',
                    ),
                  ],
                  if (Platform.isWindows) ...[
                    const SizedBox(height: 12),
                    _StatusCard(
                      icon: Icons.admin_panel_settings_rounded,
                      color: state.helperInstalled ? SgColors.green : c.muted,
                      title: 'Служба-помощник',
                      subtitle: state.helperError ??
                          (state.helperInstalled
                              ? 'Запуск от администратора без запроса UAC'
                              : 'Убирает запрос UAC при запуске '
                                  'от администратора'),
                      actionLabel: state.helperInstalled ? 'Удалить' : 'Создать',
                      onAction: () => state.setHelper(!state.helperInstalled),
                    ),
                  ],
                ],
                // Android decides on its own whether a background service may
                // keep the radio open. The gates are asked for once, in a dialog
                // on the home screen, and a dismissed request stays there as a
                // line under the location — a settings card that repeats the
                // warning would only be the same text in a second place.
                const SizedBox(height: 12),
                _Card(
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: SgColors.green.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.receipt_long_rounded,
                          color: SgColors.green,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Системное логирование',
                              style: TextStyle(
                                color: c.ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              Platform.isWindows
                                  ? 'Помогает поддержке разобраться в проблеме. '
                                        'Журнал пишется рядом с программой'
                                  : 'Помогает поддержке разобраться в проблеме. '
                                        'Журнал пишется в папку приложения',
                              style: TextStyle(color: c.faint, fontSize: 12),
                            ),
                            if (state.loggingEnabled &&
                                LogService.instance.filePath != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                LogService.instance.filePath!,
                                style: TextStyle(color: c.faint, fontSize: 11),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Switch(
                        value: state.loggingEnabled,
                        onChanged: state.setLoggingEnabled,
                      ),
                    ],
                  ),
                ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 12),
                  _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: SgColors.teal.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              alignment: Alignment.center,
                              child: const Icon(
                                Icons.battery_saver_rounded,
                                color: SgColors.teal,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Работа в фоне',
                                    style: TextStyle(
                                      color: c.ink,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Android может останавливать приложения в '
                                    'фоне. Четыре настройки ниже — то, что нужно '
                                    'разрешить, чтобы соединение не обрывалось.',
                                    style: TextStyle(
                                      color: c.faint,
                                      fontSize: 12,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Divider(height: 1, color: c.line),
                        _ActionTile(
                          icon: Icons.battery_charging_full_rounded,
                          title: 'Без ограничений батареи',
                          subtitle: 'Android не будет замораживать приложение, '
                              'когда экран выключен',
                          actionLabel: 'Открыть',
                          onTap: AndroidBackground.requestBatteryExemption,
                        ),
                        _ActionTile(
                          icon: Icons.battery_5_bar_rounded,
                          title: 'Расход заряда батареи',
                          subtitle: 'Выберите «Без ограничений» (или '
                              '«Не ограничивать») — иначе система остановит '
                              'соединение через несколько минут',
                          actionLabel: 'Открыть',
                          onTap: AndroidBackground.openBatteryUsageSettings,
                        ),
                        _ActionTile(
                          icon: Icons.notifications_active_rounded,
                          title: 'Уведомления',
                          subtitle: 'Показывают состояние соединения в шторке и '
                              'не дают Android свернуть службу',
                          actionLabel: 'Разрешить',
                          onTap: AndroidBackground.requestNotifications,
                        ),
                        _ActionTile(
                          icon: Icons.rocket_launch_rounded,
                          title: 'Автозапуск',
                          subtitle: 'Чтобы соединение возвращалось после '
                              'перезагрузки телефона. Настройка производителя',
                          actionLabel: 'Открыть',
                          onTap: AndroidBackground.openAutostartSettings,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// What the kill-switch row says, in the order the user needs it: why it did
  /// not engage comes first, because that is the only case that needs action.
  String _killSwitchSubtitle(AppState state) {
    if (!Platform.isWindows) return 'Доступно только в Windows';
    final failure = state.killSwitchError;
    if (failure != null && failure.trim().isNotEmpty) {
      final text = failure.trim().replaceAll(RegExp(r'\s+'), ' ');
      return 'Не удалось включить: '
          '${text.length > 90 ? '${text.substring(0, 90)}…' : text}';
    }
    if (state.killSwitchActive) {
      return 'Включён: пока туннель не поднят, интернет заблокирован';
    }
    if (state.killSwitchEnabled) {
      return 'Включится в момент подключения. Сейчас интернет работает как обычно';
    }
    return 'Защита от утечек: если туннель оборвётся, интернет выключится '
        'до восстановления';
  }
}

/// A settings row built around a switch.
///
/// The three switches on this screen differ only in their icon, their colour and
/// their two lines of text, so they share one widget instead of three copies of
/// the same twenty lines.
class _SwitchCard extends StatelessWidget {
  const _SwitchCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return _Card(
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: c.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(color: c.faint, fontSize: 12)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: selected ? SgColors.violet : c.muted),
      title: Text(
        label,
        style: TextStyle(
          color: c.ink,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: c.faint, fontSize: 12),
      ),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? SgColors.violet : c.faint,
      ),
      onTap: onTap,
    );
  }
}

/// A row that opens a system screen, with the reason it matters underneath.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: c.muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: c.ink,
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(color: c.faint, fontSize: 11.5, height: 1.3),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onTap,
            child: Text(actionLabel, style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Material(
      color: c.sheet,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.line),
        ),
        child: child,
      ),
    );
  }
}

/// Read-only diagnostic row: an icon in the accent of the state it reports, the
/// state itself, and an optional action.
///
/// Used for the things the user cannot simply switch on — whether the TUN driver
/// is present and whether the bundled binaries are the ones that were built.
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
    this.busy = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return _Card(
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: c.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  alignment: Alignment.topLeft,
                  child: Text(
                    busy ? 'Установка…' : subtitle,
                    style: TextStyle(color: c.faint, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: busy ? null : onAction,
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}
