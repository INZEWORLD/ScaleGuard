import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../core/binary_integrity.dart';
import '../core/bypass_domains.dart';
import '../core/device_identity.dart';
import '../core/qr_link.dart';
import '../core/vpn_engine.dart';
import '../core/windows_autostart.dart';
import '../core/windows_deep_link.dart';
import '../core/windows_elevation.dart';
import '../core/windows_helper.dart';
import '../core/windows_kill_switch.dart';
import '../core/windows_shell.dart';
import '../core/windows_tun.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/device_service.dart';
import '../services/log_service.dart';
import '../services/notification_service.dart';
import '../services/payment_service.dart';
import '../services/storage_service.dart';
import '../services/vpn_service.dart';

/// The first thing standing between the user and a live tunnel.
///
/// Windows asks for them one at a time — the elevated token first, the Wintun
/// driver after it — and each one is its own window. The enum is what lets the
/// home screen keep saying what is still missing after a window is dismissed,
/// instead of leaving the switch doing nothing.
enum ConnectRequirement { admin, tunDriver }

/// What the connection-mode picker offers the user.
///
/// Two of the three presets are the same platform mode (a full tunnel) and
/// differ only in whether Russian services stay on the user's own connection;
/// the third avoids the tunnel entirely and needs no administrator rights.
enum TunnelPreset {
  /// Russian sites direct, everything else through the location.
  rules,

  /// Everything through the location, Russian sites included.
  fullTraffic,

  /// No tunnel: the WinINet system proxy, for machines without elevation.
  systemProxy,
}

class AppState extends ChangeNotifier {
  AppState({
    required StorageService storage,
    required ApiClient api,
    required AuthService auth,
    required PaymentService payments,
    required NotificationService notifications,
    required VpnService vpn,
  }) : _storage = storage,
       _api = api,
       _auth = auth,
       _payments = payments,
       _notifications = notifications,
       _vpn = vpn;

  final StorageService _storage;
  final ApiClient _api;
  final AuthService _auth;
  final PaymentService _payments;
  final NotificationService _notifications;
  final VpnService _vpn;

  /// Reads and edits the devices the panel has bound to this subscription.
  late final DeviceService _devices = DeviceService(_api);

  bool bootstrapping = true;
  bool busy = false;

  /// True when the dashboard was painted from the local profile cache.
  ///
  /// The splash screen uses this to disappear immediately on a warm return
  /// instead of replaying its launch animation while the network catches up.
  bool restoredCachedSession = false;

  /// True while the process is handing over to a restarted copy of itself.
  ///
  /// The hand-over is not instant — the tunnel is taken down, the UAC window is
  /// shown and the replacement has to claim the single-instance port — so the
  /// window would otherwise look frozen with nothing to explain the delay.
  bool restarting = false;

  /// Whether the user was already sent to the system battery screen.
  ///
  /// Vendor shells do not report their own battery switch through the public
  /// API: MIUI can show "no restrictions" while the API keeps answering
  /// "restricted". Sending the user there on every launch would be asking for
  /// something that is already done, so a request that was carried out is
  /// remembered instead of being re-checked forever.
  bool backgroundBatteryAsked = false;

  /// The user has been sent to the per-application battery page
  /// ("Расход заряда батареи").
  ///
  /// A separate gate from the exemption above: the exemption keeps Doze away,
  /// while the restriction level on that page is what vendor shells use to kill
  /// a background service. It is never readable through the public API, so the
  /// request is remembered once made, exactly like [backgroundBatteryAsked].
  bool backgroundBatteryUsageAsked = false;

  /// True when the last launch could not reach the backend at all.
  ///
  /// The window then shows the offline page instead of the sign-in screen: a
  /// failed request is not a reason to ask for a password, and the retry
  /// button is the only useful action while the network is down.
  bool offline = false;

  /// Whether the Android background flow was completed on a vendor whose
  /// battery state cannot be read back (see [StorageService]).
  bool yandexPending = false;
  bool telegramPending = false;

  /// The selected bottom-navigation slot.
  ///
  /// A [ValueNotifier] on purpose: all four tabs are mounted at once and every
  /// one of them watches [AppState], so a notification here rebuilt all four
  /// pages. On a weak phone that rebuild was most of the frame budget the tab
  /// transition needed. Only the shell listens to this value; nothing else
  /// depends on which tab is showing.
  final ValueNotifier<int> shellTab = ValueNotifier<int>(0);
  // A client that paints itself white on a phone set to dark is the first thing
  // a new user sees, and it looks broken. Until the user picks a theme, the
  // system's choice is the only correct one.
  ThemeMode themeMode = ThemeMode.system;
  String? _error;
  String? _info;
  Timer? _messageTimer;

  /// The last failure worth reading, or `null`.
  ///
  /// Every message is put on a timer. A banner that outlives its reason stops
  /// being information and becomes furniture: the sign-in screen's "Код отправлен
  /// на email" used to sit over the tariff list for the rest of the session.
  String? get error => _error;
  set error(String? value) {
    _error = value;
    _restartMessageTimer();
  }

  /// The last confirmation worth reading, or `null`.
  String? get info => _info;
  set info(String? value) {
    _info = value;
    _restartMessageTimer();
  }

  /// Hides whatever is on screen once it has had time to be read.
  ///
  /// A failure usually carries an instruction and gets the longer pause; a
  /// confirmation is one line. Clearing only the message that is up keeps a
  /// fresh note from being wiped by a timer armed for an older one.
  void _restartMessageTimer() {
    _messageTimer?.cancel();
    _messageTimer = null;
    if (_error == null && _info == null) return;
    _messageTimer = Timer(
      _error != null
          ? const Duration(seconds: 14)
          : const Duration(seconds: 10),
      () {
        _messageTimer = null;
        if (_error == null && _info == null) return;
        _error = null;
        _info = null;
        notifyListeners();
      },
    );
  }

  AuthConfig? authConfig;
  PublicUser? user;
  TunnelInfo? tunnel;
  TrialInfo? trial;

  /// The QR code this device is showing, or `null` when no code is up.
  QrLoginSession? qrSession;

  /// True while a code is being fetched or a scanned one is being confirmed.
  bool qrBusy = false;

  /// True once the code on screen has let a device in.
  bool qrSolved = false;

  /// What the panel calls the state of the code on screen, for the subtitle.
  String? qrStatus;

  /// When the code on screen is replaced by a fresh one.
  DateTime? qrRotatesAt;

  Timer? _qrPollTimer;
  Timer? _qrRotateTimer;
  bool _qrApprovedThisSession = false;

  /// This installation's identifier for the panel's device limit (`x-hwid`).
  DeviceIdentity? device;

  /// True when the subscription's device limit is what is blocking a connect.
  bool deviceLimitReached = false;

  List<VpnPlan> plans = [];
  bool plansLoading = false;
  PaymentProviders? paymentProviders;
  String? pendingTopUpPaymentId;
  int? pendingTopUpPlanId;

  /// Seconds left of a pause the server imposed after too many attempts.
  ///
  /// Sign-in and email codes allow five attempts and then wait a minute and a
  /// half. The server says how long is left; counting it down here is what lets
  /// the screens keep the button shut instead of letting the user knock again.
  int retryAfterSeconds = 0;

  Timer? _cooldownTimer;

  /// The devices bound to the subscription, and how the list is going.
  HwidDevices? devices;
  bool devicesLoading = false;
  String? devicesError;

  /// Watches a payment that is open in the browser, so the plan activates
  /// without the user having to come back and press a button.
  Timer? _topUpPollTimer;
  int _topUpPollTicks = 0;
  static const int _topUpPollLimit = 60;

  Timer? _telegramPollTimer;
  String? _telegramSessionToken;

  int vpnDownloadBps = 0;
  int vpnUploadBps = 0;
  int vpnPingMs = 0;
  bool autoSelectingServer = false;

  /// Whether the core is allowed to choose the location by itself.
  bool autoModeEnabled = true;

  /// Whether the tunnel should reconnect automatically on the next launch.
  ///
  /// Off unless the user asks for it. A switch that flips itself on after the
  /// application was closed is indistinguishable from a bug, and the launch is
  /// exactly the moment where the user is not expecting traffic to leave.
  bool autoConnectOnLaunch = false;

  /// Games connect directly to the provider, the rest stays proxied.
  bool gameModeEnabled = false;

  /// The bypass list exactly as the user typed it, commas and all.
  String bypassDomains = '';

  /// Russian sites stay on the user's own connection.
  bool ruDirectEnabled = true;

  /// Restart the application as administrator on every launch.
  ///
  /// TUN is the default mode and needs an elevated token, so this switch is what
  /// turns a UAC prompt on every start into a single prompt the first time.
  bool runAsAdmin = false;

  /// Set when a start was attempted that TUN cannot do without elevated rights.
  ///
  /// The home screen watches this and turns it into the "restart as
  /// administrator" dialog; it is deliberately not an `error`, because nothing
  /// has failed yet — the user just has to make a choice.
  bool adminRestartPrompt = false;

  /// Cached result of the elevation check, so the settings screen can describe
  /// the current state without spawning PowerShell on every rebuild.
  bool elevated = false;

  /// Whether this machine has the kernel driver TUN needs.
  TunDriverStatus tunDriver = TunDriverStatus.unknown;

  /// Set when a connect was stopped because that driver is missing, so the home
  /// screen can offer to install it.
  bool tunDriverPrompt = false;

  /// The gate the last connect attempt stopped at, if it stopped at one.
  ///
  /// While this is non-null the home screen shows the request under the connect
  /// button, one requirement at a time, so a dismissed window never looks like a
  /// broken switch.
  ConnectRequirement? connectRequirement;

  bool tunDriverInstalling = false;

  /// Result of the last integrity check of the bundled core.
  IntegrityReport integrity = const IntegrityReport.unavailable();

  /// Whether the application is registered to start with the Windows session.
  bool autostartEnabled = false;

  /// Whether closing the window hides the application to the tray instead of
  /// quitting it. On by default: closing a VPN window should not drop a tunnel.
  bool closeToTray = true;

  bool loggingEnabled = true;

  VpnTunnelMode tunnelMode = VpnTunnelMode.tun;

  /// True while a latency sweep is running.
  bool latencySweepRunning = false;
  String? externalIp;

  /// True while the public-address lookup is in flight, so the card can show a
  /// placeholder instead of a dash that looks like a failure.
  bool externalIpLoading = false;

  /// Short-lived banner describing an automatic location change.
  String? locationNotice;

  VpnService get vpn => _vpn;
  String? get currentServerHost => _vpn.extractHostPort(_vpn.selectedIndex);

  void attachVpnListener() {
    _vpn.onAutoLocationChange = noteLocationChange;
    _vpn.onNotice = noteNotice;
    _vpn.onStatusChanged = (state, _) {
      // `onStatusChanged` fires on every assignment, not only on real changes,
      // so the transitions are worked out here — they are what the follow-up
      // work hangs off.
      final previous = _lastVpnState;
      _lastVpnState = state;
      unawaited(
        WindowsShell.setTrayState(
          connected: state == VpnConnectionState.connected,
          location: _vpn.activeProxyName,
        ),
      );
      if (state == VpnConnectionState.connected &&
          previous != VpnConnectionState.connected) {
        _onTunnelUp();
      } else if (state != VpnConnectionState.connected &&
          previous == VpnConnectionState.connected) {
        _onTunnelDown();
      }
      notifyListeners();
    };
    _vpn.onSpeedStats = (stats) {
      vpnDownloadBps = stats.downloadBytesPerSec;
      vpnUploadBps = stats.uploadBytesPerSec;
      vpnPingMs = stats.pingMs;
      notifyListeners();
    };
  }

  VpnConnectionState _lastVpnState = VpnConnectionState.disconnected;

  /// Everything that has to happen once a tunnel comes up.
  ///
  /// Kept in one place on the status transition rather than in the connect
  /// button, because a tunnel can also appear from a restored session or from
  /// the client's own recovery after a core crash — and all three need the same
  /// follow-up: the public address, its periodic refresh, and a first latency
  /// sweep so the location tile and the monitoring card are not left empty.
  void _onTunnelUp() {
    unawaited(_storage.saveSessionWasUp(true));
    unawaited(refreshExternalIp());
    _startExternalIpRefresh();
    unawaited(pingAllAndMaybeSelect(applyAuto: false));
    // The tunnel adapter exists now, so the firewall can be told to leave what
    // goes through it alone.
    unawaited(_allowKillSwitchTunnel());
  }

  void _onTunnelDown() {
    _externalIpTimer?.cancel();
    _externalIpTimer = null;
    externalIp = null;
    externalIpLoading = false;
    vpnPingMs = 0;
  }

  /// How many times the public address is re-read before the card gives up for
  /// this attempt. A failed attempt is usually a connection timeout, so the
  /// count is kept low: the periodic refresh covers the rest.
  static const int _externalIpAttempts = 3;

  static const Duration _externalIpRetryDelay = Duration(seconds: 2);

  Timer? _externalIpTimer;

  /// Shows a short banner when the core moved the tunnel to another location on
  /// its own, so the change is visible instead of silent.
  void noteLocationChange(String remark) {
    if (remark.isEmpty) return;
    locationNotice = 'Локация изменена: $remark';
    _locationNoticeTimer?.cancel();
    _locationNoticeTimer = Timer(const Duration(seconds: 6), () {
      locationNotice = null;
      notifyListeners();
    });
  }

  Timer? _locationNoticeTimer;

  /// Shows a short banner for something the client did on its own behalf.
  ///
  /// Kept separate from [noteLocationChange] because not every notice is a
  /// location change: "the node you were on stopped answering" is different news
  /// from "the core moved you", and rewording the first as the second would hide
  /// the reason the location moved at all.
  void noteNotice(String message) {
    if (message.isEmpty) return;
    locationNotice = message;
    _locationNoticeTimer?.cancel();
    _locationNoticeTimer = Timer(const Duration(seconds: 8), () {
      locationNotice = null;
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> bootstrap() async {
    bootstrapping = true;
    offline = false;
    restoredCachedSession = false;
    notifyListeners();

    String? token;
    try {
      token = await _storage.readToken();
      if (token != null && token.isNotEmpty) {
        _api.setToken(token);
        // Android may have killed the UI process while the native VPN service
        // stayed up. The cached profile is not authoritative — the refresh
        // below replaces it — but it is enough to show the dashboard without
        // another full splash-and-spinner launch.
        await _restoreCachedProfile();
        if (user != null) {
          bootstrapping = false;
          notifyListeners();
        }
      }
      loggingEnabled = await _storage.readLogging();
      await _initLogging();
      final savedTunnelMode = await _storage.readTunnelMode();
      // TUN is the default: it is the mode that covers every application. The
      // system proxy is an explicit opt-in, so anything other than a saved
      // "systemProxy" — including a first launch — means TUN.
      tunnelMode = savedTunnelMode == VpnTunnelMode.systemProxy.name
          ? VpnTunnelMode.systemProxy
          : VpnTunnelMode.tun;
      runAsAdmin = await _storage.readRunAsAdmin();
      closeToTray = await _storage.readCloseToTray();
      killSwitchEnabled = await _storage.readKillSwitch();
      unawaited(WindowsShell.setCloseToTray(closeToTray));
      unawaited(refreshElevation());
      unawaited(refreshTunDriver());
      unawaited(refreshAutostart());
      unawaited(refreshHelper());
      unawaited(verifyCoreIntegrity());
      // A client that was killed while the kill switch was engaged leaves the
      // machine with no internet at all. Undoing that comes before anything else
      // touches the network — and it is the reason the switch keeps a record on
      // disk in the first place.
      await _releaseStaleKillSwitch();
      LogService.instance.log('app', 'app started (mode: ${tunnelMode.name})');
      final savedTheme = await _storage.readThemeMode();
      // Before the theme picker existed the client wrote "light" at launch, so a
      // stored "light" is not proof that the user ever chose it. Only a choice
      // made in the settings screen is remembered as one; anything else follows
      // the system, which is what a phone set to dark should look like on the
      // very first screen.
      final themeChosen = await _storage.readThemeChosen();
      themeMode = switch (savedTheme) {
        'dark' => ThemeMode.dark,
        'light' => themeChosen ? ThemeMode.light : ThemeMode.system,
        _ => ThemeMode.system,
      };
      autoConnectOnLaunch = await _storage.readAutoConnect();
      final previousSessionUp = await _storage.readSessionWasUp();
      backgroundBatteryAsked = await _storage.readBackgroundBatteryAsked();
      backgroundBatteryUsageAsked = await _storage
          .readBackgroundBatteryUsageAsked();
      gameModeEnabled = await _storage.readGameMode();
      bypassDomains = await _storage.readBypassDomains() ?? '';
      // Russian services keep the user's own connection by default: the tunnel
      // is only useful while banks, government portals and similar services
      // behave as if there were no VPN at all. The mode picker exposes one
      // explicit alternative — "весь трафик" — where this flag is off. The
      // user's own domain list overrides it in every mode.
      ruDirectEnabled = await _storage.readRuDirect();
      await _vpn.setRoutingMode(
        gameMode: gameModeEnabled,
        bypassDomains: parseBypassDomains(bypassDomains),
        ruDirect: ruDirectEnabled,
      );
      final online = await _api.hasNetwork();
      if (!online) offline = true;
      if (online) {
        try {
          authConfig = await _auth.fetchAuthConfig();
        } catch (e) {
          if (_api.isOfflineError(e)) offline = true;
          authConfig = AuthConfig(
            telegramEnabled: true,
            yandexEnabled: true,
            hcaptchaEnabled: false,
            telegramBotName: AppConfig.telegramBotName,
          );
          error = 'Сервер авторизации: ${_api.extractError(e)}';
        }
      }
      authConfig ??= AuthConfig(
        telegramEnabled: true,
        yandexEnabled: true,
        hcaptchaEnabled: false,
        telegramBotName: AppConfig.telegramBotName,
      );
      // Resolved before anything touches the subscription, because the panel
      // binds the device on the subscription request itself.
      await _resolveDeviceIdentity();
      // Windows has no manifest declaring the `scaleguard://` scheme, so the
      // browser has nowhere to hand the user back after Yandex/Telegram login
      // unless the application claims it. Best effort: a failure only affects
      // that hand-off, never normal sign-in.
      await _ensureDesktopDeepLink();
      if (token != null && token.isNotEmpty) {
        _api.setToken(token);
        if (online) await refreshProfile(silent: true);
      }
      await _vpn.initialize();
      attachVpnListener();
      await _notifications.initialize();
      pendingTopUpPaymentId = await _storage.readPendingTopUpPaymentId();
      pendingTopUpPlanId = await _storage.readPendingTopUpPlanId();
      // A tunnel that survived the window is taken over before anything tries
      // to start a new one: on Android it lives in a foreground service, and a
      // second start would tear down the connection that is still working.
      final adopted = await _vpn.adoptRunningTunnel(mode: tunnelMode);
      if (!adopted) {
        // Android: pay for the core process and library now, not when the user
        // presses "Подключить".
        unawaited(_vpn.warmUp());
        // A tunnel that was up when the process ended — window closed, task
        // killed, phone battery of the app cleared — is not something to bring
        // back on its own: the switch would flip before the user touches
        // anything, and the only way to stop it would be to wait for the
        // connect to finish. The flag stays set until they connect again or
        // switch it off deliberately.
        if (previousSessionUp) {
          LogService.instance.log(
            'app',
            'auto-connect skipped: the previous session was up',
          );
          unawaited(pingAllAndMaybeSelect());
        } else {
          final willAutoConnect =
              autoConnectOnLaunch &&
              tunnel?.hasActiveSubscription == true &&
              _vpn.profiles.isNotEmpty;
          if (willAutoConnect) {
            unawaited(_restoreTunnelSession());
          } else {
            // The location tile is the first thing the user looks at, and the
            // manual connect should not have to wait for a sweep afterwards:
            // measure now, so it shows a number and the fastest node is already
            // chosen when "Подключить" is pressed.
            unawaited(pingAllAndMaybeSelect());
          }
        }
      }
      // A connect that had to restart the client to get past the elevation
      // prompt continues here. Without this the user would grant the rights and
      // then have to press the switch again to see the next window — or, worse,
      // assume the connection failed.
      if (!adopted && await _storage.readPendingConnect()) {
        await _storage.savePendingConnect(false);
        if (tunnel?.hasActiveSubscription == true) {
          LogService.instance.log('app', 'resuming connect after the restart');
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 900), toggleVpn),
          );
        }
      }
    } catch (e) {
      error = _api.extractError(e);
    } finally {
      bootstrapping = false;
      notifyListeners();
    }
  }

  /// Runs the launch sequence again from the offline page.
  ///
  /// The offline screen has one button and this is what it does: no token is
  /// touched, so a successful retry lands on exactly the screen the user would
  /// have seen had the network been there in the first place.
  Future<void> retryConnection() => bootstrap();

  /// Restores the last profile snapshot from secure storage.
  ///
  /// A missing or unreadable cache is not an error: the normal network refresh
  /// follows and fills the state from scratch.
  Future<void> _restoreCachedProfile() async {
    try {
      final raw = await _storage.readProfileSnapshot();
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await _storage.clearProfileSnapshot();
        return;
      }
      final snapshot = ProfileSnapshot.fromJson(decoded);
      user = snapshot.user;
      tunnel = snapshot.tunnel;
      trial = snapshot.trial;
      restoredCachedSession = true;
    } catch (_) {
      await _storage.clearProfileSnapshot();
    }
  }

  Future<void> _saveCachedProfile() async {
    if (user == null || tunnel == null || trial == null) return;
    try {
      await _storage.saveProfileSnapshot(
        jsonEncode(
          ProfileSnapshot(user: user!, tunnel: tunnel!, trial: trial!).toJson(),
        ),
      );
    } catch (_) {
      // The cache only makes the next launch faster; it must never fail a
      // profile refresh.
    }
  }

  Future<void> _initLogging() async {
    String? primary;
    String? fallback;
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      primary = '${exeDir}${Platform.pathSeparator}scaleguard_log.txt';
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        fallback =
            '$appData${Platform.pathSeparator}ScaleGuard'
            '${Platform.pathSeparator}logs'
            '${Platform.pathSeparator}scaleguard_log.txt';
      }
    } else {
      try {
        final docs = await getApplicationDocumentsDirectory();
        primary =
            '${docs.path}${Platform.pathSeparator}logs'
            '${Platform.pathSeparator}scaleguard_log.txt';
      } catch (_) {
        primary = null;
      }
      fallback =
          '${Directory.systemTemp.path}'
          '${Platform.pathSeparator}scaleguard_log.txt';
    }
    if (primary == null) return;
    LogService.instance.configure(
      path: primary,
      fallbackPath: fallback,
      enabled: loggingEnabled,
    );
  }

  /// Reconnects automatically when the "connect on launch" preference is on.
  ///
  /// The user's switch in the settings screen is the single source of truth: a
  /// manual disconnect no longer flips it, so "auto" means the same thing in
  /// both directions. Best effort — a failure never blocks the launch.
  Future<void> _restoreTunnelSession() async {
    try {
      if (_vpn.state != VpnConnectionState.disconnected) return;
      if (!autoConnectOnLaunch) return;
      if (tunnel?.hasActiveSubscription != true) return;
      if (_vpn.profiles.isEmpty) return;
      LogService.instance.log('app', 'auto-connect: restoring tunnel session');
      await toggleVpn();
    } catch (e) {
      LogService.instance.log('app', 'auto-connect failed: $e');
    }
  }

  /// Claims the `scaleguard://` URL scheme for this executable on desktop.
  ///
  /// Only Windows needs it: macOS and iOS take the scheme from the bundle, and
  /// Android from the manifest.
  Future<void> _ensureDesktopDeepLink() async {
    if (!Platform.isWindows) return;
    final registration = WindowsDeepLinkRegistration();
    final executable = Platform.resolvedExecutable;
    final registered = await registration.registeredCommand();
    if (registered != null && registered.contains(executable)) return;
    final ok = await registration.ensureRegistered(executablePath: executable);
    if (!ok) {
      // Not fatal: the user can still sign in with a password or a code.
      // ignore: avoid_print
      print('Deep link registration failed: ${registration.lastError}');
    }
  }

  /// Resolves (once per launch) the identifier this installation reports to the
  /// panel as `x-hwid`, and persists it so it survives a restart.
  Future<void> _resolveDeviceIdentity() async {
    if (device != null) return;
    try {
      device = await resolveDeviceIdentity(
        readStored: _storage.readDeviceHwid,
        writeStored: _storage.saveDeviceHwid,
      );
    } catch (error) {
      // A device identifier is an enhancement, never a prerequisite: without it
      // the client still connects, it just is not counted by the panel.
      // ignore: avoid_print
      print('Device identity unavailable: $error');
    }
  }

  /// Downloads the subscription profile, reporting a device-limit failure
  /// distinctly because the user can act on it (unbind an old device).
  Future<void> _loadSubscriptionProfile(String subscriptionUrl) async {
    await _resolveDeviceIdentity();
    deviceLimitReached = false;
    try {
      await _vpn.loadProfilesFromSubscription(subscriptionUrl, device: device);
    } catch (error) {
      final message = _api.extractError(error);
      if (message.contains('404') || message.toLowerCase().contains('лимит')) {
        deviceLimitReached = true;
      }
      rethrow;
    }
    // A profile that just arrived also tells us when the panel wants it checked
    // again, so the schedule is armed here rather than at startup.
    _armSubscriptionCheck();
  }

  /// How often the subscription is re-read when the panel does not say.
  ///
  /// Two hours matches the default of the panel this client is built for; the
  /// value is only a fallback, because Remnawave normally advertises its own
  /// interval in the response headers.
  static const Duration _defaultSubscriptionInterval = Duration(hours: 2);

  /// Interval currently in force, for the settings screen. `null` while no
  /// subscription is loaded.
  Duration? subscriptionCheckInterval;

  Timer? _subscriptionTimer;

  /// Arms the periodic subscription check.
  ///
  /// The interval is the panel's, not ours: Remnawave advertises it in the
  /// `profile-update-interval` header of the subscription response, which is the
  /// value its own clients honour. The clamp keeps a typo in the panel's setting
  /// from turning into a request storm or into a check that never runs at all.
  void _armSubscriptionCheck() {
    _subscriptionTimer?.cancel();
    _subscriptionTimer = null;
    if ((tunnel?.subscriptionUrl ?? '').isEmpty) return;
    final hours = _vpn.subscriptionMetadata?.updateIntervalHours;
    final interval = (hours == null || hours <= 0)
        ? _defaultSubscriptionInterval
        : Duration(hours: hours.clamp(1, 24));
    subscriptionCheckInterval = interval;
    _subscriptionTimer = Timer.periodic(
      interval,
      (_) => unawaited(_refreshSubscription()),
    );
    LogService.instance.log(
      'app',
      'subscription check every ${interval.inHours} h',
    );
  }

  void _disarmSubscriptionCheck() {
    _subscriptionTimer?.cancel();
    _subscriptionTimer = null;
    subscriptionCheckInterval = null;
  }

  /// Re-reads the node list from the panel.
  ///
  /// Runs while the tunnel is up as happily as while it is down: what is being
  /// checked is the subscription itself — new nodes, nodes that disappeared, an
  /// expiry — and a stale list is the most common reason a user cannot tell why
  /// a location stopped working. A running tunnel adopts the new list through
  /// the controller, so nothing is interrupted.
  Future<void> _refreshSubscription() async {
    final url = tunnel?.subscriptionUrl ?? '';
    if (url.isEmpty) return;
    try {
      final before = _vpn.profiles.length;
      await _loadSubscriptionProfile(url);
      final after = _vpn.profiles.length;
      LogService.instance.log(
        'app',
        'subscription checked: $before -> $after nodes',
      );
      if (before != after) {
        await _vpn.adoptRefreshedServers();
      }
      notifyListeners();
    } catch (error) {
      // The list already in memory keeps working, so a failed check stays out of
      // `error`: it is only worth surfacing when the user has no nodes at all,
      // and that path reports it themselves.
      LogService.instance.log('app', 'subscription check failed: $error');
    }
  }

  Future<void> refreshProfile({bool silent = false}) async {
    if (!silent) {
      busy = true;
      notifyListeners();
    }
    try {
      final profile = await _auth.fetchProfile();
      user = profile.user;
      tunnel = profile.tunnel;
      trial = profile.trial;
      error = null;
      offline = false;
      await _saveCachedProfile();

      if (profile.tunnel.hasActiveSubscription &&
          profile.tunnel.subscriptionUrl.isNotEmpty) {
        await _loadSubscriptionProfile(profile.tunnel.subscriptionUrl);
      }
      await _notifications.syncSubscriptionReminders(profile.tunnel);
    } catch (e) {
      if (_api.isUnauthorized(e)) {
        await logout();
        error = 'Сессия истекла. Войдите снова.';
        return;
      }
      if (_api.isOfflineError(e)) offline = true;
      if (!silent) error = _api.extractError(e);
    } finally {
      if (!silent) {
        busy = false;
        notifyListeners();
      } else {
        notifyListeners();
      }
    }
  }

  Future<void> _persistSession(String token, PublicUser nextUser) async {
    await _storage.saveToken(token);
    _api.setToken(token);
    user = nextUser;
    offline = false;
  }

  Future<bool> loginWithEmail(String email, String password) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final result = await _auth.login(email: email, password: password);
      await _persistSession(result.token, result.user);
      await refreshProfile(silent: true);
      return true;
    } catch (e) {
      _applyCooldown(e);
      error = _api.extractError(e);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> registerWithEmail({
    required String email,
    required String password,
    required String code,
    String? name,
  }) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final result = await _auth.register(
        email: email,
        password: password,
        verificationCode: code,
        name: name,
      );
      await _persistSession(result.token, result.user);
      await refreshProfile(silent: true);
      // The website hands a fresh account its trial from a button; the client
      // does it outright, because an empty account is the only moment the trial
      // is worth anything and a second click there adds nothing.
      if (trial?.enabled == true &&
          trial?.available == true &&
          tunnel?.hasActiveSubscription != true) {
        await activateTrial();
      }
      return true;
    } catch (e) {
      error = _api.extractError(e);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<({bool exists, bool hasPassword})?> lookupEmail(String email) async {
    busy = true;
    error = null;
    info = null;
    notifyListeners();
    try {
      return await _auth.lookupEmail(email);
    } catch (e) {
      error = _api.extractError(e);
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Whether the sign-in and email-code buttons have to stay shut.
  bool get cooldownActive => retryAfterSeconds > 0;

  /// A `1:12` label for the pause the server imposed.
  String get cooldownLabel {
    final total = retryAfterSeconds;
    final minutes = total ~/ 60;
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// Starts the pause the server asked for after too many attempts.
  void _applyCooldown(Object error) {
    final payload = _api.tryExtractErrorPayload(error);
    final raw = payload?['retryAfterSeconds'];
    final seconds = raw is num ? raw.toInt() : 0;
    if (seconds <= 0) return;
    _cooldownTimer?.cancel();
    retryAfterSeconds = seconds;
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      retryAfterSeconds -= 1;
      if (retryAfterSeconds <= 0) {
        retryAfterSeconds = 0;
        timer.cancel();
        _cooldownTimer = null;
      }
      notifyListeners();
    });
  }

  Future<bool> requestEmailCode(String email, {required bool register}) async {
    busy = true;
    error = null;
    info = null;
    notifyListeners();
    try {
      await _auth.requestEmailCode(
        email: email,
        mode: register ? 'register' : 'login',
      );
      info = 'Код отправлен на email';
      return true;
    } catch (e) {
      _applyCooldown(e);
      error = _api.extractError(e);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> requestPasswordResetCode(String email) async {
    busy = true;
    error = null;
    info = null;
    notifyListeners();
    try {
      await _auth.requestPasswordResetCode(email);
      info = 'Код для восстановления отправлен на email';
      return true;
    } catch (e) {
      _applyCooldown(e);
      error = _api.extractError(e);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> confirmPasswordReset({
    required String email,
    required String verificationCode,
    required String newPassword,
  }) async {
    busy = true;
    error = null;
    info = null;
    notifyListeners();
    try {
      final result = await _auth.confirmPasswordReset(
        email: email,
        verificationCode: verificationCode,
        newPassword: newPassword,
      );
      await _persistSession(result.token, result.user);
      await refreshProfile(silent: true);
      info = 'Пароль изменён. Вы вошли в аккаунт.';
      return true;
    } catch (e) {
      _applyCooldown(e);
      error = _api.extractError(e);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> loginWithYandex() async {
    busy = true;
    error = null;
    info = null;
    notifyListeners();
    try {
      final url = await _auth.startYandexOAuth();
      if (url.isEmpty) throw StateError('Yandex OAuth URL пуст');
      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
      yandexPending = true;
      info =
          'Откройте Яндекс и подтвердите вход. Затем вернитесь в ScaleGuard.';
    } catch (e) {
      yandexPending = false;
      error = _api.extractError(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Routes a link the operating system handed to the application.
  ///
  /// A `scaleguard://` activation is either a finished sign-in (the browser
  /// coming back with a token) or a QR code that a third-party camera app
  /// opened; the two are told apart by their payload, not by the caller.
  Future<void> handleIncomingLink(Uri uri) async {
    if (qrSessionIdFromLink(uri.toString()) != null && uri.host == 'qr') {
      await signInWithQrCode(uri.toString());
      return;
    }
    await handleOAuthDeepLink(uri);
  }

  Future<void> handleOAuthDeepLink(Uri uri) async {
    final token =
        uri.queryParameters['oauth_token'] ??
        uri.queryParameters['token'] ??
        uri.queryParameters['auth_token'];
    if (token != null && token.length >= 20) {
      yandexPending = false;
      telegramPending = false;
      await _storage.saveToken(token);
      _api.setToken(token);
      LogService.instance.log('auth', 'OAuth deep link received');
      try {
        await refreshProfile();
      } catch (e) {
        LogService.instance.log('auth', 'OAuth deep link error: $e');
      }
      // `refreshProfile` reports its own failures instead of throwing, so the
      // signed-in user is the only honest signal that the link worked. One that
      // did not — a link already used, or one that sat on disk past its token's
      // lifetime — must not leave a broken session behind.
      if (user != null) {
        info = 'Вход выполнен';
      } else {
        await _storage.clearToken();
        await _storage.clearProfileSnapshot();
        _api.setToken(null);
        restoredCachedSession = false;
        error = 'Ссылка входа устарела. Войдите снова.';
        LogService.instance.log('auth', 'OAuth deep link was not accepted');
      }
      notifyListeners();
      return;
    }

    final oauthError =
        uri.queryParameters['oauth_error'] ?? uri.queryParameters['error'];
    if (oauthError != null) {
      yandexPending = false;
      error =
          uri.queryParameters['oauth_error_message'] ??
          uri.queryParameters['error_message'] ??
          'OAuth ошибка: $oauthError';
      notifyListeners();
    }
  }

  Future<void> startTelegramLogin() async {
    _stopTelegramPolling();
    busy = true;
    error = null;
    info = null;
    notifyListeners();
    try {
      final session = await _auth.startTelegramSession();
      _telegramSessionToken = session.sessionToken;
      telegramPending = true;
      final uri = Uri.parse(session.botUrl);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }

      _telegramPollTimer = Timer.periodic(
        Duration(
          milliseconds: session.pollIntervalMs.clamp(1000, 5000).toInt(),
        ),
        (_) => _pollTelegramSession(),
      );
      info =
          'Откройте бота и подтвердите вход. Приложение само подхватит сессию.';
    } catch (e) {
      telegramPending = false;
      error = _api.extractError(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _pollTelegramSession() async {
    final token = _telegramSessionToken;
    if (token == null) return;

    try {
      final result = await _auth.pollTelegramSession(token);
      if (result.status == 'approved') {
        _stopTelegramPolling();
        telegramPending = false;
        if (result.token != null && result.user != null) {
          await _persistSession(result.token!, result.user!);
          await refreshProfile(silent: true);
          info = 'Вход через Telegram выполнен';
        }
        notifyListeners();
      } else if (result.status == 'expired' || result.status == 'missing') {
        _stopTelegramPolling();
        telegramPending = false;
        error = 'Сессия Telegram истекла. Попробуйте снова.';
        notifyListeners();
      }
    } catch (_) {}
  }

  void cancelExternalAuth() {
    _stopTelegramPolling();
    telegramPending = false;
    yandexPending = false;
    info = null;
    notifyListeners();
  }

  void _stopTelegramPolling() {
    _telegramPollTimer?.cancel();
    _telegramPollTimer = null;
    _telegramSessionToken = null;
  }

  // ---------------------------------------------------------------------------
  // Signing in by QR code
  // ---------------------------------------------------------------------------

  /// How long one code lives on screen before it is replaced.
  ///
  /// Short enough that a photograph of the screen goes stale before it can be
  /// used anywhere else, long enough to actually point a camera at it.
  static const Duration qrRotation = Duration(seconds: 40);

  /// Whether the panel on the other end can sign a device in by QR code.
  bool get qrLoginAvailable => authConfig?.qrLoginEnabled == true;

  /// Whether this device can read a code with its camera.
  ///
  /// A desktop has no camera worth aiming at a screen, so it only ever shows
  /// one; the phone is the side that scans.
  bool get canScanQrCode =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// Puts a code on screen and keeps it fresh until it is dismissed.
  ///
  /// The code is replaced every [qrRotation] rather than displayed once, which
  /// is what makes it safe to hold up in front of other people: a copy that was
  /// photographed is worthless a minute later.
  Future<void> showQrLogin() async {
    if (qrSession != null) return;
    qrBusy = true;
    qrSolved = false;
    qrStatus = null;
    error = null;
    notifyListeners();
    try {
      await _openQrSession();
      _qrPollTimer = Timer.periodic(
        const Duration(milliseconds: 1500),
        (_) => _pollQrSession(),
      );
      // The code is replaced on a timer, except in the one moment where that
      // would break the very thing it is for: once a device has announced
      // itself and is waiting to be let in, the code it scanned has to stay
      // valid until the hand-off finishes.
      _qrRotateTimer = Timer.periodic(qrRotation, (_) {
        if (!_qrApprovedThisSession) _openQrSession();
      });
    } catch (e) {
      error = _api.extractError(e);
    } finally {
      qrBusy = false;
      notifyListeners();
    }
  }

  /// Dismisses the code and stops asking the panel about it.
  void hideQrLogin() {
    _stopQrSession();
    qrSession = null;
    qrSolved = false;
    qrStatus = null;
    qrRotatesAt = null;
    notifyListeners();
  }

  Future<void> _openQrSession() async {
    final previous = qrSession;
    final session = await _auth.startQrLoginSession();
    if (session.sessionId.isEmpty) {
      throw StateError('Панель не выдала QR-код');
    }
    // A rotation replaces the code in place. The replaced session is simply
    // abandoned: the panel expires it on its own, and nothing was ever sent to
    // a device that had scanned it.
    if (previous != null) {
      _qrApprovedThisSession = false;
    }
    qrSession = session;
    qrSolved = false;
    qrStatus = null;
    qrRotatesAt = DateTime.now().add(qrRotation);
    notifyListeners();
  }

  Future<void> _pollQrSession() async {
    final session = qrSession;
    if (session == null || qrSolved) return;
    try {
      final result = await _auth.pollQrLoginSession(session.sessionId);

      // This device approved the other one; it is already signed in and must
      // not adopt the session for itself.
      if (_qrApprovedThisSession) {
        if (result.status == 'approved') {
          _stopQrSession();
          qrSolved = true;
          qrStatus = 'Устройство подключено';
          notifyListeners();
        }
        return;
      }

      if (result.status == 'approved' &&
          result.token != null &&
          result.user != null) {
        _stopQrSession();
        await _persistSession(result.token!, result.user!);
        qrSolved = true;
        qrStatus = 'Вход выполнен';
        info = 'Вход выполнен по QR-коду';
        notifyListeners();
        await refreshProfile(silent: true);
        return;
      }

      if (result.status == 'claimed' && user != null) {
        // Somebody is holding their camera against this screen and this device
        // is signed in, so it can let them in right away — that is the whole
        // point of showing the code from inside the application.
        _qrApprovedThisSession = true;
        qrStatus = 'Подтверждаем устройство…';
        notifyListeners();
        await _auth.approveQrLoginSession(session.sessionId);
      }
    } catch (_) {
      // A dropped poll is not a failure; the next tick asks again.
    }
  }

  /// Signs this device in with a code scanned (or pasted) from another one.
  ///
  /// Two shapes, decided by whether this device already has an account:
  /// a signed-in device approves the code and is done, while a signed-out one
  /// announces itself and waits for the other side to do the same.
  Future<bool> signInWithQrCode(String raw) async {
    final sessionId = qrSessionIdFromLink(raw);
    if (sessionId == null) {
      error = 'Это не код ScaleGuard';
      notifyListeners();
      return false;
    }

    qrBusy = true;
    error = null;
    info = null;
    notifyListeners();
    try {
      if (user != null) {
        await _auth.approveQrLoginSession(sessionId);
        info = 'Устройство подключено к вашему аккаунту';
        return true;
      }

      await _auth.claimQrLoginSession(sessionId);
      info = 'Подтвердите вход на устройстве, где открыт QR-код';
      notifyListeners();

      // The device showing the code approves it; a minute is far longer than
      // that takes, and the loop gives up rather than waiting forever.
      for (var attempt = 0; attempt < 40; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final result = await _auth.pollQrLoginSession(sessionId);
        if (result.status == 'approved' &&
            result.token != null &&
            result.user != null) {
          await _persistSession(result.token!, result.user!);
          info = 'Вход выполнен по QR-коду';
          notifyListeners();
          await refreshProfile(silent: true);
          return true;
        }
        if (result.status == 'expired' || result.status == 'missing') {
          error = 'Код устарел. Покажите новый QR-код.';
          return false;
        }
      }
      error = 'Вход не подтвердили. Попробуйте ещё раз.';
      return false;
    } catch (e) {
      error = _api.extractError(e);
      return false;
    } finally {
      qrBusy = false;
      notifyListeners();
    }
  }

  void _stopQrSession() {
    _qrPollTimer?.cancel();
    _qrPollTimer = null;
    _qrRotateTimer?.cancel();
    _qrRotateTimer = null;
    _qrApprovedThisSession = false;
  }

  Future<void> activateTrial() async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final profile = await _auth.activateTrial();
      user = profile.user;
      tunnel = profile.tunnel;
      trial = profile.trial;
      if (profile.tunnel.subscriptionUrl.isNotEmpty) {
        await _loadSubscriptionProfile(profile.tunnel.subscriptionUrl);
      }
      await _notifications.syncSubscriptionReminders(profile.tunnel);
      final days = profile.trial.durationDays ?? 0;
      info = days > 0
          ? 'Пробный период на $days ${_dayWord(days)} активирован'
          : 'Пробный период активирован';
    } catch (e) {
      error = _api.extractError(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Russian plural for a number of days: 1 день, 2 дня, 5 дней.
  static String _dayWord(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    if (mod10 == 1 && mod100 != 11) return 'день';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'дня';
    return 'дней';
  }

  Future<void> loadPlans() async {
    plansLoading = true;
    error = null;
    notifyListeners();
    try {
      plans = await _payments.fetchPlans();
      paymentProviders = await _payments.fetchProviders();
    } catch (e) {
      error = _api.extractError(e);
    } finally {
      plansLoading = false;
      notifyListeners();
    }
  }

  Future<void> purchasePlan(int planId) async {
    busy = true;
    error = null;
    info = null;
    notifyListeners();
    try {
      final result = await _payments.purchasePlan(planId);
      if (result.insufficientBalance != null) {
        final d = result.insufficientBalance!;
        final topUp = d.requiredTopUp.ceil().clamp(1, 1000000);
        info = 'Недостаточно средств. Открываем пополнение на $topUp ₽…';
        notifyListeners();
        await _startTopUp(amountRub: topUp, planId: d.planId);
        return;
      }
      if (result.user != null) user = result.user;
      info = result.message ?? 'Тариф оплачен';
      await refreshProfile(silent: true);
    } catch (e) {
      error = _api.extractError(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Opens a payment page for a chosen amount.
  ///
  /// Used by the "пополнить" sheet, where no plan is attached: the money simply
  /// lands on the balance and the user picks a tariff afterwards.
  Future<void> startTopUp(int amountRub, {int? planId}) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _startTopUp(amountRub: amountRub, planId: planId);
    } catch (e) {
      error = _api.extractError(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _startTopUp({required int amountRub, int? planId}) async {
    final provider = paymentProviders?.defaultProvider ?? 'yookassa';
    final session = await _payments.createTopUp(
      amountRub: amountRub,
      planId: planId,
      provider: provider,
    );
    pendingTopUpPaymentId = session.paymentId;
    pendingTopUpPlanId = session.planId ?? planId;
    await _storage.savePendingTopUp(
      paymentId: session.paymentId,
      planId: pendingTopUpPlanId,
    );
    final uri = Uri.parse(session.paymentUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Не удалось открыть страницу оплаты');
    }
    info =
        'Оплатите $amountRub ₽ в открывшемся окне — тариф включится сам, '
        'как только платёж пройдёт.';
    _armTopUpPolling();
  }

  /// Watches an open payment so the tariff appears without a second click.
  ///
  /// The website learns about a payment from the redirect back to it; a desktop
  /// window has no redirect to watch, so the client asks the panel itself —
  /// every few seconds while the payment is fresh, and on every resume of the
  /// window afterwards.
  void _armTopUpPolling() {
    _topUpPollTimer?.cancel();
    _topUpPollTicks = 0;
    _topUpPollTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (pendingTopUpPaymentId == null) {
        timer.cancel();
        return;
      }
      if (++_topUpPollTicks > _topUpPollLimit) {
        timer.cancel();
        return;
      }
      await confirmPendingTopUp(silent: true);
    });
  }

  /// Stops waiting for a payment the user walked away from.
  void cancelTopUpWait() {
    _topUpPollTimer?.cancel();
    _topUpPollTimer = null;
    pendingTopUpPaymentId = null;
    pendingTopUpPlanId = null;
    unawaited(_storage.clearPendingTopUp());
    info = 'Ожидание оплаты остановлено';
    notifyListeners();
  }

  Future<void> confirmPendingTopUp({bool silent = false}) async {
    final paymentId =
        pendingTopUpPaymentId ?? await _storage.readPendingTopUpPaymentId();
    if (paymentId == null || paymentId.isEmpty) {
      error = 'Нет ожидающего платежа';
      notifyListeners();
      return;
    }

    if (!silent) {
      busy = true;
      error = null;
      notifyListeners();
    }
    try {
      final result = await _payments.confirmTopUp(paymentId);
      if (!result.success) {
        // A silent poll that finds nothing yet is the normal case, not news.
        if (!silent) {
          info =
              'Платёж ещё не подтверждён. Подождите минуту и попробуйте снова.';
          notifyListeners();
        }
        return;
      }

      _topUpPollTimer?.cancel();
      _topUpPollTimer = null;
      if (result.user != null) user = result.user;
      final planId = result.planId ?? pendingTopUpPlanId;
      pendingTopUpPaymentId = null;
      pendingTopUpPlanId = null;
      await _storage.clearPendingTopUp();

      if (planId != null && result.autoPurchase != true) {
        await purchasePlan(planId);
        return;
      }

      info = planId == null
          ? 'Баланс пополнен'
          : 'Оплата прошла, тариф активирован';
      await refreshProfile(silent: true);
    } catch (e) {
      if (!silent) error = _api.extractError(e);
    } finally {
      if (!silent) {
        busy = false;
      }
      notifyListeners();
    }
  }

  Future<void> onAppResumed() async {
    if (_telegramSessionToken != null) {
      await _pollTelegramSession();
    }
    if (pendingTopUpPaymentId != null) {
      await confirmPendingTopUp(silent: true);
    }
  }

  /// Refreshes the devices bound to the subscription.
  Future<void> loadDevices({bool silent = false}) async {
    if (!silent) {
      devicesLoading = true;
      devicesError = null;
      notifyListeners();
    }
    try {
      devices = await _devices.fetchDevices();
      devicesError = null;
    } catch (e) {
      devicesError = _api.extractError(e);
    } finally {
      devicesLoading = false;
      notifyListeners();
    }
  }

  /// Releases one device so another machine can take the slot.
  Future<void> removeDevice(String hwid) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _devices.removeDevice(hwid);
      info = 'Устройство отключено';
      await loadDevices(silent: true);
      // This machine may be the one that was released, so the local view of the
      // subscription is refreshed as well.
      await refreshProfile(silent: true);
    } catch (e) {
      error = _api.extractError(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Releases every device, which is the way out of a device limit that has
  /// filled up with machines the user no longer has.
  Future<void> removeAllDevices() async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _devices.removeAllDevices();
      info = 'Все устройства отключены';
      await loadDevices(silent: true);
      await refreshProfile(silent: true);
    } catch (e) {
      error = _api.extractError(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void setShellTab(int index) {
    shellTab.value = index.clamp(0, 3);
  }

  Future<void> requestRuntimePermissions() async {
    try {
      await _notifications.initialize();
      await _vpn.requestSystemPermission();
    } catch (e) {
      // ignore: avoid_print
      print('Runtime permissions: $e');
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    final name = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      ThemeMode.dark => 'dark',
    };
    await _storage.saveThemeMode(name);
    await _storage.saveThemeChosen();
    notifyListeners();
  }

  /// Persists the "connect on launch" preference.
  Future<void> setAutoConnectOnLaunch(bool value) async {
    autoConnectOnLaunch = value;
    notifyListeners();
    await _storage.saveAutoConnect(value);
  }

  /// Toggles game routing.
  ///
  /// Games reach their providers directly for latency; blocked resources and
  /// Discord keep going through the proxy, so nothing stops working.
  Future<void> setGameMode(bool value) async {
    gameModeEnabled = value;
    notifyListeners();
    await _storage.saveGameMode(value);
    await _vpn.setRoutingMode(gameMode: value);
    LogService.instance.log('app', 'game mode: ${value ? 'on' : 'off'}');
  }

  /// Saves the domain list and applies it to the running tunnel at once.
  ///
  /// The list is stored as typed, and the parsed form is what reaches the
  /// profile — an unparsable entry simply disappears instead of taking the
  /// whole rule set down with it.
  Future<void> setBypassDomains(String raw) async {
    final trimmed = raw.length > maxBypassCharacters
        ? raw.substring(0, maxBypassCharacters)
        : raw;
    bypassDomains = trimmed;
    notifyListeners();
    await _storage.saveBypassDomains(trimmed);
    final parsed = parseBypassDomains(trimmed);
    await _vpn.setRoutingMode(bypassDomains: parsed);
    LogService.instance.log(
      'app',
      'tunnel domains: ${parsed.length} entr${parsed.length == 1 ? 'y' : 'ies'}',
    );
  }

  /// Records that the user has been sent to the system battery screen.
  ///
  /// Nothing on the phone can confirm the choice a vendor shell stores there,
  /// so the request is remembered once it has been made: the next step of the
  /// background flow is then allowed to open instead of the same dialog again.
  Future<void> markBackgroundBatteryAsked() async {
    if (backgroundBatteryAsked) return;
    backgroundBatteryAsked = true;
    notifyListeners();
    await _storage.saveBackgroundBatteryAsked(true);
  }

  /// Records that the user has been sent to the battery-usage screen.
  Future<void> markBackgroundBatteryUsageAsked() async {
    if (backgroundBatteryUsageAsked) return;
    backgroundBatteryUsageAsked = true;
    notifyListeners();
    await _storage.saveBackgroundBatteryUsageAsked(true);
  }

  /// Keeps Russian sites on the user's own connection — always on.
  ///
  /// The switch used to be a setting; it is now part of how the client works, so
  /// nothing in the interface calls this. It stays (and keeps persisting the
  /// flag) so that an older build sharing the same storage still reads a
  /// consistent value.
  Future<void> setRuDirect(bool value) async {
    ruDirectEnabled = value;
    notifyListeners();
    await _storage.saveRuDirect(value);
    await _vpn.setRoutingMode(ruDirect: value);
    LogService.instance.log('app', 'ru direct: ${value ? 'on' : 'off'}');
  }

  Future<void> setLoggingEnabled(bool value) async {
    loggingEnabled = value;
    LogService.instance.setEnabled(value);
    notifyListeners();
    await _storage.saveLogging(value);
  }

  Future<void> setTunnelMode(VpnTunnelMode mode) async {
    if (busy || tunnelMode == mode) return;
    if (mode == VpnTunnelMode.tun &&
        Platform.isWindows &&
        !await isProcessElevated()) {
      // Without an elevated token TUN cannot create its adapter. Offering the
      // restart keeps the switch honest: it never silently does nothing.
      adminRestartPrompt = true;
      notifyListeners();
      return;
    }
    tunnelMode = mode;
    notifyListeners();
    LogService.instance.log('app', 'tunnel mode: ${mode.name}');
    await _storage.saveTunnelMode(mode.name);
    if (_vpn.state == VpnConnectionState.connected) {
      await _reconnectWithCurrentMode();
    }
  }

  /// Turns the Windows system proxy on (`true`) or off (`false`).
  ///
  /// The screen presents the two modes as one switch: on is the system proxy
  /// (no administrator rights), off is global TUN.
  Future<void> setSystemProxyMode(bool enabled) =>
      setTunnelMode(enabled ? VpnTunnelMode.systemProxy : VpnTunnelMode.tun);

  /// The preset the connection-mode picker highlights.
  TunnelPreset get tunnelPreset {
    if (tunnelMode == VpnTunnelMode.systemProxy)
      return TunnelPreset.systemProxy;
    return ruDirectEnabled ? TunnelPreset.rules : TunnelPreset.fullTraffic;
  }

  /// Switches the connection mode as one decision.
  ///
  /// [TunnelPreset.rules] and [TunnelPreset.fullTraffic] use the same platform
  /// mode and differ only in whether Russian services stay on the user's own
  /// connection, so moving between them reloads the rules instead of restarting
  /// the tunnel. The system proxy is a different platform mode and does restart
  /// it.
  Future<void> setTunnelPreset(TunnelPreset preset) async {
    if (busy || preset == tunnelPreset) return;
    final mode = preset == TunnelPreset.systemProxy
        ? VpnTunnelMode.systemProxy
        : VpnTunnelMode.tun;
    final ruDirect = preset != TunnelPreset.fullTraffic;
    if (mode == VpnTunnelMode.tun &&
        mode != tunnelMode &&
        Platform.isWindows &&
        !await isProcessElevated()) {
      // A tunnel needs an elevated token; the home screen offers the restart
      // instead of letting the picker do nothing.
      adminRestartPrompt = true;
      notifyListeners();
      return;
    }
    final modeChanged = mode != tunnelMode;
    tunnelMode = mode;
    ruDirectEnabled = ruDirect;
    notifyListeners();
    LogService.instance.log('app', 'connection preset: ${preset.name}');
    await _storage.saveTunnelMode(mode.name);
    await _storage.saveRuDirect(ruDirect);
    await _vpn.setRoutingMode(ruDirect: ruDirect);
    if (_vpn.state == VpnConnectionState.connected && modeChanged) {
      await _reconnectWithCurrentMode();
    }
  }

  /// Whether starting the tunnel in the current mode needs an elevated process.
  bool get tunnelNeedsElevation =>
      tunnelMode == VpnTunnelMode.tun && Platform.isWindows;

  /// Whether the current mode needs the Wintun kernel driver.
  ///
  /// Only the elevated Windows mode does: the system proxy never touches the
  /// adapter, and the mobile engines own theirs.
  bool get tunnelNeedsTunDriver =>
      tunnelMode == VpnTunnelMode.tun && Platform.isWindows;

  /// Re-checks the Windows gates in the order they have to be passed.
  ///
  /// Both answers come from the system every time: the cached [elevated] and
  /// [tunDriver] are for the settings screen, and a cached "yes" is exactly what
  /// made the client skip a prompt the user had just revoked.
  Future<ConnectRequirement?> _firstMissingRequirement() async {
    if (!tunnelNeedsElevation) return null;
    if (!await isProcessElevated()) return ConnectRequirement.admin;
    if (tunnelNeedsTunDriver) {
      if (tunDriver == TunDriverStatus.unknown) {
        tunDriver = await WindowsTunDriver().check();
      }
      if (tunDriver == TunDriverStatus.driverMissing) {
        return ConnectRequirement.tunDriver;
      }
    }
    return null;
  }

  void _promptRequirement(ConnectRequirement requirement) {
    adminRestartPrompt = requirement == ConnectRequirement.admin;
    tunDriverPrompt = requirement == ConnectRequirement.tunDriver;
  }

  /// Opens the window for the requirement the connect attempt stopped at.
  ///
  /// Called by the line under the connect button, so a dismissed window can be
  /// brought back without flipping the switch again.
  void resolveConnectRequirement() {
    final requirement = connectRequirement;
    if (requirement == null) return;
    _promptRequirement(requirement);
    notifyListeners();
  }

  /// Restarts the application elevated, as the administrator dialog offers.
  Future<void> restartAsAdministrator() async {
    adminRestartPrompt = false;
    // Turning on the rights takes a while: the window has to finish its
    // processes, the UAC window is shown, and the replacement has to claim the
    // port. Without an explicit state the screen just sat there looking stuck.
    restarting = true;
    notifyListeners();
    // Accepting this prompt is the same decision as the "always start as
    // administrator" switch, so it is recorded as one: without that, the
    // elevated copy came back with the switch off and the helper task — which
    // is created by an elevated launch — was never registered either.
    final previous = runAsAdmin;
    runAsAdmin = true;
    await _storage.saveRunAsAdmin(true);
    // If this restart answers a connect attempt, the replacement has to pick the
    // attempt up: the rights were the first gate, and the driver (or the tunnel
    // itself) is next. Without this the user would land on the home screen and
    // have to press the switch again to see the next window.
    if (connectRequirement == ConnectRequirement.admin) {
      await _storage.savePendingConnect(true);
    }
    notifyListeners();
    LogService.instance.log('app', 'restarting as administrator');
    // The elevated copy has to claim the single-instance port itself, so this
    // instance releases it first; otherwise the new window would see the port
    // taken and exit as a duplicate.
    await WindowsSingleInstanceGate.release();
    // Same hand-over as the launcher's, so the same protection has to come off:
    // the replacement is a child of this process and the runner's job would end
    // it together with this window.
    await WindowsShell.setChildrenMayOutliveUs(true);
    var replaced = false;
    if (await relaunchElevated(arguments: const [kElevatedArgument])) {
      // An accepted request is not a window: Windows can report a successful
      // elevation and start nothing at all. Waiting for the replacement to
      // claim the port is what keeps this window alive when that happens,
      // instead of closing in favour of a process that never existed.
      replaced = await WindowsSingleInstanceGate.isHeldByAnotherInstance(
        timeout: const Duration(seconds: 15),
      );
    }
    if (replaced) exit(0);
    // Nothing took over, so this instance is still the application: put the
    // protection back, take the port back, and tell the user what to do instead.
    await WindowsShell.setChildrenMayOutliveUs(false);
    await WindowsSingleInstanceGate.reclaim();
    // The preference promised a mode this process does not have; leaving it on
    // would make every later launch believe it is already elevated.
    runAsAdmin = previous;
    await _storage.saveRunAsAdmin(previous);
    restarting = false;
    error =
        'Не удалось перезапустить с правами администратора. '
        'Запустите приложение вручную через «Запуск от имени администратора».';
    notifyListeners();
  }

  /// Dismisses the administrator window without granting it.
  ///
  /// Nothing is reported as an error: the request stays as the line under the
  /// connect button, which is where the user can reopen the window.
  void declineAdminRestart() {
    adminRestartPrompt = false;
    connectRequirement ??= ConnectRequirement.admin;
    // A refused permission must not leave a "connect" order behind: the next
    // launch would connect on its own, which is exactly the surprise this
    // client avoids.
    unawaited(_storage.savePendingConnect(false));
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // TUN driver, core integrity, autostart and tray
  // ---------------------------------------------------------------------------

  /// Re-reads whether the machine has the TUN driver.
  ///
  /// Cheap enough for bootstrap and for the moment before a connect; the answer
  /// is cached in [tunDriver] so the UI never has to wait for it twice.
  Future<void> refreshTunDriver() async {
    if (!Platform.isWindows) return;
    final status = await WindowsTunDriver().check();
    if (status == tunDriver) return;
    tunDriver = status;
    LogService.instance.log('app', 'tun driver: ${status.name}');
    notifyListeners();
  }

  /// Installs the TUN driver, then continues the connect that asked for it.
  ///
  /// Wintun installs itself the first time an adapter is created, so this runs
  /// the bundled core once against a throwaway profile — no download, no second
  /// installer, and nothing the user has to find.
  Future<void> installTunDriver() async {
    if (tunDriverInstalling) return;
    final corePath = _vpn.coreExecutablePath;
    if (corePath == null) {
      error = 'Не удалось определить путь к ядру приложения';
      notifyListeners();
      return;
    }
    tunDriverInstalling = true;
    tunDriverPrompt = false;
    notifyListeners();
    try {
      final driver = WindowsTunDriver();
      final installed = await driver.install(corePath: corePath);
      tunDriver = await driver.check();
      if (!installed || tunDriver != TunDriverStatus.ready) {
        error = driver.lastError ?? 'Не удалось установить драйвер TUN';
      } else {
        info = 'Драйвер TUN установлен';
      }
    } finally {
      tunDriverInstalling = false;
      notifyListeners();
    }
  }

  /// The home screen's "Установить" button in the driver dialog.
  Future<void> installTunDriverAndConnect() async {
    tunDriverPrompt = false;
    notifyListeners();
    await installTunDriver();
    if (tunDriver == TunDriverStatus.ready) await toggleVpn();
  }

  /// Dismisses the driver window without installing it.
  void declineTunDriverInstall() {
    tunDriverPrompt = false;
    connectRequirement ??= ConnectRequirement.tunDriver;
    unawaited(_storage.savePendingConnect(false));
    notifyListeners();
  }

  /// Verifies the bundled core against the digests recorded at build time.
  ///
  /// The core is launched with an administrator token, so this is the one check
  /// that can turn a silently swapped binary into a visible error. It is a
  /// background task: a failure is reported, never blocking the UI.
  Future<void> verifyCoreIntegrity() async {
    if (!Platform.isWindows) return;
    final corePath = _vpn.coreExecutablePath;
    if (corePath == null) return;
    final report = await const BinaryIntegrity().verifyDirectory(
      File(corePath).parent,
    );
    integrity = report;
    LogService.instance.log('app', 'integrity: ${report.summary}');
    notifyListeners();
  }

  /// Re-reads whether the application is registered to start with Windows.
  Future<void> refreshAutostart() async {
    if (!Platform.isWindows) return;
    final autostart = WindowsAutostart();
    final enabled = await autostart.isEnabled();
    if (enabled) {
      // The executable is renamed between releases (scaleguard_mobile.exe →
      // ScaleGuard.exe) and the folder can move, while the Run entry keeps the
      // old path. Left alone it would silently start nothing, so the entry is
      // re-pointed at this copy whenever the stored command names another file.
      final command = await autostart.registeredCommand();
      final executable = Platform.resolvedExecutable;
      if (command != null &&
          !command.toLowerCase().contains(executable.toLowerCase())) {
        await autostart.enable(executablePath: executable);
      }
    }
    if (enabled == autostartEnabled) return;
    autostartEnabled = enabled;
    notifyListeners();
  }

  /// Adds or removes the autostart entry.
  Future<void> setAutostart(bool value) async {
    final autostart = WindowsAutostart();
    final ok = value
        ? await autostart.enable(executablePath: Platform.resolvedExecutable)
        : await autostart.disable();
    if (!ok) {
      error = autostart.lastError ?? 'Не удалось изменить автозапуск';
      notifyListeners();
      return;
    }
    autostartEnabled = value;
    LogService.instance.log('app', 'autostart: ${value ? 'on' : 'off'}');
    notifyListeners();
  }

  /// Switches between "close hides to tray" and "close quits".
  Future<void> setCloseToTray(bool value) async {
    closeToTray = value;
    notifyListeners();
    await _storage.saveCloseToTray(value);
    await WindowsShell.setCloseToTray(value);
  }

  /// Turns the "always start as administrator" preference on or off.
  Future<void> setRunAsAdmin(bool value) async {
    runAsAdmin = value;
    notifyListeners();
    await _storage.saveRunAsAdmin(value);
    LogService.instance.log('app', 'run as admin: ${value ? 'on' : 'off'}');
    // Asked for administrator launches: spend the prompt the user just made
    // anyway on the helper, so it is the last one they see.
    if (value) unawaited(_ensureHelper());
  }

  /// Re-reads the elevation state.
  ///
  /// Called once during bootstrap (and after a connect attempt) rather than on
  /// every rebuild: the check spawns a PowerShell process, which is far too
  /// expensive for a `build` method.
  Future<void> refreshElevation() async {
    final value = await isProcessElevated();
    if (value != elevated) {
      elevated = value;
      notifyListeners();
    }
    // Installing the helper takes the rights the helper exists to provide, so
    // an already-elevated launch is the only moment where it is free.
    unawaited(_ensureHelper());
  }

  /// Whether the client can start elevated without a UAC prompt.
  bool helperInstalled = false;

  /// Set when the helper task could not be created or removed.
  String? helperError;

  /// Re-reads whether the helper task exists.
  Future<void> refreshHelper() async {
    if (!Platform.isWindows) return;
    final installed = await WindowsHelper().isInstalled();
    if (installed == helperInstalled) return;
    helperInstalled = installed;
    notifyListeners();
  }

  /// Creates the helper task the first time the client holds the rights for it.
  ///
  /// The prompt has to happen at least once — nothing can be installed without
  /// administrator rights — and this spends it at the moment the client is
  /// already elevated for another reason. Only for users who asked for
  /// administrator launches: quietly adding a privileged launcher for everybody
  /// else would not be the client's decision to make.
  Future<void> _ensureHelper() async {
    if (!Platform.isWindows || !runAsAdmin || !elevated) return;
    final helper = WindowsHelper();
    if (helperInstalled) return;
    if (await helper.isInstalled()) {
      helperInstalled = true;
      notifyListeners();
      return;
    }
    final installed = await helper.install();
    helperInstalled = installed;
    helperError = installed ? null : helper.lastError;
    LogService.instance.log(
      'app',
      installed
          ? 'helper installed: launches no longer need a UAC prompt'
          : 'helper not installed: $helperError',
    );
    notifyListeners();
  }

  /// Creates or removes the helper task from the settings screen.
  Future<void> setHelper(bool value) async {
    helperError = null;
    if (!elevated) {
      // Both directions need administrator rights, so this is one of the few
      // things that genuinely cannot be done from a plain session.
      helperError =
          'Нужны права администратора: перезапустите приложение '
          'от имени администратора';
      notifyListeners();
      return;
    }
    final helper = WindowsHelper();
    final ok = value ? await helper.install() : await helper.remove();
    if (!ok) {
      helperError = helper.lastError ?? 'Не удалось изменить службу-помощник';
      notifyListeners();
      return;
    }
    helperInstalled = value;
    notifyListeners();
  }

  Future<void> _reconnectWithCurrentMode() async {
    busy = true;
    notifyListeners();
    try {
      LogService.instance.log(
        'app',
        'reconnecting to apply mode ${tunnelMode.name}',
      );
      await _vpn.disconnect();
      final permissionGranted = await _vpn.requestSystemPermission();
      if (!permissionGranted) {
        throw StateError(_tunnelPermissionError());
      }
      await _vpn.connect(mode: tunnelMode);
      LogService.instance.log('app', 'reconnected (mode: ${tunnelMode.name})');
    } catch (e) {
      error = _api.extractError(e);
      LogService.instance.log('app', 'mode switch failed: $error');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  String _tunnelPermissionError() {
    if (tunnelMode == VpnTunnelMode.tun && Platform.isWindows) {
      return 'Для этого режима нужны права администратора. Запустите '
          'приложение от имени администратора или включите системный прокси.';
    }
    return 'Нет разрешения на создание туннеля';
  }

  /// Switches to another location.
  ///
  /// The switch is performed inside the running core (a selector change over the
  /// controller), so the tunnel and the system proxy stay up: established
  /// connections finish and new ones take the new route. Tearing the core down
  /// and bringing it back — which is what the previous implementation did —
  /// dropped every connection, which is unacceptable mid-game or mid-call.
  Future<void> selectServer(int index) async {
    await _vpn.selectServer(index);
    autoModeEnabled = _vpn.autoSelectEnabled;
    // The exit may be in another country now, so the address the card shows has
    // to be re-read rather than kept from the previous node.
    if (_vpn.state == VpnConnectionState.connected) {
      unawaited(refreshExternalIp());
    }
    notifyListeners();
  }

  /// Turns silent automatic selection on or off.
  ///
  /// Enabled: the core keeps the fastest reachable location selected and may
  /// change it on its own; the user's list selection becomes a hint only.
  /// Disabled: the tunnel stays pinned to whatever the user picked.
  Future<void> setAutoMode(bool enabled) async {
    await _vpn.setAutoSelect(enabled);
    autoModeEnabled = enabled;
    notifyListeners();
  }

  Future<void> pickFastestServer() async {
    if (autoSelectingServer) return;
    autoSelectingServer = true;
    notifyListeners();
    try {
      await _vpn.selectFastestServer();
      autoModeEnabled = _vpn.autoSelectEnabled;
    } catch (e) {
      error = _api.extractError(e);
    } finally {
      autoSelectingServer = false;
      notifyListeners();
    }
  }

  Future<void> pingAllAndMaybeSelect({
    bool applyAuto = false,
    void Function()? notify,
  }) async {
    if (autoSelectingServer) return;
    autoSelectingServer = true;
    notifyListeners();
    try {
      final wasConnected = _vpn.state == VpnConnectionState.connected;
      int prev = _vpn.selectedIndex;
      int selectedAfterPing = prev;
      await _vpn.pingAllServersAndAutoSelect(
        onTick: () {
          notifyListeners();
          notify?.call();
        },
      );
      selectedAfterPing = _vpn.selectedIndex;
      notifyListeners();
      notify?.call();
      // Adopting a newly measured faster location no longer restarts the tunnel:
      // the core switches route internally, so an in-flight game or call is not
      // interrupted.
      if (applyAuto && wasConnected && selectedAfterPing != prev) {
        await _vpn.applyBestServerSelection();
      }
    } catch (e) {
      error = _api.extractError(e);
    } finally {
      autoSelectingServer = false;
      notifyListeners();
      notify?.call();
    }
  }

  // ---------------------------------------------------------------------------
  // Kill switch
  // ---------------------------------------------------------------------------

  /// Whether traffic is cut off whenever the tunnel is not up.
  ///
  /// A setting rather than a mode, and off until the user turns it on: the
  /// mechanism changes a machine-wide firewall setting, and a client that did
  /// that on its own on first launch would be a hostile one. See
  /// `lib/core/windows_kill_switch.dart` for what it does and how it is undone.
  bool killSwitchEnabled = false;

  /// Whether the firewall is blocking traffic right now.
  bool killSwitchActive = false;

  /// Why the last attempt failed, for the settings screen.
  String? killSwitchError;

  WindowsKillSwitch? _killSwitchInstance;

  WindowsKillSwitch get _killSwitch =>
      _killSwitchInstance ??= WindowsKillSwitch();

  /// Arms the switch, when the user asked for it.
  ///
  /// Called while the connection is being built rather than once it is up: the
  /// gap between "connect" and "connected" is exactly where traffic would
  /// otherwise leave the machine unguarded, which is the leak the feature exists
  /// to close.
  Future<void> _engageKillSwitch() async {
    if (!killSwitchEnabled || !Platform.isWindows) return;
    final corePath = _vpn.coreExecutablePath;
    if (corePath == null || corePath.isEmpty) return;
    final engaged = await _killSwitch.enable(
      corePath: corePath,
      clientPath: Platform.resolvedExecutable,
    );
    killSwitchActive = engaged;
    killSwitchError = engaged ? null : _killSwitch.lastError;
    if (!engaged && killSwitchError != null) {
      LogService.instance.log(
        'app',
        'kill switch could not be armed: $killSwitchError',
      );
    }
    notifyListeners();
  }

  /// Allows what travels through the tunnel adapter, once it exists.
  ///
  /// The adapter is only created while the tunnel comes up, so this cannot be
  /// part of the initial arming. It is, however, the rule that makes TUN mode
  /// work at all under the switch: applications hand their packets to the
  /// adapter, and without a rule naming it the firewall would see those packets
  /// as ordinary outbound traffic and drop them.
  Future<void> _allowKillSwitchTunnel() async {
    if (!killSwitchActive || tunnelMode != VpnTunnelMode.tun) return;
    if (await _killSwitch.allowTunnelInterface()) return;
    killSwitchError = _killSwitch.lastError;
    // Worth interrupting the user for: when this rule is missing, the tunnel is
    // up and everything that goes through it is dropped.
    noteNotice(
      'Kill switch не смог разрешить трафик туннеля. Снимите блокировку '
      'в настройках или отключитесь',
    );
    notifyListeners();
  }

  /// Restores the machine's firewall configuration.
  ///
  /// [force] skips the "is there anything to do" shortcut, for the manual release
  /// in the settings: the flags describe what the client believes, and the whole
  /// point of that button is to act when the two have come apart.
  Future<void> _releaseKillSwitch(String reason, {bool force = false}) async {
    if (!force && !killSwitchActive && !_killSwitch.isActive) return;
    LogService.instance.log('app', 'kill switch released ($reason)');
    // The flag follows what is on disk, not the intention: the backup survives
    // exactly when the release could not be verified, which is the same
    // condition that has to keep showing up as "active".
    await _killSwitch.disable();
    killSwitchActive = _killSwitch.isActive;
    killSwitchError = _killSwitch.lastError;
    notifyListeners();
  }

  /// Releases a switch left behind by a client that was killed while engaged.
  ///
  /// Without this a machine whose client was ended in the task manager would
  /// have no internet at all, and the setting that caused it is not one a user
  /// can be expected to find.
  Future<void> _releaseStaleKillSwitch() async {
    if (!Platform.isWindows) return;
    try {
      if (await _killSwitch.repairFromBackup()) {
        killSwitchActive = false;
        killSwitchError = null;
        notifyListeners();
      }
    } catch (_) {
      // Best effort: a machine that could not be repaired here still has the
      // failsafe task and the manual release in the settings.
    }
  }

  /// Turns the setting on or off.
  Future<void> setKillSwitch(bool value) async {
    killSwitchEnabled = value;
    await _storage.saveKillSwitch(value);
    notifyListeners();
    if (!value) {
      await _releaseKillSwitch('turned off in the settings');
      return;
    }
    // Turning it on while a tunnel is up has to take effect at once, otherwise
    // the setting looks inert until the next reconnect.
    if (_vpn.state == VpnConnectionState.connected ||
        _vpn.state == VpnConnectionState.connecting) {
      await _engageKillSwitch();
    }
  }

  /// Releases the switch by hand.
  ///
  /// The escape hatch. Whatever happened to the tunnel or to the client, there
  /// has to be one obvious way to get the internet back that does not involve
  /// hunting through the Windows firewall settings.
  Future<void> releaseKillSwitchNow() async {
    killSwitchEnabled = false;
    await _storage.saveKillSwitch(false);
    // Forced: this button exists precisely for the case where the client's idea
    // of the firewall and the firewall's own state have come apart.
    await _releaseKillSwitch('manual release', force: true);
  }

  Future<void> toggleVpn() async {
    error = null;
    if (_vpn.state == VpnConnectionState.connecting) {
      return;
    }
    if (_vpn.state == VpnConnectionState.connected) {
      await _vpn.disconnect();
      LogService.instance.log('app', 'disconnect: user request');
      connectRequirement = null;
      // The user stopped it on purpose, so the next launch may honour the
      // "connect on launch" preference again.
      await _storage.saveSessionWasUp(false);
      vpnDownloadBps = 0;
      vpnUploadBps = 0;
      vpnPingMs = 0;
      externalIp = null;
      await _releaseKillSwitch('disconnected by the user');
      notifyListeners();
      return;
    }
    if (tunnel == null || !tunnel!.hasActiveSubscription) {
      error = 'Нет активной подписки. Оформите тариф или активируйте trial.';
      notifyListeners();
      return;
    }
    // TUN takes over the routing table, which Windows only allows for an
    // elevated process, and it needs the Wintun driver. The two are asked for
    // one after another: a window that granted rights is checked again before
    // the driver window opens, and if the user closes a window the request
    // stays as a line under the connect button instead of vanishing.
    final missing = await _firstMissingRequirement();
    if (missing != null) {
      connectRequirement = missing;
      _promptRequirement(missing);
      notifyListeners();
      return;
    }
    connectRequirement = null;
    // The core runs with an administrator token in TUN mode, so a binary that
    // does not match the digests recorded at build time is not started with
    // those rights. The system-proxy path stays available.
    if (tunnelNeedsElevation && integrity.isMismatch) {
      error =
          '${integrity.summary}. Подключение в режиме TUN остановлено — '
          'переустановите приложение.';
      notifyListeners();
      return;
    }
    busy = true;
    notifyListeners();
    try {
      if (_vpn.profiles.isEmpty && tunnel!.subscriptionUrl.isNotEmpty) {
        await _loadSubscriptionProfile(tunnel!.subscriptionUrl);
      }
      if (_vpn.profiles.isEmpty) {
        throw StateError('Не удалось загрузить серверы подписки');
      }
      final permissionGranted = await _vpn.requestSystemPermission();
      if (!permissionGranted) {
        throw StateError(_tunnelPermissionError());
      }
      LogService.instance.log('app', 'connect: mode ${tunnelMode.name}');
      await _engageKillSwitch();
      await _vpn.connect(mode: tunnelMode);
      if (_vpn.state == VpnConnectionState.error) {
        error = await _killSwitchNotice(
          _vpn.lastError ?? 'Не удалось подключиться',
        );
      } else if (_vpn.state == VpnConnectionState.connected) {
        LogService.instance.log('app', 'connected (mode: ${tunnelMode.name})');
      }
    } catch (e) {
      error = await _killSwitchNotice(_api.extractError(e));
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Releases the switch after a connect attempt that produced no tunnel, and
  /// says so in the message.
  ///
  /// A tunnel that never came up protects nothing, and a machine left blocked
  /// would be indistinguishable from a broken application: the user would be
  /// looking at an error with no internet and no way to tell the two apart. The
  /// switch stays engaged for every *other* kind of failure — which is the case
  /// the feature exists for, a tunnel that drops under a running session.
  Future<String> _killSwitchNotice(String message) async {
    if (!killSwitchActive && !_killSwitch.isActive) return message;
    await _releaseKillSwitch('the connection did not come up');
    return '$message Защита снята, чтобы не оставить вас без интернета.';
  }

  /// Reads the public address through the tunnel.
  ///
  /// The lookup races the freshly created tunnel — the first request often goes
  /// out before the core has finished wiring its resolver — and a single miss
  /// used to leave the card on "—" until the next reconnect. A handful of
  /// attempts plus a slow periodic refresh makes the value reliable instead.
  Future<void> refreshExternalIp() async {
    if (externalIpLoading) return;
    externalIpLoading = true;
    notifyListeners();
    try {
      for (var attempt = 0; attempt < _externalIpAttempts; attempt++) {
        try {
          final ip = await _vpn.fetchExternalIp();
          if (ip != null && ip.isNotEmpty) {
            externalIp = ip;
            return;
          }
        } catch (error) {
          LogService.instance.log('app', 'external ip lookup failed: $error');
        }
        await Future<void>.delayed(_externalIpRetryDelay);
      }
    } finally {
      externalIpLoading = false;
      notifyListeners();
    }
  }

  /// Re-reads the public address every couple of minutes while the tunnel is up.
  ///
  /// A subscription can move the exit between requests, and this address is the
  /// user's only proof of where the traffic actually leaves, so it is kept
  /// current instead of being read once per connect.
  void _startExternalIpRefresh() {
    _externalIpTimer?.cancel();
    _externalIpTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (_vpn.state != VpnConnectionState.connected) return;
      unawaited(refreshExternalIp());
    });
  }

  /// Everything that has to happen when a tunnel is taken down for good.
  ///
  /// One helper rather than the same six lines in four places: disconnecting
  /// from the tray, logging out, quitting and restarting all have to stop the
  /// core, restore the system proxy, release the kill switch, drop the timers
  /// and blank the counters. Missing a step in any of them is how a machine ends
  /// up pointing at a port that no longer listens.
  Future<void> _teardownTunnel(String reason) async {
    LogService.instance.log('app', 'teardown: $reason');
    _externalIpTimer?.cancel();
    _externalIpTimer = null;
    _locationNoticeTimer?.cancel();
    _locationNoticeTimer = null;
    locationNotice = null;
    // `disconnect()` stops the core and waits for its process to end, and unwinds
    // the system proxy before the core disappears.
    await _vpn.disconnect();
    // The firewall is the one piece the VPN service does not own, so it is
    // released here: a client that is going away must never leave the machine
    // blocked.
    await _releaseKillSwitch(reason);
    vpnDownloadBps = 0;
    vpnUploadBps = 0;
    vpnPingMs = 0;
    externalIp = null;
    externalIpLoading = false;
    notifyListeners();
  }

  /// Connects or disconnects from the notification-area menu.
  ///
  /// The window is normally hidden while this runs, so anything that needs the
  /// user — the administrator prompt, the missing TUN driver, a failure — brings
  /// the window back instead of leaving the menu entry looking broken.
  Future<void> toggleFromTray() async {
    LogService.instance.log('app', 'tray: toggle tunnel');
    if (_vpn.state == VpnConnectionState.connecting) return;
    await toggleVpn();
    if (adminRestartPrompt ||
        tunDriverPrompt ||
        error != null ||
        tunDriverInstalling) {
      await WindowsShell.showWindow();
    }
  }

  /// Restarts the client, as offered by the tray menu.
  ///
  /// The tunnel is taken down before anything else: a restart that left the core
  /// running would leave two of them fighting over the adapter and the ports.
  Future<void> restartApplication() async {
    LogService.instance.log('app', 'tray: restart');
    restarting = true;
    notifyListeners();
    await _teardownTunnel('restart');
    if (Platform.isWindows) {
      final isElevated = await isProcessElevated();
      // A restart is a promise about the *next* process, and Windows hands a
      // child its parent's token: restarting from an elevated window produced an
      // elevated window no matter what the switch said. That is why turning
      // "run as administrator" off, restarting and still getting TUN without a
      // prompt looked like a broken permission check — the client really was
      // still elevated. Both directions are now honoured.
      if (runAsAdmin && !isElevated) {
        await restartAsAdministrator();
        return;
      }
      if (!runAsAdmin && isElevated) {
        await WindowsSingleInstanceGate.release();
        final started = await relaunchAsStandardUser();
        if (started) {
          final replaced =
              await WindowsSingleInstanceGate.isHeldByAnotherInstance(
                timeout: const Duration(seconds: 10),
              );
          if (replaced) exit(0);
        }
        await WindowsSingleInstanceGate.reclaim();
        restarting = false;
        error =
            'Не удалось перезапустить без прав администратора. '
            'Закройте приложение и запустите его обычным способом.';
        notifyListeners();
        return;
      }
    }
    // The replacement has to be able to claim the handshake port, otherwise it
    // finds it taken, treats itself as a duplicate launch and exits without ever
    // showing a window.
    await WindowsSingleInstanceGate.release();
    await WindowsShell.restartApplication();
  }

  /// Ends the client, taking the tunnel with it.
  ///
  /// This is the tray's "Закрыть" and the whole point of it is that nothing is
  /// left running: the core is stopped, the system proxy is restored and the
  /// kill switch is released before the process goes away.
  Future<void> quitApplication() async {
    LogService.instance.log('app', 'tray: quit');
    await _teardownTunnel('quit');
    await WindowsSingleInstanceGate.release();
    await WindowsShell.quitApplication();
  }

  Future<void> logout() async {
    _stopTelegramPolling();
    _stopQrSession();
    _disarmSubscriptionCheck();
    telegramPending = false;
    yandexPending = false;
    qrSession = null;
    qrSolved = false;
    qrStatus = null;
    qrRotatesAt = null;
    // Signing out must not leave a tunnel behind: the session the client was
    // built on is gone, and the subscription that authorised the nodes with it.
    await _teardownTunnel('logout');
    await _storage.saveSessionWasUp(false);
    await _storage.clearToken();
    await _storage.clearProfileSnapshot();
    _api.setToken(null);
    restoredCachedSession = false;
    user = null;
    tunnel = null;
    trial = null;
    shellTab.value = 0;
    error = null;
    info = null;
    notifyListeners();
  }

  void setError(String message) {
    error = message;
    info = null;
    notifyListeners();
  }

  void clearMessages() {
    error = null;
    info = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopTelegramPolling();
    _stopQrSession();
    _disarmSubscriptionCheck();
    _externalIpTimer?.cancel();
    _locationNoticeTimer?.cancel();
    _cooldownTimer?.cancel();
    _messageTimer?.cancel();
    shellTab.dispose();
    super.dispose();
  }
}
