import 'package:flutter/material.dart';

/// Kleuren van het logo.
class LogoColors {
  static const light = Color(0xFF3F9682);
  static const dark = Color(0xFF1C4A40);
  static const folderBack = Color(0xFFCDEBE1);
  static const folderFront = Color(0xFFFFFFFF);
}

/// Logo van Bestandskluis: een map met een sleutelgat.
///
/// Getekend op een raster van 108 × 108 (de maat van een adaptief
/// Android-icoon); de map valt binnen de veilige zone van 66 in het midden.
class LogoPainter extends CustomPainter {
  const LogoPainter({
    this.background = true,
    this.rounded = true,
    this.monochrome = false,
    this.viewport = const Rect.fromLTWH(18, 18, 72, 72),
  });

  /// Achtergrondverloop tekenen.
  final bool background;

  /// Achtergrond als afgeronde rechthoek (anders vol vlak).
  final bool rounded;

  /// Alleen wit met een uitgespaard sleutelgat (voor thema-iconen).
  final bool monochrome;

  /// Welk deel van het 108-raster wordt getoond.
  final Rect viewport;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / viewport.width;
    final full = Offset.zero & size;

    if (background) {
      final paint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [LogoColors.light, LogoColors.dark],
        ).createShader(full);
      if (rounded) {
        canvas.drawRRect(
            RRect.fromRectAndRadius(full, Radius.circular(size.width * 0.22)),
            paint);
      } else {
        canvas.drawRect(full, paint);
      }
    }

    canvas.saveLayer(full, Paint());
    canvas.scale(s);
    canvas.translate(-viewport.left, -viewport.top);

    RRect r(double l, double t, double rr, double b, double radius) =>
        RRect.fromLTRBR(l, t, rr, b, Radius.circular(radius));

    final back = Paint()
      ..color = monochrome ? Colors.white : LogoColors.folderBack;
    final front = Paint()..color = LogoColors.folderFront;

    // Tab en achterkant van de map.
    canvas.drawRRect(r(31, 35, 53, 46, 3.5), back);
    canvas.drawRRect(r(31, 39, 77, 73, 5), back);
    // Voorkant.
    canvas.drawRRect(r(31, 45, 77, 73, 5), front);

    // Sleutelgat.
    final hole = Path()
      ..addOval(Rect.fromCircle(center: const Offset(54, 56), radius: 5))
      ..addPath(
          Path()
            ..moveTo(51.6, 58.5)
            ..lineTo(56.4, 58.5)
            ..lineTo(57.8, 67.5)
            ..lineTo(50.2, 67.5)
            ..close(),
          Offset.zero);
    canvas.drawPath(
        hole,
        monochrome
            ? (Paint()..blendMode = BlendMode.clear)
            : (Paint()..color = LogoColors.dark));

    canvas.restore();
  }

  @override
  bool shouldRepaint(LogoPainter old) =>
      old.background != background ||
      old.rounded != rounded ||
      old.monochrome != monochrome ||
      old.viewport != viewport;
}

/// Het logo als widget.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 48});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: const CustomPaint(painter: LogoPainter()),
      );
}
