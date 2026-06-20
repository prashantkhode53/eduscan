/// App build mode — selects which login this APK is built for.
///
/// Set at build time via `--dart-define=APP_MODE=academy` or
/// `--dart-define=APP_MODE=parent`. Defaults to `academy`, so a plain
/// `flutter build apk` with no define produces the exact same app that
/// existed before this switch was introduced.
///
/// This is a pure Dart-side flag: it does NOT change the Android
/// applicationId, google-services.json, manifest, Firebase, FCM, or any
/// feature. Both APKs remain `com.eduscan.app` and share the same Firebase
/// project — only the first login screen shown differs.
library;

enum AppFlavor { academy, parent }

class AppMode {
  AppMode._();

  static const String _raw =
      String.fromEnvironment('APP_MODE', defaultValue: 'academy');

  /// The flavor this APK was built as. Unknown/empty values fall back to
  /// [AppFlavor.academy] so nothing breaks if the define is omitted.
  static final AppFlavor flavor =
      _raw.toLowerCase() == 'parent' ? AppFlavor.parent : AppFlavor.academy;

  static bool get isAcademy => flavor == AppFlavor.academy;
  static bool get isParent => flavor == AppFlavor.parent;

  /// Route the splash screen sends a logged-out user to.
  ///   academy  -> '/login'         (academy admin/teacher login)
  ///   parent   -> '/parent/login'  (parent/guardian face-verified login)
  static String get loginRoute => isParent ? '/parent/login' : '/login';

  /// Whether the academy login screen should surface the
  /// "Parent / Guardian Login" entry button. Hidden in the Parent APK
  /// (it never reaches the academy login) and hidden in the Academy APK
  /// so each app is single-purpose.
  static bool get showParentEntry => false;

  /// Window/app title suffix so the two builds are distinguishable.
  static String get titleSuffix => isParent ? ' Parent' : '';
}
