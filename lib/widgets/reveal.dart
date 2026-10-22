import 'package:flutter/material.dart';

/// Fades a child in while lifting it into place.
///
/// Used by the launch and sign-in screens, where the order in which the pieces
/// arrive is what makes the screen feel composed instead of simply loaded. A
/// [controller] that is already running can be shared by several reveals, each
/// with its own slot in time.
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.controller,
    required this.child,
    this.begin = 0,
    this.end = 1,
    this.offset = 14,
    this.curve = Curves.easeOutCubic,
  });

  /// Drives the animation. Usually an [AnimationController] owned by the screen.
  final Animation<double> controller;

  final Widget child;

  /// Start and end of this reveal inside [controller], in the 0..1 range.
  final double begin;
  final double end;

  /// How far (logical pixels) the child travels upwards while fading in.
  final double offset;

  final Curve curve;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> {
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _animation = CurvedAnimation(
      parent: widget.controller,
      curve: Interval(widget.begin, widget.end, curve: widget.curve),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      child: widget.child,
      builder: (context, child) {
        final value = _animation.value.clamp(0.0, 1.0);
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * widget.offset),
            child: child,
          ),
        );
      },
    );
  }
}

/// Wraps a tappable child so it dips slightly while held.
///
/// Desktop and mobile both benefit: without it a tap has no physical feedback
/// on a screen that is otherwise full of motion.
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.scale = 0.97,
    this.duration = const Duration(milliseconds: 110),
  });

  final Widget child;
  final double scale;
  final Duration duration;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1,
        duration: widget.duration,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
