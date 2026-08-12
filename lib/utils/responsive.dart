import 'dart:io' show Platform;
import 'package:flutter/material.dart';

/// Responsive layout helpers for the Windows desktop build.
///
/// These are **presentation-only** utilities. They never change behaviour,
/// data, or navigation — they only decide how wide/dense the layout should be
/// for the current window size. On Android every consumer is expected to keep
/// its original mobile layout (callers gate desktop branches behind
/// [Responsive.isDesktop] or [Platform.isWindows]), so the APK is unaffected.
///
/// Breakpoints follow Material 3 window-size classes:
///   compact  : < 600   (phones / very narrow windows)
///   medium   : 600–1023 (small tablets / half-screen windows)
///   expanded : 1024–1439
///   large    : ≥ 1440   (wide desktop)
class Responsive {
  Responsive._();

  static const double compactMax = 600;
  static const double mediumMax = 1024;
  static const double expandedMax = 1440;

  /// Width at which the desktop navigation rail / multi-column layouts kick in.
  static const double desktopBreakpoint = 900;

  /// Comfortable maximum content width for forms and reading columns so content
  /// is not stretched edge-to-edge on a wide monitor.
  static const double readableMaxWidth = 1180;

  /// Narrow content cap for single-column forms (login, dialogs).
  static const double formMaxWidth = 460;

  /// True only on the Windows desktop build. Android always returns false, so
  /// every Android code path stays on its original mobile layout.
  static bool get isWindows => Platform.isWindows;

  static double widthOf(BuildContext context) =>
      MediaQuery.sizeOf(context).width;

  /// Whether to use the desktop shell (sidebar nav, centred content). True only
  /// on Windows once the window is at least [desktopBreakpoint] wide. Android is
  /// always false.
  static bool isDesktop(BuildContext context) =>
      isWindows && widthOf(context) >= desktopBreakpoint;

  static bool isCompact(BuildContext context) =>
      widthOf(context) < compactMax;

  static bool isMedium(BuildContext context) {
    final w = widthOf(context);
    return w >= compactMax && w < mediumMax;
  }

  static bool isExpanded(BuildContext context) {
    final w = widthOf(context);
    return w >= mediumMax && w < expandedMax;
  }

  static bool isLarge(BuildContext context) => widthOf(context) >= expandedMax;

  /// Number of columns for a responsive card/stat grid given the window width.
  /// Mobile keeps 2 columns; wider windows scale up to 4.
  static int gridColumns(
    BuildContext context, {
    int compact = 2,
    int medium = 3,
    int expanded = 4,
  }) {
    final w = widthOf(context);
    if (w >= expandedMax) return expanded;
    if (w >= mediumMax) return expanded;
    if (w >= compactMax) return medium;
    return compact;
  }

  /// Symmetric page padding that grows a little on wider windows.
  static EdgeInsets pagePadding(BuildContext context) {
    final w = widthOf(context);
    if (w >= expandedMax) return const EdgeInsets.symmetric(horizontal: 32, vertical: 24);
    if (w >= mediumMax) return const EdgeInsets.symmetric(horizontal: 24, vertical: 20);
    return const EdgeInsets.all(16);
  }
}

/// Centres its [child] and caps it at [maxWidth] so content does not stretch
/// edge-to-edge on a wide desktop window. On narrow windows it is a no-op
/// (child fills the available width), so mobile layouts are unchanged.
///
/// Purely presentational — wraps existing content without altering it.
class MaxWidthBox extends StatelessWidget {
  final double maxWidth;
  final EdgeInsetsGeometry? padding;
  final Alignment alignment;
  final Widget child;

  const MaxWidthBox({
    super.key,
    required this.child,
    this.maxWidth = Responsive.readableMaxWidth,
    this.padding,
    this.alignment = Alignment.topCenter,
  });

  @override
  Widget build(BuildContext context) {
    Widget content = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    );
    if (padding != null) {
      content = Padding(padding: padding!, child: content);
    }
    return Align(alignment: alignment, child: content);
  }
}
