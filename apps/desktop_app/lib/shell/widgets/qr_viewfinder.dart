/// Four corner brackets marking the aim area, painted over a live scanner
/// preview. Shared by the Windows stills scanner ([QrCameraScanner] in
/// qr_camera_scanner.dart) and the macOS live scanner (qr_live_scanner.dart)
/// so both frame the code the same way.
library;

import 'package:flutter/material.dart';
import 'package:neolinker_ui/neolinker_ui.dart';

class QrViewfinderBrackets extends StatelessWidget {
  const QrViewfinderBrackets({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.nl;
    return CustomPaint(
      painter: _BracketPainter(color: c.ring),
      size: Size.infinite,
    );
  }
}

class _BracketPainter extends CustomPainter {
  _BracketPainter({required this.color});

  final Color color;

  static const double _armLength = 26;
  static const double _strokeWidth = 2.5;
  static const double _frameScale = 0.62;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * _frameScale;
    if (side <= _armLength * 2) return;
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: side,
      height: side,
    );
    final paint = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;

    // Each corner is an L: one horizontal + one vertical segment.
    const arm = _armLength;
    void corner(Offset point, Offset horizontalEnd, Offset verticalEnd) {
      canvas.drawLine(point, horizontalEnd, paint);
      canvas.drawLine(point, verticalEnd, paint);
    }

    corner(rect.topLeft, Offset(rect.left + arm, rect.top),
        Offset(rect.left, rect.top + arm));
    corner(rect.topRight, Offset(rect.right - arm, rect.top),
        Offset(rect.right, rect.top + arm));
    corner(rect.bottomLeft, Offset(rect.left + arm, rect.bottom),
        Offset(rect.left, rect.bottom - arm));
    corner(rect.bottomRight, Offset(rect.right - arm, rect.bottom),
        Offset(rect.right, rect.bottom - arm));
  }

  @override
  bool shouldRepaint(covariant _BracketPainter oldDelegate) =>
      oldDelegate.color != color;
}
