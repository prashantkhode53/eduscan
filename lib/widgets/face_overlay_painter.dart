import 'dart:math';
import 'package:flutter/material.dart';

enum FaceOverlayState { idle, detected, successCheckin, successCheckout, unknown }

class FaceOverlayPainter extends CustomPainter {
  final FaceOverlayState state;
  final double holdProgress; // 0.0 → 1.0 during hold-still countdown

  const FaceOverlayPainter({required this.state, this.holdProgress = 0.0});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final rx = size.width * 0.38;
    final ry = size.height * 0.45;
    final ovalRect =
        Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2);

    Color ovalColor;
    bool dashed = false;

    switch (state) {
      case FaceOverlayState.idle:
        ovalColor = Colors.white.withValues(alpha: 0.7);
        dashed = true;
      case FaceOverlayState.detected:
        ovalColor = Colors.blue;
      case FaceOverlayState.successCheckin:
        ovalColor = Colors.green;
      case FaceOverlayState.successCheckout:
        ovalColor = Colors.orange;
      case FaceOverlayState.unknown:
        ovalColor = Colors.red;
    }

    // Dim overlay with oval cutout
    final overlayPaint = Paint()..color = Colors.black.withValues(alpha: 0.45);
    final overlayPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(overlayPath, overlayPaint);

    // Oval border
    final borderPaint = Paint()
      ..color = ovalColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    if (dashed) {
      _drawDashedOval(canvas, ovalRect, borderPaint);
    } else {
      canvas.drawOval(ovalRect, borderPaint);
    }

    // Hold-still progress arc — green ring filling clockwise from top
    if (holdProgress > 0 &&
        holdProgress < 1.0 &&
        state == FaceOverlayState.detected) {
      final arcPaint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.0
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        ovalRect.inflate(6),
        -pi / 2,
        2 * pi * holdProgress,
        false,
        arcPaint,
      );
    }

    // Label
    final bool holding =
        holdProgress > 0 && state == FaceOverlayState.detected;
    final String label = switch (state) {
      FaceOverlayState.idle => 'Position your face',
      FaceOverlayState.detected => holding ? 'Hold still...' : 'Face detected',
      FaceOverlayState.successCheckin => 'Recorded ✓',
      FaceOverlayState.successCheckout => 'Recorded ✓',
      FaceOverlayState.unknown => 'Not recognised',
    };

    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: holding ? Colors.green : ovalColor,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          shadows: const [Shadow(color: Colors.black87, blurRadius: 4)],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(cx - textPainter.width / 2, cy + ry + 12),
    );
  }

  void _drawDashedOval(Canvas canvas, Rect rect, Paint paint) {
    final path = Path()..addOval(rect);
    const dashWidth = 12.0;
    const dashSpace = 8.0;
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      double distance = 0;
      while (distance < metric.length) {
        final end = (distance + dashWidth).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(FaceOverlayPainter oldDelegate) =>
      oldDelegate.state != state || oldDelegate.holdProgress != holdProgress;
}
