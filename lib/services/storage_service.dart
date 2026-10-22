import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StorageService {
  StorageService() : _storage = const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _tokenKey = 'auth_token';
  static const _pendingTopUpKey = 'pending_topup_payment';
  static const _pendingTopUpPlanKey = 'pending_topup_plan';
  static const _themeKey = 'theme_mode';
  static const _themeChosenKey = 'theme_chosen';
  static const _hwidKey = 'device_hwid';
  static const _autoConnectKey = 'auto_connect';
  static const _gameModeKey = 'game_mode';
  static const _systemProxyKey = 'system_proxy';
  static const _loggingKey = 'logging';
  static const _tunnelModeKey = 'tunnel_mode';
  static const _runAsAdminKey = 'run_as_admin';
  static const _adminPromptKey = 'admin_prompt_shown';
  static const _closeToTrayKey = 'close_to_tray';
  static const _killSwitchKey = 'kill_switch';
  static const _bypassDomainsKey = 'bypass_domains';
  static const _ruDirectKey = 'ru_direct';
  static const _sessionUpKey = 'session_was_up';
  static const _pendingConnectKey = 'pending_connect';
  static const _bgBatteryKey = 'bg_battery_asked';
  static const _bgBatteryUsageKey = 'bg_battery_usage_asked';

  /// Whether the battery screen was already opened for the user.
  ///
  /// Vendor shells do not report their own battery switch through the public
  /// API: MIUI can show "no restrictions" while `isIgnoringBatteryOptimizations`
  /// keeps answering "restricted". Once the user has been sent to that screen
  /// and said yes, asking again forever is wrong — the request is recorded here
  /// and the client moves on to the next step.
  Future<void> saveBackgroundBatteryAsked(bool value) =>
      _storage.write(key: _bgBatteryKey, value: value ? '1' : '0');

  Future<bool> readBackgroundBatteryAsked() async =>
      await _storage.read(key: _bgBatteryKey) == '1';

  /// Whether the battery-usage screen was already opened for the user.
  ///
  /// The restriction level chosen there is not exposed by the system at all, so
  /// it is a screen, not a permission: opened once, then remembered.
  Future<void> saveBackgroundBatteryUsageAsked(bool value) =>
      _storage.write(key: _bgBatteryUsageKey, value: value ? '1' : '0');

  Future<bool> readBackgroundBatteryUsageAsked() async =>
      await _storage.read(key: _bgBatteryUsageKey) == '1';

  /// Whether the previous session ended with the tunnel up, which is what a
  /// restart restores.
  Future<void> saveAutoConnect(bool value) =>
      _storage.write(key: _autoConnectKey, value: value ? '1' : '0');

  /// Reads the "connect on launch" preference.
  ///
  /// Unset means off. The switch flipped itself on for every fresh install
  /// because "unset" used to be read as "on", which is exactly the behaviour a
  /// user reports as "it connected by itself after I reopened it".
  Future<bool> readAutoConnect() async =>
      await _storage.read(key: _autoConnectKey) == '1';

  /// Whether the user asked to connect and the attempt stopped at a permission.
  ///
  /// The administrator prompt ends in a restart, and a restarted client that
  /// forgot why it was restarted would drop the user back on the home screen
  /// with nothing happening. The flag is the memory of that request.
  Future<void> savePendingConnect(bool value) =>
      _storage.write(key: _pendingConnectKey, value: value ? '1' : '0');

  Future<bool> readPendingConnect() async =>
      await _storage.read(key: _pendingConnectKey) == '1';

  /// Whether the tunnel was up the last time the application stopped.
  ///
  /// Written on every successful connect and cleared only when the user turns
  /// the switch off themselves (or signs out). That makes a launch able to tell
  /// "they left it running and the process ended" from "they stopped it on
  /// purpose", which is exactly the case where starting again on its own would
  /// be surprising: closing the window or killing the process must not re-arm
  /// the switch behind their back.
  Future<void> saveSessionWasUp(bool value) =>
      _storage.write(key: _sessionUpKey, value: value ? '1' : '0');

  Future<bool> readSessionWasUp() async =>
      await _storage.read(key: _sessionUpKey) == '1';

  Future<void> saveGameMode(bool value) =>
      _storage.write(key: _gameModeKey, value: value ? '1' : '0');

  Future<bool> readGameMode() async =>
      await _storage.read(key: _gameModeKey) == '1';

  Future<void> saveSystemProxy(bool value) =>
      _storage.write(key: _systemProxyKey, value: value ? '1' : '0');

  Future<bool> readSystemProxy() async =>
      await _storage.read(key: _systemProxyKey) == '1';

  Future<void> saveLogging(bool value) =>
      _storage.write(key: _loggingKey, value: value ? '1' : '0');

  Future<bool> readLogging() async =>
      await _storage.read(key: _loggingKey) != '0';

  Future<void> saveTunnelMode(String value) =>
      _storage.write(key: _tunnelModeKey, value: value);

  Future<String?> readTunnelMode() => _storage.read(key: _tunnelModeKey);

  Future<void> saveRunAsAdmin(bool value) =>
      _storage.write(key: _runAsAdminKey, value: value ? '1' : '0');

  Future<bool> readRunAsAdmin() async =>
      await _storage.read(key: _runAsAdminKey) == '1';

  /// Whether closing the window should hide the application to the tray rather
  /// than quit it. Unset means on — a VPN client is expected to keep running.
  Future<void> saveCloseToTray(bool value) =>
      _storage.write(key: _closeToTrayKey, value: value ? '1' : '0');

  Future<bool> readCloseToTray() async =>
      await _storage.read(key: _closeToTrayKey) != '0';

  Future<void> saveAdminPromptShown() =>
      _storage.write(key: _adminPromptKey, value: '1');

  Future<bool> readAdminPromptShown() async =>
      await _storage.read(key: _adminPromptKey) == '1';

  /// Whether traffic is cut off whenever the tunnel is not up.
  ///
  /// Off unless the user turns it on: the mechanism changes a machine-wide
  /// firewall setting, and a client that quietly did that on first launch would
  /// be a hostile one.
  Future<void> saveKillSwitch(bool value) =>
      _storage.write(key: _killSwitchKey, value: value ? '1' : '0');

  Future<bool> readKillSwitch() async =>
      await _storage.read(key: _killSwitchKey) == '1';

  /// The user's own bypass list, stored exactly as it was typed.
  ///
  /// The raw text is kept rather than the parsed list so the field still shows
  /// what the person wrote after a restart; normalisation happens when the
  /// profile is generated.
  Future<void> saveBypassDomains(String value) =>
      _storage.write(key: _bypassDomainsKey, value: value);

  Future<String?> readBypassDomains() => _storage.read(key: _bypassDomainsKey);

  /// Whether Russian sites are kept on the user's own connection.
  ///
  /// Also on by default: it is what keeps bank and government applications from
  /// reacting to a foreign exit address.
  Future<void> saveRuDirect(bool value) =>
      _storage.write(key: _ruDirectKey, value: value ? '1' : '0');

  Future<bool> readRuDirect() async =>
      await _storage.read(key: _ruDirectKey) != '0';

  Future<void> saveThemeMode(String mode) => _storage.write(key: _themeKey, value: mode);

  Future<String?> readThemeMode() => _storage.read(key: _themeKey);

  /// Whether the theme in storage is a choice or just the old default.
  Future<void> saveThemeChosen() =>
      _storage.write(key: _themeChosenKey, value: '1');

  Future<bool> readThemeChosen() async =>
      await _storage.read(key: _themeChosenKey) == '1';

  /// The device identifier reported to the panel as `x-hwid`.
  ///
  /// It has to survive restarts, because the panel counts a new value as a new
  /// device and the subscription has a device limit.
  Future<String?> readDeviceHwid() => _storage.read(key: _hwidKey);

  Future<void> saveDeviceHwid(String value) =>
      _storage.write(key: _hwidKey, value: value);

  Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  Future<String?> readToken() => _storage.read(key: _tokenKey);

  Future<void> clearToken() => _storage.delete(key: _tokenKey);

  Future<void> savePendingTopUp({required String paymentId, int? planId}) async {
    await _storage.write(key: _pendingTopUpKey, value: paymentId);
    if (planId != null) {
      await _storage.write(key: _pendingTopUpPlanKey, value: planId.toString());
    } else {
      await _storage.delete(key: _pendingTopUpPlanKey);
    }
  }

  Future<String?> readPendingTopUpPaymentId() => _storage.read(key: _pendingTopUpKey);

  Future<int?> readPendingTopUpPlanId() async {
    final raw = await _storage.read(key: _pendingTopUpPlanKey);
    return int.tryParse(raw ?? '');
  }
  Future<void> clearPendingTopUp() async {
    await _storage.delete(key: _pendingTopUpKey);
    await _storage.delete(key: _pendingTopUpPlanKey);
  }
}
