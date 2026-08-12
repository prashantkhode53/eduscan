import 'dart:io' show Platform;

/// Central feature-availability flags for the Windows desktop build.
///
/// The Windows port intentionally ships only the management-console subset of
/// EduScan. Features that depend on mobile-only plugins — the live camera image
/// stream (`camera.startImageStream`), on-device face detection
/// (`google_mlkit_face_detection`), push notifications (`firebase_messaging`),
/// and text-to-speech (`flutter_tts`) — have no Windows support and are hidden
/// on that platform.
///
/// IMPORTANT: these are additive guards only. On Android every flag below is
/// `true`, so the existing Android behaviour is completely unchanged. Never use
/// these to *replace* an Android code path — only to *hide* an entry point on
/// Windows.
class PlatformSupport {
  PlatformSupport._();

  /// True on every platform except Windows desktop.
  static final bool _isWindows = Platform.isWindows;

  /// Camera + on-device ML Kit face detection. Drives student face
  /// registration, face re-capture, live attendance scan, and parent
  /// face-verified login. Unavailable on Windows.
  static bool get faceFeatures => !_isWindows;

  /// Firebase Cloud Messaging push notifications. Unavailable on Windows.
  static bool get pushNotifications => !_isWindows;

  /// `flutter_tts` voice feedback during scanning. Unavailable on Windows.
  static bool get voiceFeedback => !_isWindows;
}
