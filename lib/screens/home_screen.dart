import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../core/android_background.dart';
import '../core/mihomo_config.dart';
import '../services/vpn_service.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: _HomeBody(),
        ),
      ),
    );
  }
}

class _HomeBody extends StatefulWidget {
  const _HomeBody();

  @override
  State<_HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends State<_HomeBody> with WidgetsBindingObserver {
  /// Guards against pushing the administrator dialog twice while a rebuild is
  /// already scheduled from [AppState.notifyListeners].
  bool _adminDialogOpen = false;

  /// Same guard for the TUN driver prompt.
  bool _tunDialogOpen = false;

  /// Whether Android currently lets the tunnel run unattended, and whether the
  /// start-up prompt has already been offered in this session.
  BackgroundStatus? _background;
  bool _backgroundPrompted = false;

  /// Guards the step-by-step flow: each step opens a system window, and the
  /// lifecycle listener fires while one is on screen.
  bool _backgroundStepRunning = false;

  /// A granted permission is confirmed on this screen for a few seconds, then
  /// the line disappears: the requirement is met, so there is nothing left to
  /// ask for, but the user still gets to see that their tap worked.
  bool _backgroundJustGranted = false;
  Timer? _backgroundFlashTimer;

  /// A slow re-read while something is still missing.
  ///
  /// Vendor shells commit their battery switch when their own screen closes,
  /// sometimes seconds later, and some never report it through the public API
  /// at all. The line under the location used to stay on screen until the next
  /// resume, so a permission that had just been granted looked ignored.
  Timer? _backgroundPoll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startBackgroundCheck());
  }

  @override
  void dispose() {
    _backgroundFlashTimer?.cancel();
    _backgroundPoll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The exemption is granted on a system screen; the line has to reflect the
    // new state when the user comes back, not after the next launch. The system
    // can apply the change a moment after the activity resumes, so the state is
    // re-read a few times instead of once.
    if (state == AppLifecycleState.resumed) unawaited(_refreshBackgroundSoon());
  }

  /// Reads the Android background state.
  ///
  /// The answer is exactly what the system reports. It used to be overridden
  /// with "the flow was completed once" on vendors with their own battery
  /// screen, and that made a cancelled system dialog look like a granted
  /// permission: the card claimed success without ever checking, and never asked
  /// again. A permission that cannot be read back is reported as missing, not
  /// guessed to be present.
  Future<BackgroundStatus?> _readBackground() async {
    if (!mounted) return null;
    return AndroidBackground.read();
  }

  /// Shows the green confirmation for a few seconds, once.
  void _flashBackgroundGranted() {
    _backgroundFlashTimer?.cancel();
    setState(() => _backgroundJustGranted = true);
    _backgroundFlashTimer = Timer(const Duration(seconds: 7), () {
      if (!mounted) return;
      setState(() => _backgroundJustGranted = false);
    });
  }

  /// Whether the battery side of the background flow is settled.
  ///
  /// Either the system agrees that the app is exempt, or the user has already
  /// been sent to the vendor's screen and accepted the request. The second half
  /// matters because some shells ("no restrictions" in MIUI) never show up in
  /// `isIgnoringBatteryOptimizations`; treating that as "still missing" made the
  /// client ask for a permission the user had just granted, on every launch.
  bool _batterySettled(BackgroundStatus? status, AppState state) =>
      status == null || status.batteryExempt || state.backgroundBatteryAsked;

  /// Reads the Android background state and, once per launch, offers to fix it.
  ///
  /// The system gate is asked like the elevation prompt is on Windows: one
  /// dialog at the start, and if it is dismissed the same request stays as a
  /// line under the location — so the tunnel is never silently throttled.
  Future<void> _startBackgroundCheck() async {
    final status = await _readBackgroundSettled();
    if (!mounted) return;
    setState(() => _background = status);
    _startBackgroundPoll();
    final state = context.read<AppState>();
    final settled = _batterySettled(status, state);
    if (status == null || _backgroundPrompted) return;
    if (settled &&
        state.backgroundBatteryUsageAsked &&
        status.notifications) {
      return;
    }
    await _promptBackgroundPermissions();
  }

  /// Re-reads the state every few seconds while a line is still showing.
  ///
  /// Bounded: a user who chose "Позже" has answered, and a timer that keeps
  /// reading the system for the rest of the session would only waste battery.
  /// Two minutes is enough for a vendor shell to commit a switch after its own
  /// settings screen has closed.
  void _startBackgroundPoll() {
    _backgroundPoll?.cancel();
    var ticks = 0;
    _backgroundPoll = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!mounted || ++ticks > 24) {
        timer.cancel();
        _backgroundPoll = null;
        return;
      }
      final status = await _readBackground();
      if (!mounted) return;
      setState(() => _background = status);
      final state = context.read<AppState>();
      if (status == null ||
          (_batterySettled(status, state) &&
              state.backgroundBatteryUsageAsked &&
              status.notifications)) {
        timer.cancel();
        _backgroundPoll = null;
      }
    });
  }

  /// Re-reads the state for a few seconds after the user comes back.
  ///
  /// A single read on `resumed` catches the old value often enough to matter:
  /// the battery screen returns before the setting is committed, and the line
  /// then keeps asking for exactly what the user has just granted. MIUI in
  /// particular commits the change after its own settings activity has closed.
  Future<void> _refreshBackgroundSoon() async {
    const delays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 400),
      Duration(milliseconds: 1100),
      Duration(milliseconds: 2400),
      Duration(milliseconds: 4000),
      Duration(milliseconds: 6500),
    ];
    for (final delay in delays) {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      if (!mounted) return;
      final status = await _readBackground();
      if (!mounted) return;
      setState(() => _background = status);
      if (status == null || status.ready) return;
    }
  }

  /// Reads the background state, giving the system a moment to settle.
  ///
  /// The first answer right after launch (or right after the battery screen
  /// closes) can still describe the previous setting. Only a status that is
  /// already free of battery limits is trusted immediately; anything else is
  /// re-read for a couple of seconds before the client asks the user to fix
  /// something that may already be fixed.
  Future<BackgroundStatus?> _readBackgroundSettled({
    Duration timeout = const Duration(milliseconds: 2200),
  }) async {
    var status = await _readBackground();
    if (status == null || status.batteryExempt) return status;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) return status;
      status = await _readBackground();
      if (status == null || status.batteryExempt) return status;
    }
    return status;
  }

  Future<void> _promptBackgroundPermissions() =>
      _startBackgroundStep(force: false);

  /// Offers the *first* missing permission, in its own window.
  ///
  /// Each gate is a separate dialog because each one is a separate system
  /// screen: the battery exemption, the notification permission, and the
  /// vendor's autostart page. Each step is re-read from the system, and the next
  /// window only opens once the previous one is granted — except for the battery
  /// switch, whose vendor screen has no readable state: there the request is
  /// recorded and the flow moves on, otherwise MIUI users were asked for the
  /// same permission on every launch while its settings screen said "no
  /// restrictions".
  Future<void> _startBackgroundStep({bool force = true}) async {
    if (_backgroundStepRunning) return;
    // The start-up pass asks once per launch; the line under the location is
    // what the user taps when they want to be asked again.
    if (!force && _backgroundPrompted) return;
    _backgroundPrompted = true;
    _backgroundStepRunning = true;
    try {
      final status = _background ?? await _readBackground();
      if (!mounted || status == null) return;
      setState(() => _background = status);
      final state = context.read<AppState>();
      if (!_batterySettled(status, state)) {
        await _askBatteryExemption();
      } else if (!state.backgroundBatteryUsageAsked) {
        await _askBatteryUsage();
      } else if (!status.notifications) {
        await _askNotifications();
      } else {
        await _offerAutostart(status);
      }
    } finally {
      _backgroundStepRunning = false;
    }
  }

  Future<void> _askBatteryExemption() async {
    final granted = await _showChoiceDialog(
      icon: Icons.battery_charging_full_rounded,
      accent: SgColors.green,
      title: 'Работа в фоне',
      body: 'Android ограничивает приложения в фоне: соединение может '
          'отключиться, когда экран выключен или окно закрыто. Разрешите работу '
          'в фоне, чтобы защита оставалась включённой.',
      hint: 'В следующем окне нажмите «Разрешить» (или «ОК»).',
      cancelLabel: 'Позже',
      confirmLabel: 'Разрешить',
    );
    if (granted != true || !mounted) return;
    await AndroidBackground.requestBatteryExemption();
    // The vendor screen was opened and accepted: record it before reading the
    // state back. Some shells never report this switch, and asking again on the
    // next launch is exactly the loop the user sees as "I granted it already".
    if (!mounted) return;
    await context.read<AppState>().markBackgroundBatteryAsked();
    // MIUI applies the choice when its screen closes, not when the radio button
    // is tapped: read for a few seconds so a granted exemption is not reported
    // as missing.
    final after = await _readBackgroundSettled(
      timeout: const Duration(seconds: 5),
    );
    if (!mounted) return;
    setState(() => _background = after);
    if (after == null) return;
    // Move on to the next step whether or not the shell admits to the change:
    // the battery page has been shown, and the next permission is a separate one.
    await _askBatteryUsage();
  }

  /// The second battery gate: the system's per-application energy limit.
  ///
  /// It is not the same switch as the exemption above. The exemption keeps Doze
  /// from freezing the process, while this screen ("Расход заряда батареи" /
  /// "Battery usage") decides how much the vendor shell may restrict the
  /// application — and on many phones it silently kills a background service even
  /// when the exemption is granted. Nothing on the phone reports the chosen level,
  /// so the request is remembered once the screen has been shown.
  Future<void> _askBatteryUsage() async {
    if (!mounted) return;
    final open = await _showChoiceDialog(
      icon: Icons.battery_saver_rounded,
      accent: SgColors.teal,
      title: 'Расход заряда батареи',
      body: 'Это отдельная настройка, она не выдаётся автоматически. Система '
          'может ограничивать расход заряда приложением и останавливать '
          'соединение через несколько минут после закрытия окна.',
      hint: 'Выберите «Без ограничений» (на некоторых телефонах — '
          '«Не ограничивать»). Если откроется общий экран: Настройки → '
          'Приложения → ScaleGuard → Расход заряда батареи.',
      cancelLabel: 'Позже',
      confirmLabel: 'Открыть',
    );
    if (open != true || !mounted) return;
    await AndroidBackground.openBatteryUsageSettings();
    if (!mounted) return;
    await context.read<AppState>().markBackgroundBatteryUsageAsked();
    await _askNotifications();
  }

  Future<void> _askNotifications() async {
    if (!mounted) return;
    final granted = await _showChoiceDialog(
      icon: Icons.notifications_active_rounded,
      accent: SgColors.blue,
      title: 'Уведомления',
      body: 'Уведомление показывает состояние соединения и позволяет остановить '
          'его из шторки. Без него Android вправе свернуть службу, которая '
          'держит соединение включённым.',
      hint: 'Это системное разрешение, его достаточно выдать один раз.',
      cancelLabel: 'Позже',
      confirmLabel: 'Разрешить',
    );
    if (granted != true || !mounted) return;
    await AndroidBackground.requestNotifications();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final after = await _readBackground();
    if (!mounted) return;
    setState(() => _background = after);
    if (after == null || !after.notifications) return;
    await _offerAutostart(after);
  }

  /// The vendor's autostart page, offered only where the vendor has one.
  ///
  /// This is a screen, not a permission: nothing can read the choice back, so
  /// the step sends the user there and claims nothing afterwards.
  Future<void> _offerAutostart(BackgroundStatus status) async {
    if (!status.hasAutostartScreen || !mounted) {
      if (mounted && _backgroundSettled) _flashBackgroundGranted();
      return;
    }
    final open = await _showChoiceDialog(
      icon: Icons.rocket_launch_rounded,
      accent: SgColors.violet,
      title: 'Автозапуск',
      // No vendor name here on purpose: this build ships to every phone, and
      // "Xiaomi stops background apps" read as if the client had been made for
      // one brand.
      body: 'Система останавливает фоновые приложения, даже когда Android '
          'разрешил работу в фоне. Откройте системный экран и разрешите '
          'автозапуск — иначе соединение может оборваться после закрытия окна.',
      hint: 'Это настройка производителя, приложение не видит её состояние.',
      cancelLabel: 'Не сейчас',
      confirmLabel: 'Открыть',
    );
    if (open == true) await AndroidBackground.openAutostartSettings();
    if (!mounted) return;
    if (_backgroundSettled) _flashBackgroundGranted();
  }

  /// Whether every readable requirement of the background flow is met.
  bool get _backgroundSettled {
    final status = _background;
    if (status == null || !mounted) return false;
    final state = context.read<AppState>();
    return _batterySettled(status, state) &&
        state.backgroundBatteryUsageAsked &&
        status.notifications;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final vpn = state.vpn;
    final tunnel = state.tunnel;
    final trial = state.trial;
    final c = SgColors.of(context);
    final connected = vpn.state == VpnConnectionState.connected;
    final connecting = vpn.state == VpnConnectionState.connecting;
    final active = tunnel?.hasActiveSubscription == true;
    final selectedProfile = vpn.profiles.isNotEmpty
        ? vpn.selectedIndex >= 0 && vpn.selectedIndex < vpn.profiles.length
              ? vpn.profiles[vpn.selectedIndex]
              : null
        : null;
    final serverRemark = selectedProfile?.remark ?? 'ScaleGuard';
    final swept = vpn.selectedIndex >= 0 &&
            vpn.selectedIndex < vpn.serverLatencies.length
        ? vpn.serverLatencies[vpn.selectedIndex]
        : null;
    // The tunnel's own probe is the freshest number while a session is up: the
    // sweep may not have reached this node yet, and a tile that shows nothing
    // while the monitoring card shows 614 ms looks broken.
    final latency = swept != null && swept > 0
        ? swept
        : (vpn.currentPingMs > 0 ? vpn.currentPingMs : null);

    if (state.adminRestartPrompt) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeShowAdminDialog();
      });
    }
    if (state.tunDriverPrompt) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeShowTunDriverDialog();
      });
    }

    return Column(
      children: [
        Row(
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutBack,
              builder: (_, v, __) =>
                  Transform.scale(scale: v, child: const BrandMark(size: 40)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TweenAnimationBuilder<Offset>(
                tween: Tween(begin: const Offset(-12, 0), end: Offset.zero),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOutBack,
                builder: (_, off, __) => Transform.translate(
                  offset: off,
                  child: Text(
                    'ScaleGuard',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.0,
                      color: c.ink,
                    ),
                  ),
                ),
              ),
            ),
            _PulseBounce(
              child: Material(
                color: c.pill,
                shape: const CircleBorder(),
                child: IconButton(
                  onPressed: () => launchUrl(
                    Uri.parse('https://t.me/${AppConfig.telegramBotName}'),
                  ),
                  icon: Icon(Icons.chat_bubble_outline_rounded, color: c.ink),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              children: [
                const SizedBox(height: 12),
                if (state.offlineMode) ...[
                  _OfflineModeBanner(
                    busy: state.busy,
                    onRetry: state.retryOfflineConnection,
                  ),
                  const SizedBox(height: 12),
                ],
                RepaintBoundary(
                  child: _VpnHero(
                    connected: connected,
                    connecting: connecting,
                    active: active,
                    busy: state.busy,
                    onTap: () {
                      if (!active) {
                        context.read<AppState>().setShellTab(1);
                        return;
                      }
                      state.toggleVpn();
                    },
                  ),
                ),
                if (state.connectRequirement != null)
                  _ConnectRequirementHint(
                    requirement: state.connectRequirement!,
                    onFix: state.resolveConnectRequirement,
                  ),
                const SizedBox(height: 14),
                _ServerCard(
                  serverName: serverRemark,
                  latencyMs: latency,
                  active: active,
                  hasMultiple: vpn.profiles.length > 1,
                  onTap: active && vpn.profiles.isNotEmpty
                      ? () => _openServers(context)
                      : null,
                ),
                _BackgroundHint(
                  status: _background,
                  batteryAsked: state.backgroundBatteryAsked,
                  usageAsked: state.backgroundBatteryUsageAsked,
                  justGranted: _backgroundJustGranted,
                  onFix: _startBackgroundStep,
                ),
                if (active && (tunnel?.trafficLimitBytes ?? 0) > 0) ...[
                  const SizedBox(height: 14),
                  _SubscriptionCard(
                    usedTraffic: tunnel?.usedTrafficBytes,
                    limitTraffic: tunnel?.trafficLimitBytes,
                    formatTraffic: vpn.formatTraffic,
                  ),
                ] else if (!active) ...[
                  const SizedBox(height: 14),
                  _NoSubscriptionCard(
                    onChoosePlan: () => context.read<AppState>().setShellTab(1),
                  ),
                  if (trial?.available == true) ...[
                    const SizedBox(height: 12),
                    _TrialCtaCard(
                      days: trial?.durationDays,
                      busy: state.busy,
                      onActivate: () => context.read<AppState>().activateTrial(),
                    ),
                  ],
                ],
                const SizedBox(height: 14),
                if (connected)
                  _SpeedMonitorCard(
                    downloadBps: state.vpnDownloadBps,
                    uploadBps: state.vpnUploadBps,
                    pingMs: state.vpnPingMs > 0
                        ? state.vpnPingMs
                        : (latency ?? 0),
                    formatSpeed: vpn.formatSpeed,
                    externalIp: state.externalIp,
                    externalIpLoading: state.externalIpLoading,
                  ),
                if (state.locationNotice != null) ...[
                  const SizedBox(height: 10),
                  _LocationNotice(text: state.locationNotice!),
                ],
                if (state.error != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    decoration: BoxDecoration(
                      color: SgColors.red.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: SgColors.red.withValues(alpha: 0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: SgColors.red,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            state.error!,
                            textAlign: TextAlign.left,
                            style: const TextStyle(
                              color: SgColors.red,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                // The confirmation a fresh account needs to see — the trial it
                // was just handed — lands on this screen, so the note is shown
                // here too and not only on the screens that live off `info`.
                if (state.info != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    decoration: BoxDecoration(
                      color: SgColors.green.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: SgColors.green.withValues(alpha: 0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle_outline_rounded,
                          color: SgColors.green,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            state.info!,
                            textAlign: TextAlign.left,
                            style: const TextStyle(
                              color: SgColors.green,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 110),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Offers to restart the app elevated when TUN was requested without the
  /// rights to create its adapter.
  ///
  /// TUN is the default mode, so this is the first thing a new installation
  /// sees when it starts the tunnel: a clear choice instead of a tunnel that
  /// silently fails to come up.
  Future<void> _maybeShowAdminDialog() async {
    if (_adminDialogOpen) return;
    final state = context.read<AppState>();
    if (!state.adminRestartPrompt) return;
    _adminDialogOpen = true;
    final restart = await _showChoiceDialog(
      icon: Icons.admin_panel_settings_rounded,
      accent: SgColors.violet,
      title: 'Нужны права администратора',
      body: 'Для этого режима приложение нужно запустить от имени '
          'администратора.',
      hint: 'Подсказка: включите «Всегда запускать от имени администратора» '
          'в настройках — тогда приложение будет запускаться так автоматически.',
      cancelLabel: 'Отмена',
      confirmLabel: 'Перезапустить',
    );
    _adminDialogOpen = false;
    if (restart == true) {
      await state.restartAsAdministrator();
    } else {
      state.declineAdminRestart();
    }
  }

  /// Offers to install the TUN driver the connect just ran into.
  ///
  /// Accepting installs it and continues the connect in one go; the driver is
  /// installed by the bundled core itself, which is what Wintun expects, so
  /// nothing has to be downloaded.
  Future<void> _maybeShowTunDriverDialog() async {
    if (_tunDialogOpen) return;
    final state = context.read<AppState>();
    if (!state.tunDriverPrompt) return;
    _tunDialogOpen = true;
    final install = await _showChoiceDialog(
      icon: Icons.memory_rounded,
      accent: SgColors.teal,
      title: 'Нужен драйвер TUN',
      body: 'На этом компьютере нет драйвера виртуального адаптера (Wintun), '
          'поэтому полный туннель создать нельзя.',
      hint: 'Приложение установит драйвер само и сразу подключится. '
          'Понадобится подтверждение прав администратора.',
      cancelLabel: 'Отмена',
      confirmLabel: 'Установить',
    );
    _tunDialogOpen = false;
    if (install == true) {
      await state.installTunDriverAndConnect();
    } else {
      state.declineTunDriverInstall();
    }
  }

  /// Shared modal for the prompts that need a decision before a tunnel can come
  /// up. Returns `true` when the user accepted.
  Future<bool?> _showChoiceDialog({
    required IconData icon,
    required Color accent,
    required String title,
    required String body,
    required String hint,
    required String cancelLabel,
    required String confirmLabel,
  }) {
    final c = SgColors.of(context);
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: c.sheet,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: c.line),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: Icon(icon, color: accent, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          color: c.ink,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  body,
                  style: TextStyle(color: c.muted, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 8),
                Text(
                  hint,
                  style: TextStyle(color: c.faint, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        style: TextButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                          foregroundColor: c.muted,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(cancelLabel),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(confirmLabel),
                      ),
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

/// Marks a dashboard that is running from the last downloaded subscription.
///
/// Without this line an offline session looks exactly like an online one until
/// a purchase or a plan refresh fails. The check button retries only the
/// account call, so a still-down backend does not cost the user the dashboard.
class _OfflineModeBanner extends StatelessWidget {
  const _OfflineModeBanner({required this.busy, required this.onRetry});

  final bool busy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
      decoration: BoxDecoration(
        color: SgColors.violet.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: SgColors.violet.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.cloud_off_rounded,
                size: 19,
                color: SgColors.violet,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Офлайн-режим',
                      style: TextStyle(
                        color: SgColors.violet,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Сервер аккаунта недоступен. Используются сохранённые '
                      'серверы; тарифы и покупки временно не работают.',
                      style: TextStyle(
                        color: c.muted,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: busy ? null : onRetry,
              style: TextButton.styleFrom(
                foregroundColor: SgColors.violet,
                visualDensity: VisualDensity.compact,
              ),
              icon: busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          SgColors.violet,
                        ),
                      ),
                    )
                  : const Icon(Icons.refresh_rounded, size: 17),
              label: Text(busy ? 'Проверяем…' : 'Проверить связь'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One line under the connect button for the gate that is still closed.
///
/// The Windows gates are asked for in separate windows, and a window that was
/// dismissed has to leave something behind: without this line the switch simply
/// did nothing, which is indistinguishable from a broken client. It shows one
/// requirement at a time — the first one the last attempt stopped at — and the
/// tap reopens that window.
class _ConnectRequirementHint extends StatelessWidget {
  const _ConnectRequirementHint({
    required this.requirement,
    required this.onFix,
  });

  final ConnectRequirement requirement;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final (text, action) = switch (requirement) {
      ConnectRequirement.admin => (
        'Нужны права администратора',
        'Разрешить',
      ),
      ConnectRequirement.tunDriver => (
        'Нужен драйвер TUN',
        'Установить',
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: SgColors.violet.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onFix,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
            child: Row(
              children: [
                const Icon(
                  Icons.lock_outline_rounded,
                  size: 18,
                  color: SgColors.violet,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: SgColors.violet,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  action,
                  style: TextStyle(
                    color: c.ink,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "keep it running" requirement, under the location.
///
/// Shown only while something is missing: a tunnel that Android may freeze is
/// worth one line on the screen where the tunnel is started, and the same line
/// is where a dismissed dialog leaves the request. Once every gate is open it
/// turns into a green confirmation and then gets out of the way.
class _BackgroundHint extends StatelessWidget {
  const _BackgroundHint({
    required this.status,
    required this.batteryAsked,
    required this.usageAsked,
    required this.justGranted,
    required this.onFix,
  });

  final BackgroundStatus? status;

  /// The user has already been sent to the system battery screen.
  ///
  /// Some shells keep reporting "restricted" after their own settings screen
  /// says "no restrictions", so the line must not keep asking for the battery
  /// once that screen has been shown. The next readable step is what is offered.
  final bool batteryAsked;

  /// The user has been sent to the per-application battery page ("Расход заряда
  /// батареи"). Vendor shells keep the chosen level to themselves, so like the
  /// exemption above, this is remembered rather than read back.
  final bool usageAsked;
  final bool justGranted;
  final Future<void> Function() onFix;

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) return const SizedBox.shrink();
    final batteryOk = s.batteryExempt || batteryAsked;
    if (batteryOk && usageAsked && s.notifications) {
      if (!justGranted) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.check_circle_rounded,
              size: 16,
              color: SgColors.green,
            ),
            const SizedBox(width: 6),
            Text(
              'Фон разрешён — туннель не уснёт',
              style: TextStyle(
                color: SgColors.green,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }
    final c = SgColors.of(context);
    final missing = !batteryOk
        ? 'разрешить работу без ограничений батареи'
        : !usageAsked
        ? 'снять ограничение расхода заряда'
        : 'включить уведомления';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: SgColors.red.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onFix(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
            child: Row(
              children: [
                const Icon(
                  Icons.battery_alert_rounded,
                  size: 18,
                  color: SgColors.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'В фоне соединение может отключиться — $missing',
                    style: const TextStyle(
                      color: SgColors.red,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'Разрешить',
                  style: TextStyle(
                    color: c.ink,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PulseBounce extends StatefulWidget {
  const _PulseBounce({required this.child});
  final Widget child;

  @override
  State<_PulseBounce> createState() => _PulseBounceState();
}

class _PulseBounceState extends State<_PulseBounce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0,
      upperBound: 1,
    );
    Future<void>.delayed(const Duration(milliseconds: 80), _c.forward);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cv = _c.value.clamp(0.0, 1.0);
    final e = _elasticOut(cv).clamp(0.0, 1.0);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Transform.scale(
        scale: (0.88 + e * 0.12).clamp(0.85, 1.05),
        child: Opacity(
          opacity: (0.4 + cv * 0.6).clamp(0.0, 1.0),
          child: widget.child,
        ),
      ),
    );
  }

  double _elasticOut(double t) {
    const p = 0.4;
    final v =
        math.pow(2, -10 * t) * math.sin((t - p / 4) * (2 * math.pi) / p) + 1;
    return v.clamp(0.0, 1.0);
  }
}

class _VpnHero extends StatefulWidget {
  const _VpnHero({
    required this.connected,
    required this.connecting,
    required this.active,
    required this.busy,
    required this.onTap,
  });

  final bool connected;
  final bool connecting;
  final bool active;
  final bool busy;
  final VoidCallback onTap;

  @override
  State<_VpnHero> createState() => _VpnHeroState();
}

class _VpnHeroState extends State<_VpnHero> with TickerProviderStateMixin {
  late final AnimationController _pulse;
  late final AnimationController _bounce;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat(min: 0, max: 1);
    _bounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    Future<void>.delayed(const Duration(milliseconds: 120), _bounce.forward);
  }

  @override
  void dispose() {
    _pulse.dispose();
    _bounce.dispose();
    super.dispose();
  }

  double _elasticOut(double t) {
    const p = 0.36;
    final v =
        math.pow(2, -10 * t) * math.sin((t - p / 4) * (2 * math.pi) / p) + 1;
    return v.clamp(0.0, 1.0);
  }

  double _smoothRippleProgress(double pulseT, int ringIndex, int totalRings) {
    final phase = ringIndex / math.max(1, totalRings);
    final x = (pulseT + phase) % 1.0;
    final sinVal = math.sin(x * math.pi);
    return sinVal.clamp(0.0, 1.0);
  }

  double _ringOpacity(double progress) {
    final a = math.sin(progress * math.pi);
    return (a * 0.42).clamp(0.0, 0.45);
  }

  double _ringScale(double progress) {
    const minSize = 188.0;
    const maxSize = 262.0;
    return minSize + (maxSize - minSize) * progress;
  }

  @override
  Widget build(BuildContext context) {
    return _SimpleVpnControl(
      connected: widget.connected,
      connecting: widget.connecting,
      active: widget.active,
      busy: widget.busy,
      onTap: widget.onTap,
    );
  }

  // ignore: unused_element
  Widget _buildLegacy(BuildContext context) {
    final accent = widget.connected
        ? SgColors.green
        : widget.connecting
        ? SgColors.teal
        : widget.active
        ? SgColors.blue
        : SgColors.red;
    final shieldGrad = widget.connected
        ? const [Color(0xFF0A3B35), Color(0xFF061A28), Color(0xFF042032)]
        : widget.connecting
        ? const [Color(0xFF0E2A46), Color(0xFF122250), Color(0xFF1B1650)]
        : const [Color(0xFF2A1858), Color(0xFF14103C), Color(0xFF08122A)];

    final status = !widget.active
        ? 'НЕТ ПОДПИСКИ'
        : widget.connecting
        ? 'ПОДКЛЮЧЕНИЕ…'
        : widget.connected
        ? 'ЗАЩИЩЕНО'
        : 'ОТКЛЮЧЕНО';

    return AnimatedBuilder(
      animation: Listenable.merge([_pulse, _bounce]),
      builder: (context, _) {
        final bounceT = _elasticOut(_bounce.value);
        final pulseT =
            (widget.connecting || widget.connected ? _pulse.value : 0.15).clamp(
              0.0,
              1.0,
            );
        return Transform.scale(
          scale: (0.9 + bounceT * 0.1).clamp(0.85, 1.05),
          child: Opacity(
            opacity: (0.7 + bounceT * 0.3).clamp(0.0, 1.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 280,
                  height: 280,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (widget.connecting || widget.connected)
                        ...List.generate(3, (i) {
                          final t = _smoothRippleProgress(pulseT, i, 3);
                          final size = _ringScale(t);
                          final opacity = _ringOpacity(t);
                          return IgnorePointer(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              curve: Curves.easeOutCubic,
                              width: size,
                              height: size,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: accent.withValues(alpha: opacity),
                                  width: 2.2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: accent.withValues(
                                      alpha: opacity * 0.25,
                                    ),
                                    blurRadius: 34 + t * 18,
                                    spreadRadius: 2 + t * 3,
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.easeOutBack,
                        width: 250,
                        height: 250,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: accent.withValues(
                                alpha: widget.connecting || widget.connected
                                    ? 0.35
                                    : 0.15,
                              ),
                              blurRadius: 40,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                      ),
                      IgnorePointer(
                        child: AnimatedBuilder(
                          animation: _pulse,
                          builder: (_, __) {
                            const tau = math.pi * 2;
                            final rot =
                                (widget.connecting
                                    ? _pulse.value * tau * 1.2
                                    : _pulse.value * tau * 0.12) %
                                tau;
                            return Container(
                              width: 242,
                              height: 242,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: SweepGradient(
                                  startAngle: 0,
                                  endAngle: tau,
                                  colors: [
                                    accent.withValues(alpha: 0.0),
                                    accent.withValues(alpha: 0.55),
                                    accent.withValues(alpha: 0.0),
                                    SgColors.violet.withValues(alpha: 0.6),
                                    accent.withValues(alpha: 0.0),
                                  ],
                                  stops: const [0, 0.25, 0.5, 0.75, 1],
                                  transform: GradientRotation(rot),
                                ),
                              ),
                              child: Container(
                                margin: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: shieldGrad,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.white.withValues(alpha: 0.05),
                                          Colors.transparent,
                                        ],
                                      ),
                                      border: Border.all(
                                        color: accent.withValues(alpha: 0.35),
                                        width: 1.2,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: accent.withValues(alpha: 0.22),
                                          blurRadius: 16,
                                          spreadRadius: -2,
                                        ),
                                      ],
                                    ),
                                    child: Material(
                                      color: Colors.transparent,
                                      shape: const CircleBorder(),
                                      child: InkWell(
                                        customBorder: const CircleBorder(),
                                        onTap: widget.busy
                                            ? null
                                            : widget.onTap,
                                        child: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            CustomPaint(
                                              size: const Size.square(150),
                                              painter: _ShieldPainter(
                                                gradient: LinearGradient(
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                  colors: [
                                                    accent.withValues(
                                                      alpha: 0.95,
                                                    ),
                                                    SgColors.violet.withValues(
                                                      alpha: 0.95,
                                                    ),
                                                  ],
                                                ),
                                                glow: accent.withValues(
                                                  alpha: 0.6,
                                                ),
                                              ),
                                            ),
                                            widget.connecting || widget.busy
                                                ? const SizedBox(
                                                    width: 38,
                                                    height: 38,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 3,
                                                          color: Colors.white,
                                                        ),
                                                  )
                                                : Icon(
                                                    Icons
                                                        .power_settings_new_rounded,
                                                    size: 48,
                                                    color: widget.connected
                                                        ? Colors.white
                                                        : Colors.white
                                                              .withValues(
                                                                alpha: 0.95,
                                                              ),
                                                  ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  status,
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.4,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SimpleVpnControl extends StatelessWidget {
  const _SimpleVpnControl({
    required this.connected,
    required this.connecting,
    required this.active,
    required this.busy,
    required this.onTap,
  });

  final bool connected;
  final bool connecting;
  final bool active;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = connected ? SgColors.green : SgColors.violet;
    final enabled = !busy;
    final status = !active
        ? 'НЕТ ПОДПИСКИ'
        : connecting
        ? 'ПОДКЛЮЧЕНИЕ…'
        : connected
        ? 'ЗАЩИЩЕНО'
        : 'ОТКЛЮЧЕНО';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 220,
          height: 220,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 210,
                height: 210,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: accent.withValues(alpha: 0.45),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.18),
                      blurRadius: 28,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
              Container(
                width: 178,
                height: 178,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    colors: [Color(0xFF20245A), Color(0xFF101431)],
                  ),
                  border: Border.all(
                    color: accent.withValues(alpha: 0.7),
                    width: 1.5,
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  child: InkWell(
                    onTap: enabled ? onTap : null,
                    customBorder: const CircleBorder(),
                    child: Icon(
                      Icons.power_settings_new_rounded,
                      size: 58,
                      color: enabled
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ),
              if (connecting || busy)
                const SizedBox(
                  width: 76,
                  height: 76,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          status,
          style: TextStyle(
            color: accent,
            fontWeight: FontWeight.w900,
            letterSpacing: 2.2,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

class _ShieldPainter extends CustomPainter {
  _ShieldPainter({required this.gradient, required this.glow});
  final Gradient gradient;
  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.5, h * 0.08)
      ..cubicTo(w * 0.25, h * 0.16, w * 0.10, h * 0.30, w * 0.10, h * 0.44)
      ..quadraticBezierTo(w * 0.10, h * 0.70, w * 0.50, h * 0.94)
      ..quadraticBezierTo(w * 0.90, h * 0.70, w * 0.90, h * 0.44)
      ..cubicTo(w * 0.90, h * 0.30, w * 0.75, h * 0.16, w * 0.50, h * 0.08)
      ..close();

    canvas.drawShadow(path, glow, 14, true);

    final borderPaint = Paint()
      ..shader = gradient.createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2;
    canvas.drawPath(path, borderPaint);

    final fillPaint = Paint()
      ..shader = (LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [glow.withValues(alpha: 0.10), Colors.transparent],
      )).createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _ShieldPainter oldDelegate) =>
      oldDelegate.gradient != gradient || oldDelegate.glow != glow;
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutBack,
      builder: (_, v, __) => Transform.scale(
        scale: 0.97 + v * 0.03,
        child: Opacity(
          opacity: (0.7 + v * 0.3).clamp(0.0, 1.0),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: c.line),
              boxShadow: [
                BoxShadow(
                  color: SgColors.blue.withValues(alpha: 0.08),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

String _stripLeadingEmoji(String value) {
  final raw = String.fromCharCodes(value.runes.toList());
  final re = RegExp(
    r'^[\s\u{1F30D}-\u{1F77F}\u{1F780}-\u{1F7FF}\u{1F800}-\u{1F8FF}\u{1F900}-\u{1F9FF}\u{1FA00}-\u{1FA6F}\u{1FA70}-\u{1FAFF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}\u{1F1E6}-\u{1F1FF}\u{E0061}-\u{E007F}\u{FEFF}\u{200D}\u{FE0F}]+',
    unicode: true,
    caseSensitive: false,
    dotAll: true,
  );
  return raw.replaceFirst(re, '').trim();
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.serverName,
    required this.latencyMs,
    required this.active,
    required this.hasMultiple,
    this.onTap,
  });

  final String serverName;
  final int? latencyMs;
  final bool active;
  final bool hasMultiple;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final lat = latencyMs;
    final good = lat != null && lat > 0 && lat <= 80;
    final ok = lat != null && lat > 0 && lat <= 180;
    final pingColor = good
        ? SgColors.green
        : ok
        ? SgColors.teal
        : lat != null && lat > 0
        ? SgColors.violet
        : c.muted;
    final clickable = active && hasMultiple && onTap != null;
    final cleanName = active
        ? _stripLeadingEmoji(serverName)
        : 'Выберите тариф';

    return _BounceButton(
      onTap: clickable ? onTap : null,
      child: _GlassCard(
        child: Row(
          children: [
            _FlagEmoji(name: serverName, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cleanName,
                    style: TextStyle(
                      color: c.ink,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (lat != null && lat > 0)
                    Text(
                      'Пинг: $lat мс',
                      style: TextStyle(
                        color: pingColor,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                        letterSpacing: 0.2,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              clickable
                  ? Icons.chevron_right_rounded
                  : hasMultiple
                  ? Icons.chevron_right_rounded
                  : Icons.lock_outline_rounded,
              color: clickable ? c.ink : c.muted,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _BounceButton extends StatefulWidget {
  const _BounceButton({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_BounceButton> createState() => _BounceButtonState();
}

class _BounceButtonState extends State<_BounceButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      value: 1,
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down(_) => _c.reverse();
  void _up(_) {
    _c.forward().then((_) {
      if (mounted) widget.onTap?.call();
    });
  }

  void _cancel() => _c.forward();

  double _ease(double t) => Curves.easeOutBack.transform(t);

  @override
  Widget build(BuildContext context) {
    final cv = _c.value.clamp(0.0, 1.0);
    final ease = _ease(cv).clamp(0.0, 1.0);
    return GestureDetector(
      onTapDown: widget.onTap != null ? _down : null,
      onTapUp: widget.onTap != null ? _up : null,
      onTapCancel: widget.onTap != null ? _cancel : null,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Transform.scale(
          scale: (0.95 + ease * 0.05).clamp(0.9, 1.02),
          child: widget.child,
        ),
      ),
    );
  }
}

String _countryCodeFor(String name) {
  final n = name.toLowerCase().replaceAll('-', ' ');
  const rules = <String, List<String>>{
    'fi': ['финлянд', 'финск', 'фин', 'хельсинк', 'helsinki', 'finland', 'suomi', 'tampere', 'oulu'],
    'se': ['швец', 'швед', 'стокгольм', 'sweden', 'swedish', 'stockholm'],
    'no': ['норвег', 'осло', 'norway', 'oslo'],
    'dk': ['дани', 'копенгаген', 'denmark', 'copenhagen'],
    'is': ['исланд', 'reykjavik', 'iceland'],
    'nl': ['нидерл', 'голланд', 'амстердам', 'netherlands', 'holland', 'amsterdam'],
    'be': ['бельг', 'брюссел', 'belgium', 'brussels'],
    'lu': ['люксем', 'luxembourg'],
    'ru': ['москв', 'росси', 'санкт', 'петерб', 'спб', 'russia', 'moscow', 'petersburg'],
    'de': ['немец', 'герман', 'берлин', 'франкфурт', 'germany', 'berlin', 'frankfurt'],
    'gb': ['лондон', 'англ', 'великобр', 'британ', 'britain', 'england', 'london'],
    'fr': ['франц', 'париж', 'france', 'paris'],
    'it': ['итали', 'милан', 'italy', 'milan', 'rome'],
    'es': ['испан', 'мадрид', 'барселон', 'spain', 'madrid', 'barcelona'],
    'pt': ['португал', 'лиссабон', 'portugal', 'lisbon'],
    'ie': ['ирланд', 'дублин', 'ireland', 'dublin'],
    'at': ['австри', 'вена', 'austria', 'vienna'],
    'ch': ['швейцар', 'цюрих', 'switzerland', 'zurich'],
    'cz': ['чеш', 'праг', 'czech', 'prague'],
    'pl': ['поль', 'варшав', 'poland', 'warsaw'],
    'ua': ['украин', 'киев', 'kyiv', 'ukraine'],
    'by': ['беларус', 'минск', 'belarus', 'minsk'],
    'lt': ['литв', 'вильнюс', 'lithuania', 'vilnius'],
    'lv': ['латв', 'риг', 'latvia', 'riga'],
    'ee': ['эстон', 'таллин', 'estonia', 'tallinn'],
    'md': ['молдов', 'кишин', 'moldova', 'chisinau'],
    'ro': ['румын', 'bucharest', 'romania'],
    'bg': ['болгар', 'bulgaria', 'sofia'],
    'hu': ['венгр', 'будапешт', 'hungary', 'budapest'],
    'rs': ['серби', 'белград', 'serbia', 'belgrade'],
    'hr': ['хорват', 'zagreb', 'croatia'],
    'si': ['словени', 'ljubljana', 'slovenia'],
    'sk': ['словак', 'bratislava', 'slovakia'],
    'gr': ['грец', 'афин', 'greece', 'athens'],
    'cy': ['кипр', 'cyprus'],
    'tr': ['турц', 'стамбул', 'ankara', 'turkey', 'istanbul'],
    'ge': ['грузи', 'тбилиси', 'georgia', 'tbilisi'],
    'am': ['армен', 'ереван', 'armenia', 'yerevan'],
    'az': ['азербайж', 'баку', 'azerbaijan', 'baku'],
    'kz': ['казахст', 'алмат', 'астан', 'kazakhstan', 'almaty'],
    'il': ['израил', 'israel'],
    'ae': ['эмират', 'оаэ', 'дубай', 'emirates', 'uae', 'dubai'],
    'us': ['сша', 'америк', 'нью йорк', 'usa', 'united states', 'america', 'new york', 'dallas', 'ashburn'],
    'ca': ['канад', 'торонто', 'canada', 'toronto'],
    'mx': ['мексик', 'mexico'],
    'br': ['бразил', 'brazil'],
    'jp': ['япон', 'токио', 'japan', 'tokyo'],
    'kr': ['корей', 'сеул', 'korea', 'seoul'],
    'cn': ['кита', 'пекин', 'china', 'beijing'],
    'hk': ['гонконг', 'hong kong'],
    'in': ['инди', 'бомбей', 'mumbai', 'india'],
    'sg': ['сингапур', 'singapore'],
    'th': ['таиланд', 'bangkok', 'thailand'],
    'vn': ['вьетнам', 'vietnam'],
    'au': ['австрал', 'сидней', 'australia', 'sydney'],
    'nz': ['новая зеланд', 'zealand'],
  };
  for (final entry in rules.entries) {
    for (final keyword in entry.value) {
      if (n.contains(keyword)) return entry.key;
    }
  }
  return 'world';
}

class _FlagEmoji extends StatelessWidget {
  const _FlagEmoji({required this.name, this.size = 44});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.pill,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.line),
        ),
        child: CustomPaint(
          size: Size.square(size * 0.56),
          painter: _CountryFlagPainter(_countryCodeFor(name)),
        ),
      ),
    );
  }
}

class _CountryFlagPainter extends CustomPainter {
  const _CountryFlagPainter(this.country);

  final String country;

  static const Map<String, List<Color>> _hBands = {
    'nl': [Color(0xFFAE1C28), Colors.white, Color(0xFF21468B)],
    'ru': [Colors.white, Color(0xFF2449A5), Color(0xFFD52B1E)],
    'de': [Color(0xFF141414), Color(0xFFDD0000), Color(0xFFFFCE00)],
    'at': [Color(0xFFED2939), Colors.white, Color(0xFFED2939)],
    'bg': [Colors.white, Color(0xFF00966E), Color(0xFFD62612)],
    'hu': [Color(0xFFCD2A3E), Colors.white, Color(0xFF436F4D)],
    'lu': [Color(0xFFEF3340), Colors.white, Color(0xFF00A1DE)],
    'lt': [Color(0xFFFDB913), Color(0xFF006A44), Color(0xFFC1272D)],
    'ee': [Color(0xFF0072CE), Color(0xFF141414), Colors.white],
    'am': [Color(0xFFD90012), Color(0xFF0033A0), Color(0xFFF2A800)],
    'rs': [Color(0xFFC6363C), Color(0xFF0C4076), Colors.white],
    'sk': [Colors.white, Color(0xFF0B4EA2), Color(0xFFEE1C25)],
    'si': [Colors.white, Color(0xFF005DA4), Color(0xFFED1C24)],
    'hr': [Color(0xFFFF0000), Colors.white, Color(0xFF171796)],
  };

  static const Map<String, List<Color>> _vBands = {
    'fr': [Color(0xFF1D3F9B), Colors.white, Color(0xFFE33B4B)],
    'it': [Color(0xFF009246), Colors.white, Color(0xFFCE2B37)],
    'ie': [Color(0xFF169B62), Colors.white, Color(0xFFFF883E)],
    'ro': [Color(0xFF002B7F), Color(0xFFFCD116), Color(0xFFCE1126)],
    'be': [Color(0xFF141414), Color(0xFFFAE042), Color(0xFFED2939)],
    'md': [Color(0xFF0046AE), Color(0xFFFFD200), Color(0xFFCC092F)],
    'mx': [Color(0xFF006847), Colors.white, Color(0xFFCE1126)],
  };

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()..style = PaintingStyle.fill;
    final border = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.width * 0.14),
    );
    canvas.save();
    canvas.clipRRect(border);
    final h = _hBands[country];
    final v = _vBands[country];
    if (h != null) {
      _horizontal(canvas, size, h, paint);
    } else if (v != null) {
      _vertical(canvas, size, v, paint);
    } else {
      switch (country) {
        case 'fi':
          _nordic(canvas, size, paint, Colors.white, const Color(0xFF003580));
        case 'dk':
          _nordic(canvas, size, paint, const Color(0xFFC8102E), Colors.white);
        case 'no':
          _nordic(
            canvas,
            size,
            paint,
            const Color(0xFFBA0C2F),
            Colors.white,
            inner: const Color(0xFF00205B),
          );
        case 'is':
          _nordic(
            canvas,
            size,
            paint,
            const Color(0xFF02529C),
            Colors.white,
            inner: const Color(0xFFDC1E35),
          );
        case 'se':
          _nordic(
            canvas,
            size,
            paint,
            const Color(0xFF2363A5),
            const Color(0xFFF6C744),
          );
        case 'gb':
          _unionJack(canvas, size, paint);
        case 'us':
          paint.color = const Color(0xFFB22234);
          canvas.drawRect(rect, paint);
          paint.color = Colors.white;
          for (var i = 1; i < 13; i += 2) {
            canvas.drawRect(
              Rect.fromLTWH(
                0,
                size.height * i / 13,
                size.width,
                size.height / 13 + 1,
              ),
              paint,
            );
          }
          paint.color = const Color(0xFF3C3B6E);
          canvas.drawRect(
            Rect.fromLTWH(0, 0, size.width * 0.5, size.height * 7 / 13),
            paint,
          );
        case 'pl':
          _horizontal(canvas, size, [
            Colors.white,
            const Color(0xFFDC143C),
          ], paint);
        case 'ua':
          _horizontal(canvas, size, [
            const Color(0xFF005BBB),
            const Color(0xFFFFD500),
          ], paint);
        case 'lv':
          _ratioH(canvas, size, [
            const Color(0xFF9E3039),
            Colors.white,
            const Color(0xFF9E3039),
          ], const [2, 1, 2], paint);
        case 'es':
          _ratioH(canvas, size, [
            const Color(0xFFAA151B),
            const Color(0xFFF1BF00),
            const Color(0xFFAA151B),
          ], const [1, 2, 1], paint);
        case 'cz':
          _horizontal(canvas, size, [
            Colors.white,
            const Color(0xFFD7141A),
          ], paint);
          final triangle = Path()
            ..moveTo(0, 0)
            ..lineTo(size.width * 0.45, size.height / 2)
            ..lineTo(0, size.height)
            ..close();
          paint.color = const Color(0xFF11457E);
          canvas.drawPath(triangle, paint);
        case 'gr':
          const greekBlue = Color(0xFF0D5EAF);
          for (var i = 0; i < 9; i++) {
            paint.color = i.isEven ? greekBlue : Colors.white;
            canvas.drawRect(
              Rect.fromLTWH(
                0,
                size.height * i / 9,
                size.width,
                size.height / 9 + 1,
              ),
              paint,
            );
          }
          paint.color = greekBlue;
          canvas.drawRect(
            Rect.fromLTWH(0, 0, size.width * 0.37, size.height * 5 / 9),
            paint,
          );
          paint.color = Colors.white;
          canvas.drawRect(
            Rect.fromLTWH(
              size.width * 0.148,
              0,
              size.width * 0.074,
              size.height * 5 / 9,
            ),
            paint,
          );
          canvas.drawRect(
            Rect.fromLTWH(
              0,
              size.height * (5 / 18 - 1 / 18),
              size.width * 0.37,
              size.height / 9,
            ),
            paint,
          );
        case 'ae':
          _horizontal(canvas, size, [
            const Color(0xFF00732F),
            Colors.white,
            const Color(0xFF141414),
          ], paint);
          paint.color = const Color(0xFFFF0000);
          canvas.drawRect(
            Rect.fromLTWH(0, 0, size.width * 0.28, size.height),
            paint,
          );
        case 'by':
          _ratioH(canvas, size, [
            const Color(0xFFCE1720),
            const Color(0xFF007C30),
          ], const [2, 1], paint);
          paint.color = Colors.white;
          canvas.drawRect(
            Rect.fromLTWH(0, 0, size.width * 0.13, size.height),
            paint,
          );
          paint.color = const Color(0xFFCE1720);
          canvas.drawRect(
            Rect.fromLTWH(0, 0, size.width * 0.05, size.height),
            paint,
          );
        case 'ge':
          paint.color = Colors.white;
          canvas.drawRect(rect, paint);
          paint.color = const Color(0xFFFF0000);
          canvas.drawRect(
            Rect.fromLTWH(size.width * 0.42, 0, size.width * 0.16, size.height),
            paint,
          );
          canvas.drawRect(
            Rect.fromLTWH(0, size.height * 0.42, size.width, size.height * 0.16),
            paint,
          );
          for (final p in const [
            (0.25, 0.25),
            (0.75, 0.25),
            (0.25, 0.75),
            (0.75, 0.75),
          ]) {
            canvas.drawCircle(
              Offset(size.width * p.$1, size.height * p.$2),
              size.shortestSide * 0.07,
              paint,
            );
          }
        case 'cy':
          paint.color = Colors.white;
          canvas.drawRect(rect, paint);
          paint.color = const Color(0xFFD57800);
          canvas.drawCircle(
            Offset(size.width / 2, size.height * 0.44),
            size.shortestSide * 0.12,
            paint,
          );
          paint.color = const Color(0xFF4E5B31);
          canvas.drawRect(
            Rect.fromLTWH(
              size.width * 0.3,
              size.height * 0.62,
              size.width * 0.4,
              size.height * 0.05,
            ),
            paint,
          );
        case 'jp':
          _disc(canvas, size, paint, Colors.white, const Color(0xFFBC002D));
        case 'ch':
          paint.color = const Color(0xFFDA291C);
          canvas.drawRect(rect, paint);
          paint.color = Colors.white;
          canvas.drawRect(
            Rect.fromLTWH(
              size.width * 0.4,
              size.height * 0.18,
              size.width * 0.2,
              size.height * 0.64,
            ),
            paint,
          );
          canvas.drawRect(
            Rect.fromLTWH(
              size.width * 0.18,
              size.height * 0.4,
              size.width * 0.64,
              size.height * 0.2,
            ),
            paint,
          );
        case 'tr':
          paint.color = const Color(0xFFE30A17);
          canvas.drawRect(rect, paint);
          _crescent(
            canvas,
            size,
            paint,
            Colors.white,
            const Color(0xFFE30A17),
            Offset(size.width * 0.4, size.height / 2),
            size.shortestSide * 0.26,
          );
          paint.color = Colors.white;
          _star(
            canvas,
            Offset(size.width * 0.66, size.height / 2),
            size.shortestSide * 0.11,
            paint,
          );
        case 'az':
          _horizontal(canvas, size, [
            const Color(0xFF00B9E4),
            const Color(0xFFED2939),
            const Color(0xFF3F9C35),
          ], paint);
          _crescent(
            canvas,
            size,
            paint,
            Colors.white,
            const Color(0xFFED2939),
            size.center(Offset.zero),
            size.shortestSide * 0.14,
          );
        case 'kr':
          paint.color = Colors.white;
          canvas.drawRect(rect, paint);
          final taeguk = Rect.fromCenter(
            center: size.center(Offset.zero),
            width: size.shortestSide * 0.5,
            height: size.shortestSide * 0.5,
          );
          paint.color = const Color(0xFFCD2E3A);
          canvas.drawArc(taeguk, math.pi, math.pi, true, paint);
          paint.color = const Color(0xFF0047A0);
          canvas.drawArc(taeguk, 0, math.pi, true, paint);
        case 'kz':
          paint.color = const Color(0xFF00AFCA);
          canvas.drawRect(rect, paint);
          paint.color = const Color(0xFFFEC50C);
          canvas.drawCircle(
            size.center(Offset.zero),
            size.shortestSide * 0.2,
            paint,
          );
          canvas.drawRect(
            Rect.fromLTWH(size.width * 0.06, 0, size.width * 0.06, size.height),
            paint,
          );
        case 'il':
          paint.color = Colors.white;
          canvas.drawRect(rect, paint);
          paint.color = const Color(0xFF0038B8);
          canvas.drawRect(
            Rect.fromLTWH(0, size.height * 0.12, size.width, size.height * 0.12),
            paint,
          );
          canvas.drawRect(
            Rect.fromLTWH(
              0,
              size.height * 0.76,
              size.width,
              size.height * 0.12,
            ),
            paint,
          );
          _star(
            canvas,
            size.center(Offset.zero),
            size.shortestSide * 0.18,
            paint,
          );
        case 'sg':
          _horizontal(canvas, size, [
            const Color(0xFFEF3340),
            Colors.white,
          ], paint);
          paint.color = Colors.white;
          canvas.drawCircle(
            Offset(size.width * 0.3, size.height * 0.28),
            size.shortestSide * 0.14,
            paint,
          );
        case 'cn':
          paint.color = const Color(0xFFDE2910);
          canvas.drawRect(rect, paint);
          paint.color = const Color(0xFFFFDE00);
          _star(
            canvas,
            Offset(size.width * 0.32, size.height * 0.34),
            size.shortestSide * 0.18,
            paint,
          );
        case 'vn':
          paint.color = const Color(0xFFDA251D);
          canvas.drawRect(rect, paint);
          paint.color = const Color(0xFFFFF000);
          _star(
            canvas,
            size.center(Offset.zero),
            size.shortestSide * 0.26,
            paint,
          );
        case 'hk':
          paint.color = const Color(0xFFDE2910);
          canvas.drawRect(rect, paint);
          paint.color = Colors.white;
          canvas.drawCircle(
            size.center(Offset.zero),
            size.shortestSide * 0.17,
            paint,
          );
        case 'in':
          _horizontal(canvas, size, [
            const Color(0xFFFF9933),
            Colors.white,
            const Color(0xFF138808),
          ], paint);
          paint.color = const Color(0xFF000080);
          paint.style = PaintingStyle.stroke;
          paint.strokeWidth = size.shortestSide * 0.04;
          canvas.drawCircle(
            size.center(Offset.zero),
            size.shortestSide * 0.12,
            paint,
          );
          paint.style = PaintingStyle.fill;
        case 'th':
          _ratioH(canvas, size, [
            const Color(0xFFA51931),
            const Color(0xFFF4F5F8),
            const Color(0xFF2D2A4A),
            const Color(0xFFF4F5F8),
            const Color(0xFFA51931),
          ], const [1, 1, 2, 1, 1], paint);
        case 'ca':
          _ratioV(canvas, size, [
            const Color(0xFFD80621),
            Colors.white,
            const Color(0xFFD80621),
          ], const [1, 2, 1], paint);
          paint.color = const Color(0xFFD80621);
          canvas.drawCircle(
            size.center(Offset.zero),
            size.shortestSide * 0.14,
            paint,
          );
        case 'pt':
          _ratioV(canvas, size, [
            const Color(0xFF046A38),
            const Color(0xFFDA291C),
          ], const [2, 3], paint);
          paint.color = const Color(0xFFFFE900);
          canvas.drawCircle(
            Offset(size.width * 0.4, size.height / 2),
            size.shortestSide * 0.15,
            paint,
          );
        case 'br':
          paint.color = const Color(0xFF009C3B);
          canvas.drawRect(rect, paint);
          final diamond = Path()
            ..moveTo(size.width / 2, size.height * 0.1)
            ..lineTo(size.width * 0.9, size.height / 2)
            ..lineTo(size.width / 2, size.height * 0.9)
            ..lineTo(size.width * 0.1, size.height / 2)
            ..close();
          paint.color = const Color(0xFFFEDF00);
          canvas.drawPath(diamond, paint);
          paint.color = const Color(0xFF002776);
          canvas.drawCircle(
            size.center(Offset.zero),
            size.shortestSide * 0.18,
            paint,
          );
        case 'au':
          paint.color = const Color(0xFF002476);
          canvas.drawRect(rect, paint);
          paint.color = Colors.white;
          _star(
            canvas,
            Offset(size.width * 0.28, size.height * 0.55),
            size.shortestSide * 0.13,
            paint,
          );
          for (final p in const [(0.68, 0.22), (0.82, 0.45), (0.62, 0.68), (0.78, 0.82)]) {
            canvas.drawCircle(
              Offset(size.width * p.$1, size.height * p.$2),
              size.shortestSide * 0.045,
              paint,
            );
          }
        case 'nz':
          paint.color = const Color(0xFF002476);
          canvas.drawRect(rect, paint);
          paint.color = const Color(0xFFCC142B);
          for (final p in const [(0.66, 0.25), (0.8, 0.48), (0.6, 0.7), (0.78, 0.82)]) {
            canvas.drawCircle(
              Offset(size.width * p.$1, size.height * p.$2),
              size.shortestSide * 0.055,
              paint,
            );
          }
        default:
          final center = size.center(Offset.zero);
          paint.color = SgColors.blue;
          canvas.drawCircle(center, size.shortestSide / 2, paint);
          paint.color = Colors.white.withValues(alpha: 0.85);
          paint.style = PaintingStyle.stroke;
          paint.strokeWidth = size.shortestSide * 0.06;
          canvas.drawOval(
            Rect.fromCenter(
              center: center,
              width: size.width * 0.48,
              height: size.height * 0.92,
            ),
            paint,
          );
          canvas.drawLine(
            Offset(0, size.height / 2),
            Offset(size.width, size.height / 2),
            paint,
          );
          canvas.drawOval(
            Rect.fromCenter(
              center: center,
              width: size.width * 0.92,
              height: size.height * 0.34,
            ),
            paint,
          );
          paint.style = PaintingStyle.fill;
      }
    }
    canvas.restore();
  }

  void _horizontal(Canvas canvas, Size size, List<Color> colors, Paint paint) {
    final band = size.height / colors.length;
    for (var i = 0; i < colors.length; i++) {
      paint.color = colors[i];
      canvas.drawRect(Rect.fromLTWH(0, i * band, size.width, band + 1), paint);
    }
  }

  void _vertical(Canvas canvas, Size size, List<Color> colors, Paint paint) {
    final band = size.width / colors.length;
    for (var i = 0; i < colors.length; i++) {
      paint.color = colors[i];
      canvas.drawRect(Rect.fromLTWH(i * band, 0, band + 1, size.height), paint);
    }
  }

  void _nordic(
    Canvas canvas,
    Size size,
    Paint paint,
    Color bg,
    Color cross, {
    Color? inner,
  }) {
    paint.color = bg;
    canvas.drawRect(Offset.zero & size, paint);
    final cx = size.width * 0.36;
    final cy = size.height * 0.5;
    final bandW = size.width * 0.2;
    final bandH = size.height * 0.22;
    void bands(Color color, double w, double h) {
      paint.color = color;
      canvas.drawRect(Rect.fromLTWH(cx - w / 2, 0, w, size.height), paint);
      canvas.drawRect(Rect.fromLTWH(0, cy - h / 2, size.width, h), paint);
    }

    if (inner != null) bands(inner, bandW, bandH);
    bands(cross, bandW * 0.55, bandH * 0.55);
  }

  void _unionJack(Canvas canvas, Size size, Paint paint) {
    paint.color = const Color(0xFF173A8F);
    canvas.drawRect(Offset.zero & size, paint);
    paint.color = Colors.white;
    paint.strokeWidth = size.width * 0.2;
    canvas.drawLine(Offset.zero, Offset(size.width, size.height), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), paint);
    paint.color = const Color(0xFFD52B3E);
    paint.strokeWidth = size.width * 0.09;
    canvas.drawLine(Offset.zero, Offset(size.width, size.height), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), paint);
    paint.strokeWidth = size.height * 0.28;
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      paint,
    );
  }

  void _disc(
    Canvas canvas,
    Size size,
    Paint paint,
    Color bg,
    Color disc, {
    double r = 0.3,
  }) {
    paint.color = bg;
    canvas.drawRect(Offset.zero & size, paint);
    paint.color = disc;
    canvas.drawCircle(size.center(Offset.zero), size.shortestSide * r, paint);
  }

  void _crescent(
    Canvas canvas,
    Size size,
    Paint paint,
    Color outer,
    Color inner,
    Offset center,
    double r,
  ) {
    paint.color = outer;
    canvas.drawCircle(center, r, paint);
    paint.color = inner;
    canvas.drawCircle(center + Offset(r * 0.4, 0), r * 0.82, paint);
  }

  void _star(Canvas canvas, Offset center, double r, Paint paint) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final angle = i * math.pi / 5 - math.pi / 2;
      final rad = i.isEven ? r : r * 0.45;
      final x = center.dx + rad * math.cos(angle);
      final y = center.dy + rad * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  void _ratioH(
    Canvas canvas,
    Size size,
    List<Color> colors,
    List<double> weights,
    Paint paint,
  ) {
    final total = weights.fold(0.0, (a, b) => a + b);
    var y = 0.0;
    for (var i = 0; i < colors.length; i++) {
      final h = size.height * weights[i] / total;
      paint.color = colors[i];
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, h + 1), paint);
      y += h;
    }
  }

  void _ratioV(
    Canvas canvas,
    Size size,
    List<Color> colors,
    List<double> weights,
    Paint paint,
  ) {
    final total = weights.fold(0.0, (a, b) => a + b);
    var x = 0.0;
    for (var i = 0; i < colors.length; i++) {
      final w = size.width * weights[i] / total;
      paint.color = colors[i];
      canvas.drawRect(Rect.fromLTWH(x, 0, w + 1, size.height), paint);
      x += w;
    }
  }

  @override
  bool shouldRepaint(covariant _CountryFlagPainter oldDelegate) =>
      oldDelegate.country != country;
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({
    required this.usedTraffic,
    required this.limitTraffic,
    required this.formatTraffic,
  });

  final num? usedTraffic;
  final num? limitTraffic;
  final String Function(num?) formatTraffic;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final limit = limitTraffic ?? 0;
    final used = usedTraffic ?? 0;
    if (limit <= 0) return const SizedBox.shrink();
    final progress = (used / limit).clamp(0.0, 1.0);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutBack,
      builder: (_, v, __) => Transform.scale(
        scale: 0.97 + v * 0.03,
        child: Opacity(
          opacity: 0.7 + v * 0.3,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: c.line),
              boxShadow: [
                BoxShadow(
                  color: SgColors.blue.withValues(alpha: 0.06),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                    children: [
                      Text(
                        'Трафик',
                        style: TextStyle(
                          color: c.faint,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${formatTraffic(usedTraffic)} / ${formatTraffic(limitTraffic)}',
                        style: TextStyle(
                          color: c.ink,
                          fontWeight: FontWeight.w800,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: Stack(
                      children: [
                        Container(height: 6, color: c.pill),
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: progress.toDouble()),
                          duration: const Duration(milliseconds: 900),
                          curve: Curves.easeOutCubic,
                          builder: (_, v, __) => Container(
                            height: 6,
                            width: MediaQuery.of(context).size.width * 0.72 * v,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(99),
                              gradient: LinearGradient(
                                colors: progress > 0.85
                                    ? const [SgColors.red, SgColors.violet]
                                    : progress > 0.6
                                    ? const [SgColors.violet, SgColors.blue]
                                    : const [SgColors.blue, SgColors.teal],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The trial offer, shaped like the banner the website shows a new account.
///
/// It sits directly under "подписка не активна" because that is the only moment
/// it is useful: an account with no tunnel and a trial it has never used.
class _TrialCtaCard extends StatelessWidget {
  const _TrialCtaCard({required this.busy, required this.onActivate, this.days});

  final bool busy;
  final VoidCallback onActivate;
  final int? days;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final period = days != null && days! > 0 ? ' на $days ${_dayWord(days!)}' : '';
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: SgColors.violet.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.card_giftcard_rounded,
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
                      'Пробный доступ$period',
                      style: TextStyle(
                        color: c.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Бесплатно и без карты — чтобы проверить скорость и локации',
                      style: TextStyle(
                        color: c.muted,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: busy ? null : onActivate,
            icon: const Icon(Icons.flash_on_rounded, size: 18),
            label: Text(busy ? 'Подождите…' : 'Получить пробный период'),
          ),
        ],
      ),
    );
  }
}

String _dayWord(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) return 'день';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'дня';
  return 'дней';
}

class _NoSubscriptionCard extends StatelessWidget {
  const _NoSubscriptionCard({required this.onChoosePlan});
  final VoidCallback onChoosePlan;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: SgColors.red.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.card_membership_outlined,
                  color: SgColors.red,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Подписка не активна',
                      style: TextStyle(
                        color: c.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Выберите тариф, чтобы открыть доступ ко всем локациям',
                      style: TextStyle(
                        color: c.muted,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _BounceButton(
            onTap: onChoosePlan,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [SgColors.blue, SgColors.violet],
                ),
                boxShadow: [
                  BoxShadow(
                    color: SgColors.violet.withValues(alpha: 0.25),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: const Text(
                'Выбрать тариф',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 14.5,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpeedMonitorCard extends StatelessWidget {
  const _SpeedMonitorCard({
    required this.downloadBps,
    required this.uploadBps,
    required this.pingMs,
    required this.formatSpeed,
    required this.externalIp,
    required this.externalIpLoading,
  });

  final int downloadBps;
  final int uploadBps;
  final int pingMs;
  final String Function(int?) formatSpeed;
  final String? externalIp;
  final bool externalIpLoading;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);

    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: SgColors.teal.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.speed_rounded,
                  color: SgColors.teal,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Мониторинг соединения',
                  style: TextStyle(
                    color: c.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5,
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Внешний IP',
                    style: TextStyle(
                      color: c.faint,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 2),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    child: Text(
                      // A dash means "answered, nothing there"; while the first
                      // lookup is still in flight the card says so instead of
                      // looking like a failure.
                      externalIp ??
                          (externalIpLoading ? 'поиск…' : '—'),
                      key: ValueKey(externalIp ?? (externalIpLoading ? 'l' : 'n')),
                      style: TextStyle(
                        color: externalIp == null && externalIpLoading
                            ? c.faint
                            : c.muted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(
                    begin: downloadBps.toDouble(),
                    end: downloadBps.toDouble(),
                  ),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutCubic,
                  builder: (_, v, __) => _SpeedTile(
                    label: 'Скачивание',
                    value: formatSpeed(v.round()),
                    icon: Icons.arrow_downward_rounded,
                    color: SgColors.teal,
                    bars: v.round(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(
                    begin: uploadBps.toDouble(),
                    end: uploadBps.toDouble(),
                  ),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutCubic,
                  builder: (_, v, __) => _SpeedTile(
                    label: 'Отдача',
                    value: formatSpeed(v.round()),
                    icon: Icons.arrow_upward_rounded,
                    color: SgColors.violet,
                    bars: v.round(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: pingMs.toDouble(), end: pingMs.toDouble()),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutCubic,
                  builder: (_, v, __) {
                    final ping = v.round();
                    final color = ping <= 0
                        ? c.muted
                        : ping <= 60
                        ? SgColors.green
                        : ping <= 150
                        ? SgColors.teal
                        : SgColors.violet;
                    return _SpeedTile(
                      label: 'Пинг',
                      value: ping > 0 ? '$ping мс' : '—',
                      icon: Icons.network_ping_rounded,
                      color: color,
                      // Scale to the same 0..1e6 range as the throughput tiles
                      // (lower latency = more lit bars); without the factor the
                      // ping tile never lit a single bar.
                      bars: ping > 0 ? math.max(0, 400 - ping) * 2500 : 0,
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Transient banner shown when the core moved the tunnel on its own.
class _LocationNotice extends StatelessWidget {
  const _LocationNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, (1 - v) * 8),
          child: child,
        ),
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: BoxDecoration(
          color: SgColors.violet.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: SgColors.violet.withValues(alpha: 0.22)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.swap_horiz_rounded,
              color: SgColors.violet,
              size: 16,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: c.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpeedTile extends StatelessWidget {
  const _SpeedTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.bars,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final int bars;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final level = (bars / 1000000.0).clamp(0.0, 1.0);
    final activeBars = (level * 5).round().clamp(0, 5);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      decoration: BoxDecoration(
        color: c.pill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 14),
              const SizedBox(width: 4),
              // The three tiles share one row, so the longest label has to be
              // allowed to shrink instead of pushing the tile past its edge.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.muted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.6, end: 1),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutBack,
            builder: (_, v, __) => Transform.scale(
              scale: v,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: List.generate(5, (i) {
              final active = i < activeBars;
              final t = (label == 'Пинг') ? 1 - (i / 5) : (i + 1) / 5;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.2),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                    height: 10 + t * 14,
                    decoration: BoxDecoration(
                      color: active ? color : color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

Color latencyColor(int? ms, {required BuildContext context}) {
  final c = SgColors.of(context);
  if (ms == null || ms <= 0) return c.muted;
  if (ms <= 80) return SgColors.green;
  if (ms <= 180) return SgColors.teal;
  return SgColors.violet;
}

class _HostEntry {
  _HostEntry({
    required this.profileIndex,
    required this.remark,
    required this.hostPort,
  });
  final int profileIndex;
  final String remark;
  final String hostPort;
}

class _LocationGroup {
  _LocationGroup({
    required this.key,
    required this.locationName,
    required this.representativeRemark,
    required this.hosts,
  });
  final String key;
  final String locationName;
  final String representativeRemark;
  final List<_HostEntry> hosts;

  int? bestPing(List<int?> latencies) {
    int? best;
    for (final h in hosts) {
      final l = h.profileIndex < latencies.length
          ? latencies[h.profileIndex]
          : null;
      if (l != null && l > 0 && (best == null || l < best)) best = l;
    }
    return best;
  }

  int? selectedProfileIndex(int vpnSelectedIndex) {
    for (final h in hosts) {
      if (h.profileIndex == vpnSelectedIndex) return h.profileIndex;
    }
    return null;
  }

}

String _locationKey(String remark) {
  final digitsRe = RegExp(r'[0-9]+');
  final clean = _stripLeadingEmoji(remark)
      .replaceAll(digitsRe, '')
      .replaceAll(RegExp(r'[\s·•\-_#.]+$'), '')
      .replaceAll(RegExp(r'^[\s·•\-_#.]+'), '')
      .trim()
      .toLowerCase();
  return clean.isEmpty ? remark.trim().toLowerCase() : clean;
}

String _locationName(String remark) {
  final digitsRe = RegExp(r'[0-9]+');
  var name = _stripLeadingEmoji(remark)
      .replaceAll(digitsRe, '')
      .replaceAll(RegExp(r'[\s·•\-_#.]+$'), '')
      .replaceAll(RegExp(r'^[\s·•\-_#.]+'), '')
      .trim();
  if (name.isEmpty) name = _stripLeadingEmoji(remark).trim();
  return name.isEmpty ? remark.trim() : name;
}

List<_LocationGroup> _groupProfilesIntoLocations(VpnService vpn) {
  final groups = <String, _LocationGroup>{};
  final order = <String>[];
  for (var i = 0; i < vpn.profiles.length; i++) {
    final p = vpn.profiles[i];
    final hostPort = vpn.extractHostPort(i) ?? '•••:•••';
    final k = _locationKey(p.remark);
    final locName = _locationName(p.remark);
    if (!groups.containsKey(k)) {
      order.add(k);
      groups[k] = _LocationGroup(
        key: k,
        locationName: locName,
        representativeRemark: p.remark,
        hosts: [],
      );
    }
    groups[k]!.hosts.add(
      _HostEntry(profileIndex: i, remark: p.remark, hostPort: hostPort),
    );
  }
  return [for (final k in order) groups[k]!];
}

int? _bestLatencyExcludingRussia(VpnService vpn, List<int?> latencies) {
  int? best;
  for (var i = 0; i < vpn.profiles.length && i < latencies.length; i++) {
    if (isRussianLocation(vpn.profiles[i].remark)) continue;
    final value = latencies[i];
    if (value != null && value > 0 && (best == null || value < best)) {
      best = value;
    }
  }
  return best;
}

Future<void> _openServers(BuildContext context) async {
  final state = context.read<AppState>();
  final vpn = state.vpn;
  // Both live in the outer scope on purpose: the modal re-runs its builder on
  // every route rebuild, so a "run once" flag declared inside the builder
  // resets and re-arms the sweep forever. The first sweep is also started here,
  // once per sheet opening, instead of from inside a build — and slightly after
  // the sheet animation, so the two do not compete for the main thread.
  Timer(const Duration(milliseconds: 350), () {
    unawaited(state.pingAllAndMaybeSelect(applyAuto: false));
  });
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      final c = SgColors.of(sheetContext);
      final baseGroups = _groupProfilesIntoLocations(vpn);
      return _LatencyGate(
        state: state,
        builder: (listenCtx) {
          return StatefulBuilder(
            builder: (ctx, _) {
              final latencies = vpn.serverLatencies;
              final pinging = state.autoSelectingServer;

              // The sheet is wrapped in [_LatencyGate], so the numbers
              // refresh on their own; the action only has to start the sweep.
              Future<void> refreshPings() async {
                if (state.autoSelectingServer) return;
                unawaited(state.pingAllAndMaybeSelect(applyAuto: false));
              }

              Color pingColorFor(int? ms) => latencyColor(ms, context: ctx);

              return SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: c.sheet,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(28),
                        bottom: Radius.circular(22),
                      ),
                      border: Border.all(color: c.line),
                      boxShadow: [
                        BoxShadow(
                          color: SgColors.violet.withValues(alpha: 0.18),
                          blurRadius: 36,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(sheetContext).size.height * 0.72,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 8, 14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 42,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: c.line,
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          _PulseDot(
                                            color: pinging
                                                ? SgColors.teal
                                                : SgColors.green,
                                          ),
                                          const SizedBox(width: 6),
                                          Flexible(
                                            child: Text(
                                              'СЕТЬ · СЕРВЕРЫ',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: c.faint,
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 1.5,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                      const Text(
                                        'Локации',
                                        style: TextStyle(
                                          fontSize: 21,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: -0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _SheetPill(
                                  icon: pinging
                                      ? Icons.hourglass_top_rounded
                                      : Icons.refresh_rounded,
                                  label: pinging ? 'Пинг…' : 'Пинг',
                                  busy: pinging,
                                  onTap: pinging ? null : refreshPings,
                                ),
                              ],
                            ),
                          ),
                          // HUD separator: a neon rule that reads as a live link,
                          // the way a game client marks the active server list.
                          Container(
                            height: 2,
                            margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  SgColors.teal,
                                  SgColors.blue,
                                  SgColors.violet,
                                ],
                              ),
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                          Flexible(
                            child: ListView.builder(
                              shrinkWrap: true,
                              physics: const BouncingScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
                              itemCount: baseGroups.length + 1,
                              itemBuilder: (_, gi) {
                                if (gi == 0) {
                                  final autoPing = _bestLatencyExcludingRussia(
                                    vpn,
                                    latencies,
                                  );
                                  final autoHasPing =
                                      autoPing != null && autoPing > 0;
                                  final autoState = pinging
                                      ? 'подбор оптимального узла…'
                                      : autoHasPing
                                      ? 'пинг $autoPing мс'
                                      : latencies.any((value) => value == -1)
                                      ? 'часть серверов недоступна'
                                      : 'нажмите «Пинг» для замера';
                                  final autoColor = autoHasPing
                                      ? pingColorFor(autoPing)
                                      : c.muted;
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                    ),
                                    child: _BounceButton(
                                      onTap: () => state.setAutoMode(
                                        !state.autoModeEnabled,
                                      ),
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 250,
                                        ),
                                        curve: Curves.easeOutCubic,
                                        padding: const EdgeInsets.fromLTRB(
                                          14,
                                          12,
                                          14,
                                          12,
                                        ),
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                            colors: state.autoModeEnabled
                                                ? [
                                                    SgColors.blue.withValues(
                                                      alpha: 0.24,
                                                    ),
                                                    SgColors.violet.withValues(
                                                      alpha: 0.16,
                                                    ),
                                                  ]
                                                : [c.pill, c.pill],
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            22,
                                          ),
                                          border: Border.all(
                                            color: state.autoModeEnabled
                                                ? SgColors.blue.withValues(
                                                    alpha: 0.55,
                                                  )
                                                : c.line,
                                          ),
                                          boxShadow: state.autoModeEnabled
                                              ? [
                                                  BoxShadow(
                                                    color: SgColors.blue
                                                        .withValues(alpha: 0.3),
                                                    blurRadius: 24,
                                                    offset: const Offset(0, 8),
                                                  ),
                                                ]
                                              : null,
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 42,
                                              height: 42,
                                              alignment: Alignment.center,
                                              decoration: BoxDecoration(
                                                gradient: const LinearGradient(
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                  colors: [
                                                    SgColors.blue,
                                                    SgColors.violet,
                                                  ],
                                                ),
                                                shape: BoxShape.circle,
                                                boxShadow:
                                                    state.autoModeEnabled
                                                    ? [
                                                        BoxShadow(
                                                          color: SgColors.blue
                                                              .withValues(
                                                                alpha: 0.45,
                                                              ),
                                                          blurRadius: 16,
                                                        ),
                                                      ]
                                                    : null,
                                              ),
                                              child: const Icon(
                                                Icons.auto_awesome_rounded,
                                                color: Colors.white,
                                                size: 20,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      Text(
                                                        'Авто',
                                                        style: TextStyle(
                                                          color: c.ink,
                                                          fontWeight:
                                                              FontWeight.w900,
                                                          fontSize: 15.5,
                                                        ),
                                                      ),
                                                      if (state
                                                          .autoModeEnabled) ...[
                                                        const SizedBox(
                                                          width: 6,
                                                        ),
                                                        const _PulseDot(
                                                          color: SgColors.teal,
                                                          size: 6,
                                                        ),
                                                      ],
                                                    ],
                                                  ),
                                                  const SizedBox(height: 3),
                                                  Text(
                                                    autoState,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: autoColor,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      fontSize: 11.5,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Transform.scale(
                                              scale: 0.9,
                                              child: Switch(
                                                value: state.autoModeEnabled,
                                                onChanged: state.setAutoMode,
                                                materialTapTargetSize:
                                                    MaterialTapTargetSize
                                                        .shrinkWrap,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                }
                                final g = baseGroups[gi - 1];
                                final bestPing = g.bestPing(latencies);
                                final accent = SgColors.violet;
                                final isSelected =
                                    g.selectedProfileIndex(vpn.selectedIndex) !=
                                    null;
                                final locationCode = _countryCodeFor(
                                  g.representativeRemark,
                                );
                                final isRu = isRussianLocation(
                                  g.representativeRemark,
                                );
                                final hasTimeout = g.hosts.any((host) {
                                  final value =
                                      host.profileIndex < latencies.length
                                      ? latencies[host.profileIndex]
                                      : null;
                                  return value == -1;
                                });
                                final hasPing = bestPing != null && bestPing > 0;
                                final pingLabel = hasPing
                                    ? '$bestPing мс'
                                    : hasTimeout && !pinging
                                    ? 'таймаут'
                                    : 'проверка…';
                                final statusColor = hasPing
                                    ? pingColorFor(bestPing)
                                    : hasTimeout && !pinging
                                    ? SgColors.red
                                    : c.muted;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                  ),
                                  child: _BounceButton(
                                    onTap: () {
                                      final firstIndex =
                                          g.hosts.first.profileIndex;
                                      state.selectServer(firstIndex);
                                      Navigator.pop(sheetContext);
                                    },
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 250,
                                      ),
                                      curve: Curves.easeOutCubic,
                                      padding: const EdgeInsets.fromLTRB(
                                        12,
                                        12,
                                        12,
                                        12,
                                      ),
                                      decoration: BoxDecoration(
                                        gradient: isSelected
                                            ? LinearGradient(
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                                colors: [
                                                  accent.withValues(alpha: 0.18),
                                                  SgColors.blue.withValues(
                                                    alpha: 0.08,
                                                  ),
                                                ],
                                              )
                                            : null,
                                        color: isSelected ? null : c.pill,
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                          color: isSelected
                                              ? accent.withValues(alpha: 0.55)
                                              : c.line,
                                        ),
                                        boxShadow: isSelected
                                            ? [
                                                BoxShadow(
                                                  color: accent.withValues(
                                                    alpha: 0.28,
                                                  ),
                                                  blurRadius: 22,
                                                  offset: const Offset(0, 8),
                                                ),
                                              ]
                                            : null,
                                      ),
                                      child: Row(
                                        children: [
                                          _FlagEmoji(
                                            name: g.representativeRemark,
                                            size: 40,
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Flexible(
                                                      child: Text(
                                                        g.locationName,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: c.ink,
                                                          fontWeight:
                                                              FontWeight.w900,
                                                          fontSize: 15.5,
                                                          letterSpacing: -0.2,
                                                        ),
                                                      ),
                                                    ),
                                                    if (locationCode !=
                                                        'world') ...[
                                                      const SizedBox(width: 6),
                                                      _TagChip(
                                                        text: locationCode
                                                            .toUpperCase(),
                                                        color: SgColors.blue,
                                                      ),
                                                    ],
                                                    if (isRu) ...[
                                                      const SizedBox(width: 6),
                                                      const _TagChip(
                                                        text: 'НЕ АВТО',
                                                        color: SgColors.red,
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                                const SizedBox(height: 7),
                                                Wrap(
                                                  spacing: 8,
                                                  runSpacing: 4,
                                                  crossAxisAlignment:
                                                      WrapCrossAlignment.center,
                                                  children: [
                                                    _SignalBars(
                                                      level: _pingLevel(
                                                        bestPing,
                                                      ),
                                                      color: statusColor,
                                                    ),
                                                    Text(
                                                      pingLabel,
                                                      style: TextStyle(
                                                        color: statusColor,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          if (isSelected)
                                            Container(
                                              width: 28,
                                              height: 28,
                                              alignment: Alignment.center,
                                              decoration: const BoxDecoration(
                                                gradient: LinearGradient(
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                  colors: [
                                                    SgColors.blue,
                                                    SgColors.violet,
                                                  ],
                                                ),
                                                shape: BoxShape.circle,
                                              ),
                                              child: const Icon(
                                                Icons.check_rounded,
                                                color: Colors.white,
                                                size: 17,
                                              ),
                                            )
                                          else
                                            Icon(
                                              Icons.chevron_right_rounded,
                                              color: c.muted,
                                              size: 22,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    },
  );
}

/// Rebuilds the location sheet only when something it shows changes.
///
/// The sheet used to listen to the whole application state, so every traffic
/// statistics tick (twice a second while a session is up) rebuilt the header,
/// the auto row and every flag row in the list. That is invisible on a desktop
/// and a stutter on a phone: the list is long and each flag is painted from a
/// custom painter. The signature below keeps the latency numbers, the selection
/// and the sweep state — and drops everything else.
class _LatencyGate extends StatefulWidget {
  const _LatencyGate({required this.state, required this.builder});

  final AppState state;
  final WidgetBuilder builder;

  @override
  State<_LatencyGate> createState() => _LatencyGateState();
}

class _LatencyGateState extends State<_LatencyGate> {
  late String _signature;

  @override
  void initState() {
    super.initState();
    _signature = _readSignature();
    widget.state.addListener(_onStateChanged);
  }

  @override
  void didUpdateWidget(covariant _LatencyGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onStateChanged);
      widget.state.addListener(_onStateChanged);
      _signature = _readSignature();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    super.dispose();
  }

  String _readSignature() {
    final vpn = widget.state.vpn;
    return '${vpn.serverLatencies.join(',')}|${vpn.selectedIndex}|'
        '${widget.state.autoSelectingServer}|${widget.state.autoModeEnabled}|'
        '${vpn.state.name}';
  }

  void _onStateChanged() {
    if (!mounted) return;
    final next = _readSignature();
    if (next == _signature) return;
    _signature = next;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Builder(builder: widget.builder);
}

/// Compact action pill used in the location sheet header.
class _SheetPill extends StatelessWidget {
  const _SheetPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return _BounceButton(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: enabled ? 1 : 0.6,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(99),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [SgColors.blue, SgColors.violet],
            ),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: SgColors.violet.withValues(alpha: 0.35),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              else
                Icon(icon, color: Colors.white, size: 15),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small pill used for country codes, throughput and the "auto excludes me"
/// marker. Everything in the location list is a chip so the row reads like a
/// game client's server browser.
class _TagChip extends StatelessWidget {
  const _TagChip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// Five ascending bars, the way a game client shows connection quality.
class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.level, required this.color});

  /// `0` = no signal, `1` = full signal.
  final double level;
  final Color color;

  /// Number of bars drawn. Five reads as a game server's signal meter.
  static const int _bars = 5;

  @override
  Widget build(BuildContext context) {
    final active = (level.clamp(0.0, 1.0) * _bars).round().clamp(0, _bars);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(_bars, (i) {
        final on = i < active;
        final t = (i + 1) / _bars;
        return Padding(
          padding: EdgeInsets.only(right: i == _bars - 1 ? 0 : 2),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            width: 3.5,
            height: 15 * (0.4 + 0.6 * t),
            decoration: BoxDecoration(
              color: on ? color : color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }),
    );
  }
}

/// A softly pulsing dot — the "live" marker in a game client.
class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.25 + 0.5 * t),
                blurRadius: 3 + 6 * t,
                spreadRadius: 0.5 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Maps a latency reading to a `0..1` signal level, lower being better.
double _pingLevel(int? ms) {
  if (ms == null || ms <= 0) return 0;
  if (ms <= 40) return 1;
  if (ms >= 320) return 0.15;
  return 1 - (ms - 40) * 0.85 / 280;
}
