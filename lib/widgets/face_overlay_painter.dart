import 'package:flutter/material.dart';

enum FaceOverlayState { idle, detected, successCheckin, successCheckout, unknown }

class FaceOverlayPainter extends CustomPainter {
  final FaceOverlayState state;
  final double scanLineProgress;

  const FaceOverlayPainter({required this.state, this.scanLineProgress = 0.0});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final rx = size.width * 0.38;
    final ry = size.height * 0.45;
    final ovalRect = Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2);

    Color ovalColor;
    bool dashed = false;
    bool showScanLine = false;

    switch (state) {
      case FaceOverlayState.idle:
        ovalColor = Colors.white.withOpacity(0.7);
        dashed = true;
      case FaceOverlayState.detected:
        ovalColor = Colors.blue;
        showScanLine = true;
      case FaceOverlayState.successCheckin:
        ovalColor = Colors.green;
      case FaceOverlayState.successCheckout:
        ovalColor = Colors.orange;
      case FaceOverlayState.unknown:
        ovalColor = Colors.red;
    }

    // Draw dim overlay with oval cutout
    final overlayPaint = Paint()..color = Colors.black.withOpacity(0.45);
    final overlayPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(overlayPath, overlayPaint);

    // Draw oval border
    final borderPaint = Paint()
      ..color = ovalColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    if (dashed) {
      _drawDashedOval(canvas, ovalRect, borderPaint);
    } else {
      canvas.drawOval(ovalRect, borderPaint);
    }

    // Scan line
    if (showScanLine) {
      final scanY = cy - ry + (ry * 2 * scanLineProgress);
      final scanPaint = Paint()
        ..color = Colors.blue.withOpacity(0.8)
        ..strokeWidth = 2.0;
      final startX = _ovalXAtY(cx, rx, ry, cy, scanY);
      if (startX > 0) {
        canvas.drawLine(Offset(cx - startX, scanY), Offset(cx + startX, scanY), scanPaint);
      }
    }

    // Label
    String label = '';
    switch (state) {
      case FaceOverlayState.idle:
        label = 'Position your face';
      case FaceOverlayState.detected:
        label = 'Hold still...';
      case FaceOverlayState.successCheckin:
        label = 'Recorded ✓';
      case FaceOverlayState.successCheckout:
        label = 'Recorded ✓';
      case FaceOverlayState.unknown:
        label = 'Not recognised';
    }

    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: ovalColor,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
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

  double _ovalXAtY(double cx, double rx, double ry, double cy, double y) {
    final yDiff = y - cy;
    final val = 1 - (yDiff * yDiff) / (ry * ry);
    if (val < 0) return 0;
    return rx * Math.sqrt(val);
  }

  @override
  bool shouldRepaint(FaceOverlayPainter oldDelegate) =>
      oldDelegate.state != state || oldDelegate.scanLineProgress != scanLineProgress;
}

// Workaround for dart:math in a widget file
class Math {
  static double sqrt(double x) {
    if (x <= 0) return 0;
    double guess = x / 2;
    for (int i = 0; i < 20; i++) {
      guess = (guess + x / guess) / 2;
    }
    return guess;
  }
}
