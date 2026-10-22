import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/windows_deep_link.dart';
import 'core/windows_elevation.dart';
import 'core/windows_helper.dart';
import 'core/windows_shell.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/log_service.dart';
import 'services/notification_service.dart';
import 'services/payment_service.dart';
import 'services/storage_service.dart';
import 'services/vpn_service.dart';
import 'state/app_state.dart';

/// The argument the copy started with administrator rights carries.
///
/// See [kElevatedArgument]; the launcher below is one half of that pair.
const String _elevatedArgument = kElevatedArgument;

/// How long the launcher waits for a replacement instance to claim the
/// single-instance port before it gives up and shows a window itself.
///
/// Both waits below end in "no window" if they are wrong in one direction, so
/// the deadline is deliberately generous: being slow costs a few seconds, being
/// wrong costs the user the application.
const Duration _replacementTimeout = Duration(seconds: 15);

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Opt-in frame log: build with `--dart-define=SG_FRAME_LOG=true` to see what
  // each frame costs on a device (build and raster separately, in ms). Used to
  // judge animation work on a slow phone, where a desktop GPU hides it.
  const frameLog = bool.fromEnvironment('SG_FRAME_LOG');
  if (frameLog) {
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        // Only frames that missed the 60 Hz budget: the log is read from
        // logcat, and a full 60 fps stream would drown the few frames that
        // actually matter.
        if (t.totalSpan.inMilliseconds < 20) continue;
        debugPrint(
          'SGFRAME build=${t.buildDuration.inMilliseconds} '
          'raster=${t.rasterDuration.inMilliseconds} '
          'total=${t.totalSpan.inMilliseconds}',
        );
      }
    });
  }

  final storage = StorageService();
  final alreadyReplacement = args.contains(_elevatedArgument);

  // A `scaleguard://…` activation — the browser handing the user back after a
  // Yandex or Telegram login — is settled here, before anything else gets a say.
  //
  // This order matters. With "always run as administrator" on, the process the
  // browser started is not the one that ends up on screen: it asks the helper
  // task to start an elevated copy and exits, and a scheduled task has a single
  // fixed command line that cannot carry the browser's URL. Forwarding the link
  // to an instance that is already running, or parking it for the replacement to
  // read on its way up, is what keeps the login from being dropped at the door.
  if (Platform.isWindows) {
    final link = WindowsSingleInstanceGate.launchUriFrom(args);
    if (link != null) {
      final delivered = await WindowsSingleInstanceGate.forwardToRunningInstance(
        link,
      );
      if (delivered) {
        // A running instance owns the link now, and it also owns the window.
        _startupTrace('deep link delivered to the running instance');
        exit(0);
      }
      await WindowsPendingDeepLink.store(link);
    }
  }

  // "Always run as administrator" (settings) is honoured before the window is
  // built. The helper task is what turns this from a prompt on every launch into
  // a prompt once — but neither the task nor the prompt is trusted on its own:
  // the port is, because that is what a window on screen actually means.
  if (Platform.isWindows && !alreadyReplacement) {
    await _startElevatedCopyIfRequested(storage);
  }

  // A second launch — a double click, or the browser activating
  // `scaleguard://…` after OAuth — must never open a second window: the URL is
  // forwarded to the running instance and this process exits before any UI
  // exists.
  if (Platform.isWindows && !await WindowsSingleInstanceGate.start(args)) {
    _startupTrace('another instance owns the window; exiting');
    exit(0);
  }

  _startupTrace('primary instance: building the window');

  // Nothing below may keep the window from appearing. A preference that cannot
  // be read is a preference with its default value, not a reason to leave the
  // user staring at nothing — which is exactly how a silent exit looks.
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {}

  String? token;
  try {
    token = await storage.readToken();
  } catch (_) {
    token = null;
  }
  final api = ApiClient(token: token);
  final auth = AuthService(api);
  final payments = PaymentService(api);
  final notifications = NotificationService(api);

  final appState = AppState(
    storage: storage,
    api: api,
    auth: auth,
    payments: payments,
    notifications: notifications,
    vpn: VpnService(onStatusChanged: (_, __) {}),
  );
  appState.attachVpnListener();

  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const ScaleGuardApp(),
    ),
  );

  unawaited(appState.bootstrap());
}

/// Restarts this process with administrator rights when the settings ask for it.
///
/// Returns only when *this* process is the one that has to carry on; it exits
/// itself once a replacement has been proven to be on screen. The proof is the
/// handshake port, never the launch result: Windows can report a successful
/// elevation and leave no process at all behind — which is what a launcher that
/// trusts the answer turns into "I double-clicked it and nothing happened".
Future<void> _startElevatedCopyIfRequested(StorageService storage) async {
  if (!await _readRunAsAdmin(storage)) return;
  try {
    if (await isProcessElevated()) return;

    final helper = WindowsHelper();
    final asked = await helper.isInstalled() && await helper.launch();
    if (asked && await WindowsSingleInstanceGate.isHeldByAnotherInstance()) {
      // The elevated copy is up and owns the handshake port. This one has no
      // reason left to exist.
      _startupTrace('helper started the elevated copy');
      exit(0);
    }
    if (asked) {
      // The task accepted the request but nothing came up. Retrying through
      // the prompt is better than exiting and leaving no window behind.
      LogService.instance.log(
        'app',
        'helper launch produced no instance; falling back to a UAC prompt',
      );
      _startupTrace('helper launch produced no instance');
    }

    // The replacement is a child of this process, and the runner keeps every
    // child of the client from outliving it — which would take the new window
    // down with this one the moment it exits. Lifting that protection around the
    // hand-over is what makes "the elevated copy took over" survivable.
    await WindowsShell.setChildrenMayOutliveUs(true);
    if (!await relaunchElevated(arguments: const [_elevatedArgument])) {
      await WindowsShell.setChildrenMayOutliveUs(false);
      // Windows refused or the user declined the prompt. That is not fatal: the
      // client carries on unelevated and asks again, with an explanation, the
      // first time the tunnel is started.
      _startupTrace('elevation declined; carrying on unelevated');
      return;
    }
    if (await WindowsSingleInstanceGate.isHeldByAnotherInstance(
      timeout: _replacementTimeout,
    )) {
      _startupTrace('elevated copy took over');
      exit(0);
    }
    // The request was accepted and still nothing appeared. Showing the window
    // unelevated is the only answer that does not end with an empty desktop.
    await WindowsShell.setChildrenMayOutliveUs(false);
    _startupTrace('elevated copy never appeared; carrying on unelevated');
  } catch (error) {
    _startupTrace('elevation failed: $error');
  }
}

Future<bool> _readRunAsAdmin(StorageService storage) async {
  try {
    return await storage.readRunAsAdmin();
  } catch (_) {
    return false;
  }
}

/// Appends one line to `%APPDATA%\ScaleGuard\logs\startup.log`.
///
/// A launcher that can end before the app's own logging exists has exactly one
/// failure mode worth being able to explain later: the window never appeared.
/// This is where that story is written down, and it is deliberately independent
/// of everything else — no service, no plugin, no preference.
void _startupTrace(String message) {
  if (!Platform.isWindows) return;
  try {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return;
    final directory = Directory(
      '$appData${Platform.pathSeparator}ScaleGuard${Platform.pathSeparator}logs',
    );
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}startup.log');
    if (file.existsSync() && file.lengthSync() > 128 * 1024) file.deleteSync();
    file.writeAsStringSync(
      '${DateTime.now().toIso8601String()} pid=$pid $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // Diagnostics must never be the reason a launch fails.
  }
}
