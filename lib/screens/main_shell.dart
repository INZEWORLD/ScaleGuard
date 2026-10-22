import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/reveal.dart';
import 'devices_screen.dart';
import 'home_screen.dart';
import 'plans_screen.dart';
import 'settings_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    final state = context.read<AppState>();
    // The tab lives in its own notifier, so switching it rebuilds this shell
    // and nothing else. With a plain `notifyListeners` every screen watching
    // the app state — all four mounted tabs — rebuilt on a tab tap, which is
    // exactly the frame the transition needed.
    return ValueListenableBuilder<int>(
      valueListenable: state.shellTab,
      builder: (context, tab, _) {
        // A blur is a full-width rasterisation on every frame. On a desktop GPU
        // it is free; on a phone it competes with the tab animation itself.
        final blurredBar = Platform.isWindows ||
            Platform.isMacOS ||
            Platform.isLinux;
        Widget bar = Container(
          height: 64,
          decoration: BoxDecoration(
            color: c.nav.withValues(alpha: blurredBar ? 0.82 : 0.96),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _NavIcon(
                icon: Icons.shield_outlined,
                selected: tab == 0,
                onTap: () => state.setShellTab(0),
              ),
              _NavIcon(
                icon: Icons.shopping_bag_outlined,
                selected: tab == 1,
                onTap: () => state.setShellTab(1),
              ),
              _NavIcon(
                icon: Icons.people_outline,
                selected: tab == 2,
                onTap: () {
                  state.setShellTab(2);
                  // The panel owns the list, and it changes whenever a
                  // device connects, so the tab re-reads it on every visit.
                  state.loadDevices(silent: true);
                },
              ),
              _NavIcon(
                icon: Icons.settings_outlined,
                selected: tab == 3,
                onTap: () => state.setShellTab(3),
              ),
            ],
          ),
        );
        if (blurredBar) {
          bar = BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: bar,
          );
        }
        return Scaffold(
          backgroundColor: Colors.transparent,
          extendBody: true,
          body: Stack(
            fit: StackFit.expand,
            children: [
              const RepaintBoundary(child: AuroraBackdrop(intense: true)),
              _TabBody(
                index: tab,
                children: [
                  // An offstage tab keeps its state but must not keep its
                  // tickers running: the pulsing hero and the live dots burned
                  // a frame budget the visible tab needed for its animation.
                  TickerMode(enabled: tab == 0, child: const HomeScreen()),
                  TickerMode(
                    enabled: tab == 1,
                    child: const PlansScreen(embedded: true),
                  ),
                  TickerMode(
                    enabled: tab == 2,
                    child: const DevicesScreen(embedded: true),
                  ),
                  TickerMode(
                    enabled: tab == 3,
                    child: const SettingsScreen(embedded: true),
                  ),
                ],
              ),
            ],
          ),
          bottomNavigationBar: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: RepaintBoundary(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(32),
                child: bar,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TabBody extends StatefulWidget {
  const _TabBody({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_TabBody> createState() => _TabBodyState();
}

/// Swaps tabs with a short fade instead of a hard cut.
///
/// The pages stay in an [IndexedStack], so their state (scroll positions, open
/// lists, the running hero animation) survives the switch.
///
/// The fade is a veil drawn *over* the page, never a transform or an opacity
/// around the page itself. Both of those look free on a desktop GPU and both
/// are frame-by-frame work on a weak phone: a translated full-screen layer is
/// re-rasterised by Impeller on every frame, and an opacity around the page
/// adds an offscreen buffer on top of that. A solid veil only changes one
/// colour per frame, while the page underneath stays a cached
/// [RepaintBoundary] layer — which is the difference between a transition and
/// a slideshow.
class _TabBodyState extends State<_TabBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 170),
    value: 1,
  );

  @override
  void didUpdateWidget(covariant _TabBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _enter.value = 1;
      return;
    }
    _enter.forward(from: 0);
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final veilColor = SgColors.of(context).canvas;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: IndexedStack(index: widget.index, children: widget.children),
        ),
        IgnorePointer(
          child: AnimatedBuilder(
            animation: _enter,
            builder: (context, _) {
              final t = Curves.easeOutCubic.transform(_enter.value);
              if (t >= 1) return const SizedBox.shrink();
              // One rectangle per frame; no layer around the page.
              return ColoredBox(
                color: veilColor.withValues(alpha: (1 - t) * 0.88),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _NavIcon extends StatelessWidget {
  const _NavIcon({required this.icon, this.selected = false, this.onTap});

  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      scale: 0.92,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: AnimatedContainer(
          // A fixed width: animating it would relayout the whole bar on every
          // frame, which is the kind of work a weak phone feels. Only the
          // decoration and the icon scale change now, and those are paint and
          // transform work inside the bar's own repaint boundary.
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: 56,
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: selected
                ? const LinearGradient(
                    colors: [SgColors.blue, SgColors.violet],
                  )
                : null,
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: SgColors.blue.withValues(alpha: 0.45),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: AnimatedScale(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            scale: selected ? 1.05 : 1,
            child: Icon(
              icon,
              color: selected ? Colors.white : const Color(0xFF8E8E93),
              size: 25,
            ),
          ),
        ),
      ),
    );
  }
}
