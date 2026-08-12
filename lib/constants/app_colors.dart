import 'dart:io' show Platform;
import 'package:flutter/material.dart';

/// App colour palette and themes.
///
/// IMPORTANT — platform parity:
/// The Android theme is intentionally LEFT EXACTLY AS IT WAS. All desktop
/// refinements (denser typography, auto-width buttons, hover states, refined
/// surfaces) live behind `Platform.isWindows` and apply only to the Windows
/// desktop build. On Android `lightTheme` / `darkTheme` resolve to the original
/// mobile theme, so the APK renders pixel-identical to before.
class AppColors {
  static const Color primary = Color(0xFF1A56DB);
  static const Color primaryDark = Color(0xFF1246C0);
  static const Color success = Color(0xFF16A34A);
  static const Color error = Color(0xFFDC2626);
  static const Color warning = Color(0xFFD97706);
  static const Color info = Color(0xFF0284C7);

  // ── Public entry points (unchanged signatures) ───────────────────────────
  static ThemeData get lightTheme =>
      Platform.isWindows ? _desktopTheme(Brightness.light) : _mobileTheme(Brightness.light);

  static ThemeData get darkTheme =>
      Platform.isWindows ? _desktopTheme(Brightness.dark) : _mobileTheme(Brightness.dark);

  // ── Original mobile theme (Android) — DO NOT CHANGE ──────────────────────
  static ThemeData _mobileTheme(Brightness brightness) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primary,
          brightness: brightness,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 1,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      );

  // ── Modern desktop theme (Windows only) ──────────────────────────────────
  //
  // A consistent, Fluent-inspired design system: a refined surface palette,
  // a slightly tighter type scale tuned for mouse-distance viewing, hover and
  // focus affordances, and desktop-appropriate controls (buttons size to their
  // content rather than stretching full-width).
  static ThemeData _desktopTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    );

    // Subtle neutral surfaces give the app a calm, layered desktop look.
    final scaffoldBg = isDark ? const Color(0xFF15161A) : const Color(0xFFF4F6FB);
    final surface = isDark ? const Color(0xFF1D1F25) : Colors.white;
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : const Color(0xFF0F172A).withValues(alpha: 0.07);
    final outline = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : const Color(0xFF0F172A).withValues(alpha: 0.12);

    final hoverOverlay = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.pressed)) {
        return scheme.primary.withValues(alpha: 0.18);
      }
      if (states.contains(WidgetState.hovered)) {
        return scheme.primary.withValues(alpha: 0.10);
      }
      return null;
    });

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme.copyWith(surface: surface),
      scaffoldBackgroundColor: scaffoldBg,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
    );

    // Desktop type scale: slightly tighter line-height and weight balance,
    // readable at typical monitor distance.
    final t = base.textTheme;
    final textTheme = t.copyWith(
      displaySmall: t.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      headlineSmall: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: t.bodyLarge?.copyWith(height: 1.4),
      bodyMedium: t.bodyMedium?.copyWith(height: 1.4),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.1),
    );

    const radius = 12.0;
    final buttonShape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius - 2));

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
        shape: Border(bottom: BorderSide(color: cardBorder, width: 1)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: surface,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: cardBorder, width: 1),
        ),
      ),
      dividerTheme: DividerThemeData(color: cardBorder, thickness: 1, space: 1),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surface,
        elevation: 0,
        useIndicator: true,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme:
            IconThemeData(color: scheme.onSurface.withValues(alpha: 0.65)),
        selectedLabelTextStyle: textTheme.labelLarge?.copyWith(color: scheme.primary),
        unselectedLabelTextStyle: textTheme.labelLarge
            ?.copyWith(color: scheme.onSurface.withValues(alpha: 0.7)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        elevation: 0,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? Colors.white.withValues(alpha: 0.04) : const Color(0xFFF8FAFC),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius - 2),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius - 2),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius - 2),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
      ),
      // Desktop buttons size to content (not full-width) and gain hover states.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
          shape: WidgetStatePropertyAll(buttonShape),
          overlayColor: hoverOverlay,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
          shape: WidgetStatePropertyAll(buttonShape),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
          shape: WidgetStatePropertyAll(buttonShape),
          side: WidgetStatePropertyAll(BorderSide(color: outline)),
          overlayColor: hoverOverlay,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
          shape: WidgetStatePropertyAll(buttonShape),
          overlayColor: hoverOverlay,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(overlayColor: hoverOverlay),
      ),
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide(color: outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2D35) : const Color(0xFF1F2430),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      dialogTheme: DialogThemeData(
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      scrollbarTheme: const ScrollbarThemeData(
        thumbVisibility: WidgetStatePropertyAll(true),
        thickness: WidgetStatePropertyAll(8),
        radius: Radius.circular(8),
        interactive: true,
      ),
    );
  }
}
