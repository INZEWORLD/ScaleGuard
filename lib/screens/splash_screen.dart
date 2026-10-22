import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../theme/app_colors.dart';
import '../widgets/reveal.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _pulse;
  late final Animation<double> _scale;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _scale = CurvedAnimation(parent: _intro, curve: Curves.easeOutBack);
    _fade = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.12, 1, curve: Curves.easeOut),
    );
    _intro.forward();
  }

  @override
  void dispose() {
    _intro.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const AuroraBackdrop(intense: true),
          SafeArea(
            child: FadeTransition(
              opacity: _fade,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ScaleTransition(
                        scale: _scale,
                        child: AnimatedBuilder(
                          animation: _pulse,
                          builder: (context, child) {
                            return Transform.scale(
                              scale: 1 + (_pulse.value * 0.03),
                              child: child,
                            );
                          },
                          child: const BrandMark(size: 92),
                        ),
                      ),
                      const SizedBox(height: 22),
                      // Every line after the mark arrives on its own beat: the
                      // staggered reveal is what makes the first screen feel
                      // composed rather than simply loaded.
                      Reveal(
                        controller: _intro,
                        begin: 0.10,
                        end: 0.48,
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
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Reveal(
                        controller: _intro,
                        begin: 0.18,
                        end: 0.58,
                        child: Text(
                          AppConfig.appName,
                          style: TextStyle(
                            color: c.ink,
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Reveal(
                        controller: _intro,
                        begin: 0.26,
                        end: 0.68,
                        child: Text(
                          'Защищённый интернет за секунды',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: c.muted,
                            fontSize: 15,
                            height: 1.4,
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      Reveal(
                        controller: _intro,
                        begin: 0.38,
                        end: 0.9,
                        child: SizedBox(
                          width: 132,
                          child: ClipRRect(
                            borderRadius:
                                const BorderRadius.all(Radius.circular(99)),
                            child: LinearProgressIndicator(
                              minHeight: 3,
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.12),
                              color: SgColors.blue,
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
        ],
      ),
    );
  }
}
