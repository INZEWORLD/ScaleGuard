import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SgColors {
  SgColors._(this.dark);
  factory SgColors.of(BuildContext context) =>
      SgColors._(Theme.of(context).brightness == Brightness.dark);

  final bool dark;

  Color get canvas => dark ? const Color(0xFF070614) : const Color(0xFFF4F6FF);
  Color get ink => dark ? const Color(0xFFF4F1FF) : const Color(0xFF171A2B);
  Color get muted => dark ? const Color(0xFFB7B3D0) : const Color(0xFF5B6478);
  Color get faint => dark ? const Color(0xFF8C87A8) : const Color(0xFF8B93A7);
  Color get pill => dark ? const Color(0xFF17142A) : const Color(0xFFF3F5FB);
  Color get line => dark ? const Color(0x33FFFFFF) : const Color(0xFFE4E8F2);
  Color get card => dark ? const Color(0xCC14102A) : Colors.white.withValues(alpha: 0.9);
  Color get sheet => dark ? const Color(0xFF14102A) : Colors.white;
  Color get nav => dark ? const Color(0xFF120E24) : const Color(0xFF1B1F33);

  static const blue = Color(0xFF5B7CFF);
  static const teal = Color(0xFF3DDBFF);
  static const violet = Color(0xFF9B7CFF);
  static const red = Color(0xFFFF4D6A);
  static const green = Color(0xFF3DFFB0);
}

class AppColors {
  static const canvas = Color(0xFF070614);
  static const ink = Color(0xFFF4F1FF);
  static const muted = Color(0xFFB7B3D0);
  static const faint = Color(0xFF8C87A8);
  static const pill = Color(0xFF17142A);
  static const line = Color(0x33FFFFFF);
  static const blue = SgColors.blue;
  static const teal = SgColors.teal;
  static const violet = SgColors.violet;
  static const red = SgColors.red;
  static const green = SgColors.green;
}

class AuroraBackdrop extends StatelessWidget {
  const AuroraBackdrop({super.key, this.intense = false});

  final bool intense;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final a = intense ? 0.55 : 0.4;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? const [Color(0xFF070614), Color(0xFF120B2E), Color(0xFF08122A)]
                : const [Color(0xFFF7F4FF), Color(0xFFF3F8FF), Color(0xFFEDFBF6)],
          ),
        ),
        child: Stack(
          children: [
            Positioned(top: -120, right: -70, child: _Glow(size: 300, color: SgColors.violet.withValues(alpha: a))),
            Positioned(top: 160, left: -90, child: _Glow(size: 260, color: SgColors.blue.withValues(alpha: a * 0.9))),
            Positioned(bottom: -90, right: -30, child: _Glow(size: 280, color: SgColors.teal.withValues(alpha: a * 0.7))),
          ],
        ),
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
      ),
    );
  }
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 88});
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = SgColors.of(context);
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        color: c.dark ? Colors.white.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.86),
        border: Border.all(color: Colors.white.withValues(alpha: c.dark ? 0.12 : 1)),
        boxShadow: [
          BoxShadow(
            color: SgColors.violet.withValues(alpha: 0.28),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Image.asset(
        'assets/scaleguard-logo.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final ink = dark ? const Color(0xFFF4F1FF) : const Color(0xFF171A2B);
    final canvas = dark ? const Color(0xFF070614) : const Color(0xFFF4F6FF);
    final pill = dark ? const Color(0xFF17142A) : const Color(0xFFF3F5FB);
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: canvas,
      colorScheme: ColorScheme.fromSeed(seedColor: SgColors.blue, brightness: brightness),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: dark
            ? SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent)
            : SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent),
        titleTextStyle: TextStyle(color: ink, fontSize: 17, fontWeight: FontWeight.w700),
      ),
      listTileTheme: const ListTileThemeData(
        tileColor: Colors.transparent,
        selectedTileColor: Colors.transparent,
        // Without a shape the pointer highlight is the tile's plain rectangle:
        // inside a rounded card it read as a crooked square sitting on the
        // rounded corners. The tile's InkWell uses this as its custom border, so
        // hover, focus and splash all follow the same radius.
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
      ),
      // The switches are the one control the user touches on every settings
      // screen, so they carry the product violet instead of the seed colour.
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? SgColors.violet
              : (dark ? const Color(0x33FFFFFF) : const Color(0xFFDDE2EE)),
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? SgColors.violet
              : (dark ? const Color(0x33FFFFFF) : const Color(0xFFDDE2EE)),
        ),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : (dark ? const Color(0xFFB7B3D0) : Colors.white),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: dark ? const Color(0xFF14102A) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
      // Every push uses the same gentle fade-and-slide instead of the platform
      // defaults, which read as a flicker or a hard cut next to the app's own
      // transitions. One builder for every platform keeps the feel identical on
      // the phone and on the desktop.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        },
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: pill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(88, 52),
          backgroundColor: SgColors.blue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        ),
      ),
    );
  }
}
