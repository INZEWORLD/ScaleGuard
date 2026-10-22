import 'package:flutter/material.dart';

class YandexBrandIcon extends StatelessWidget {
  const YandexBrandIcon({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: _YandexPainter());
  }
}

class _YandexPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.scale(s);
    canvas.drawCircle(const Offset(12, 12), 10, Paint()..color = const Color(0xFFFC3F1D));
    final p = Path()
      ..moveTo(13.32, 7.666)
      ..lineTo(12.396, 7.666)
      ..cubicTo(10.702, 7.666, 9.811, 8.524, 9.811, 9.789)
      ..cubicTo(9.811, 11.219, 10.427, 11.889, 11.692, 12.748)
      ..lineTo(12.737, 13.452)
      ..lineTo(9.734, 17.939)
      ..lineTo(7.49, 17.939)
      ..lineTo(10.185, 13.925)
      ..cubicTo(8.635, 12.814, 7.765, 11.735, 7.765, 9.91)
      ..cubicTo(7.765, 7.622, 9.36, 6.06, 12.385, 6.06)
      ..lineTo(15.388, 6.06)
      ..lineTo(15.388, 17.928)
      ..lineTo(13.32, 17.928)
      ..close();
    canvas.drawPath(p, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class TelegramBrandIcon extends StatelessWidget {
  const TelegramBrandIcon({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: _TelegramOfficialPainter());
  }
}

class _TelegramOfficialPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.scale(s);
    canvas.drawCircle(const Offset(12, 12), 12, Paint()..color = const Color(0xFF229ED9));
    final plane = Path()
      ..moveTo(5.2, 11.85)
      ..lineTo(18.55, 6.72)
      ..cubicTo(19.15, 6.5, 19.68, 6.86, 19.48, 7.62)
      ..lineTo(17.22, 16.95)
      ..cubicTo(17.05, 17.62, 16.64, 17.78, 16.08, 17.47)
      ..lineTo(12.72, 14.98)
      ..lineTo(11.12, 16.52)
      ..cubicTo(10.94, 16.7, 10.78, 16.86, 10.45, 16.86)
      ..lineTo(10.68, 13.42)
      ..lineTo(16.05, 8.58)
      ..cubicTo(16.28, 8.38, 16.0, 8.26, 15.7, 8.46)
      ..lineTo(9.12, 12.58)
      ..lineTo(5.78, 11.52)
      ..cubicTo(5.22, 11.35, 5.2, 11.98, 5.2, 11.85)
      ..close();
    // The plane is not symmetric: its ink sits a little to the right and down,
    // so drawing it as-is made the mark look off-centre inside the circle even
    // though both were built around the same point. Centring the drawn bounds
    // (and leaving the small breathing room the original mark has) puts the
    // paper plane where the eye expects it.
    final bounds = plane.getBounds();
    canvas.save();
    canvas.translate(12, 12);
    canvas.scale(0.88);
    canvas.translate(-bounds.center.dx, -bounds.center.dy);
    canvas.drawPath(plane, Paint()..color = Colors.white);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class MailBrandIcon extends StatelessWidget {
  const MailBrandIcon({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Icon(
      Icons.mail_outline_rounded,
      size: size,
      color: dark ? const Color(0xFFF4F1FF) : const Color(0xFF1F1F1F),
    );
  }
}
