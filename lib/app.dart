import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/windows_deep_link.dart';
import 'core/windows_shell.dart';
import 'screens/auth_screen.dart';
import 'screens/email_auth_screen.dart';
import 'screens/main_shell.dart';
import 'screens/offline_screen.dart';
import 'screens/plans_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/splash_screen.dart';
import 'services/update_service.dart';
import 'state/app_state.dart';
import 'theme/app_colors.dart';

/// Native window channel implemented by the Windows runner
/// (`windows/runner/flutter_window.cpp`). Used to keep the title bar in step
/// with the theme the user picked instead of the system one.
const MethodChannel _windowChannel = MethodChannel('scaleguard/window');

class ScaleGuardApp extends StatefulWidget {
  const ScaleGuardApp({super.key});

  @override
  State<ScaleGuardApp> createState() => _ScaleGuardAppState();
}

class _ScaleGuardAppState extends State<ScaleGuardApp> with WidgetsBindingObserver {
  final _appLinks = AppLinks();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<String>? _forwardedLinks;
  bool _linksReady = false;
  bool _minSplashElapsed = false;

  /// Last brightness sent to the native title bar, so the channel is only used
  /// when the value actually changes.
  bool? _titleBarDark;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _minSplashElapsed = true);
    });
    _appLinks.uriLinkStream.listen((uri) {
      if (!mounted) return;
      context.read<AppState>().handleIncomingLink(uri);
    });
    // Windows single-instance hand-off: a second launch forwards its URL to
    // this instance over the loopback gate and exits without a window.
    _forwardedLinks = WindowsSingleInstanceGate.incomingLinks.listen((raw) {
      if (!mounted) return;
      final uri = Uri.tryParse(raw);
      if (uri == null) return;
      // The window is often minimised to the tray by the time a login comes
      // back, and a login the user cannot see is indistinguishable from one
      // that never happened.
      unawaited(WindowsShell.showWindow());
      context.read<AppState>().handleIncomingLink(uri);
    });
  }

  @override
  void dispose() {
    _forwardedLinks?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<AppState>().onAppResumed();
    }
  }

  Future<void> _init() async {
    final state = context.read<AppState>();
    // The tray menu is drawn by the runner, but none of its three entries can be
    // carried out there: restarting, taking the tunnel down and quitting all go
    // through the application state, which owns the tunnel, the system proxy,
    // the kill switch and the saved session. The runner asks, this answers.
    WindowsShell.handleTrayActions(
      restart: state.restartApplication,
      toggle: state.toggleFromTray,
      quit: state.quitApplication,
    );
    // Self-updater: one check shortly after launch, then every hour. It uses the
    // root navigator so the offer is centred over whatever screen is open, and
    // the shutdown callback so Windows can stop the tunnel and release the
    // single-instance port before its binary is replaced.
    UpdateService.instance.start(
      navigatorKey: _navigatorKey,
      shutdown: state.quitApplication,
      ready: () => !state.bootstrapping,
    );
    // The URL this process was itself started with. It either arrived as an
    // argument (this process became the application) or was parked on disk by
    // the launcher when the URL had to survive the elevation hand-off.
    final launchUri = WindowsSingleInstanceGate.consumeLaunchUri();
    final parkedUri = launchUri == null
        ? await WindowsPendingDeepLink.consume()
        : null;
    final initialUri = launchUri ?? parkedUri;
    if (initialUri != null && mounted) {
      final parsed = Uri.tryParse(initialUri);
      if (parsed != null) {
        await state.handleIncomingLink(parsed);
      }
    }
    final initial = await _appLinks.getInitialLink();
    if (initial != null && mounted) {
      await state.handleIncomingLink(initial);
    }
    if (mounted) setState(() => _linksReady = true);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final showSplash = !_linksReady || !_minSplashElapsed || state.bootstrapping;

    // The native caption has to know which flavour of the window it belongs to.
    final dark = switch (state.themeMode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };
    _syncTitleBarTheme(dark);

    Widget screen;
    if (showSplash) {
      screen = const SplashScreen(key: ValueKey('splash'));
    } else if (state.user == null && state.offline) {
      screen = const OfflineScreen(key: ValueKey('offline'));
    } else if (state.user == null) {
      screen = const AuthScreen(key: ValueKey('auth'));
    } else {
      screen = const MainShell(key: ValueKey('home'));
    }

    return MaterialApp(
      title: 'ScaleGuard',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: state.themeMode,
      routes: {
        '/auth': (_) => const AuthScreen(),
        '/email-auth': (_) => const EmailAuthScreen(),
        '/home': (_) => const MainShell(),
        '/plans': (_) => const PlansScreen(),
        '/settings': (_) => const SettingsScreen(),
      },
      // Android still tries to navigate to the whole sign-in URL when the
      // intent reaches the engine rather than the links plugin. A route the
      // application does not know used to end the sign-in with "Could not find
      // a generator for route": the payload is passed on here instead, and the
      // screen it lands on is the one the state says the user belongs on.
      onGenerateRoute: _handleIncomingRoute,
      onUnknownRoute: (_) =>
          MaterialPageRoute<void>(builder: (_) => const _RootFallback()),
      // The restart handed over to a new process is a wait with nothing on
      // screen: the tunnel is taken down, UAC asks for confirmation and the
      // replacement has to claim the port. The overlay lives above the
      // navigator so it also covers an open window when the tray asks.
      builder: (context, child) {
        final restarting = context.select<AppState, bool>((s) => s.restarting);
        return Stack(
          children: [
            if (child != null) child,
            if (restarting) const _RestartOverlay(),
          ],
        );
      },
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 480),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.985, end: 1).animate(animation),
            child: child,
          ),
        ),
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.center,
          children: [...previousChildren, ?currentChild],
        ),
        child: screen,
      ),
    );
  }

  /// Turns a route the OS pushed from a link into an application action.
  ///
  /// `scaleguard://oauth?...` arrives as `/?oauth=...` when the engine, not the
  /// links plugin, handles the intent. The URL is enough to sign the user in,
  /// so it is handed to the state and the user is left on the root screen.
  Route<dynamic> _handleIncomingRoute(RouteSettings settings) {
    final name = settings.name;
    final parsed = (name == null || name.isEmpty) ? null : Uri.tryParse(name);
    if (parsed != null) {
      final state = context.read<AppState>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(state.handleIncomingLink(parsed));
      });
    }
    return MaterialPageRoute<void>(builder: (_) => const _RootFallback());
  }

  /// Pushes the current brightness to the native window frame.
  void _syncTitleBarTheme(bool dark) {
    if (!Platform.isWindows || _titleBarDark == dark) return;
    _titleBarDark = dark;
    unawaited(_applyTitleBarTheme(dark));
  }

  Future<void> _applyTitleBarTheme(bool dark) async {
    try {
      await _windowChannel.invokeMethod<void>('setTitleBarTheme', dark);
    } catch (_) {
      // A runner without the channel (an older build) must never break the UI.
    }
  }
}

/// A hand-over to a restarted copy of the process, shown over everything.
///
/// Right after the rights prompt goes away the window still has work to do:
/// the tunnel is stopped, the elevated copy is started and has to claim the
/// single-instance port. Doing that silently looked like a frozen window that
/// closed "with a delay", so the wait is now explained and cannot be missed.
class _RestartOverlay extends StatelessWidget {
  const _RestartOverlay();

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Stack(
      children: [
        const ModalBarrier(dismissible: false, color: Color(0xC405040E)),
        Center(
          // The builder sits above the navigator, so nothing here is inside a
          // `Material`. MaterialApp answers text outside one with its fallback
          // style — red monospace with a yellow double underline — and only the
          // properties a style sets are overridden: the underline stayed, which
          // is what the yellow lines under every word were. A transparent
          // Material hands the card the theme's text style instead.
          child: Material(
            type: MaterialType.transparency,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
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
                  children: [
                    const SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.6,
                        color: SgColors.violet,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Перезапуск…',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: c.ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Приложение закрывается, чтобы завершить текущие процессы, '
                      'и откроется снова. Это займёт несколько секунд.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: c.muted,
                        fontSize: 12.5,
                        height: 1.4,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Where a route that is not part of the application's map lands.
///
/// The screen follows the session rather than the route, so a link that opened
/// a page the application has no map entry for cannot leave an empty screen or
/// a signed-in user staring at the sign-in form.
class _RootFallback extends StatelessWidget {
  const _RootFallback();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return state.user == null ? const AuthScreen() : const MainShell();
  }
}
