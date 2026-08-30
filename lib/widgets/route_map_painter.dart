import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Draws a simple stylised "map" with a winding safe route,
/// a start marker and a destination flag — purely decorative,
/// good enough for a prototype demo (no real map SDK needed).
class RouteMapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0xFFEFF3FA);
    canvas.drawRect(Offset.zero & size, bgPaint);

    // Faint grid to suggest streets.
    final gridPaint = Paint()
      ..color = Colors.grey.withOpacity(0.18)
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += size.width / 6) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y < size.height; y += size.height / 5) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Route path.
    final path = Path();
    path.moveTo(size.width * 0.18, size.height * 0.85);
    path.quadraticBezierTo(size.width * 0.15, size.height * 0.55,
        size.width * 0.45, size.height * 0.5);
    path.quadraticBezierTo(size.width * 0.75, size.height * 0.45,
        size.width * 0.55, size.height * 0.2);
    path.quadraticBezierTo(size.width * 0.45, size.height * 0.05,
        size.width * 0.7, size.height * 0.1);

    final routePaint = Paint()
      ..color = AppColors.blue
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, routePaint);

    // Start marker.
    final startPaint = Paint()..color = AppColors.green;
    canvas.drawCircle(
        Offset(size.width * 0.18, size.height * 0.85), 8, startPaint);
    canvas.drawCircle(
        Offset(size.width * 0.18, size.height * 0.85),
        8,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);

    // Destination flag.
    final flagPaint = Paint()..color = AppColors.purple;
    canvas.drawCircle(
        Offset(size.width * 0.7, size.height * 0.1), 9, flagPaint);
    final textPainter = TextPainter(
      text: const TextSpan(
        text: '🏁',
        style: TextStyle(fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(size.width * 0.7 - 6, size.height * 0.1 - 8),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
