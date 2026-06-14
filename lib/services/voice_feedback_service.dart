import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Spoken success confirmation for attendance ("Thank you").
///
/// Every method here is best-effort and fully error-safe: any TTS failure is
/// caught and swallowed so audio can NEVER affect the attendance flow. Playback
/// is fire-and-forget (never awaited by callers), so it does not block the UI
/// or delay face scanning.
class VoiceFeedbackService {
  static final FlutterTts _tts = FlutterTts();
  static bool _initialized   = false;
  static bool _initInFlight  = false;

  /// Lazily configure the TTS engine once. Safe to call repeatedly.
  static Future<void> _ensureInit() async {
    if (_initialized || _initInFlight) return;
    _initInFlight = true;
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);          // clear; "Thank you" lands under ~1s
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(false); // do not block on playback
      _initialized = true;
    } catch (e) {
      debugPrint('[voice] TTS init failed (non-fatal): $e');
    } finally {
      _initInFlight = false;
    }
  }

  /// Warm the TTS engine when the scan screen opens so the first "Thank you"
  /// isn't delayed by lazy initialisation. Fire-and-forget.
  static void warmUp() {
    _ensureInit();
  }

  /// Speak "Thank you". Never throws; call directly from the UI thread.
  /// Only the caller decides WHEN to call this (success-only) — this method
  /// makes no decision about attendance state.
  static void thankYou() {
    // Detached async so the caller is never blocked and never sees an error.
    () async {
      try {
        await _ensureInit();
        if (!_initialized) return;
        await _tts.stop();            // flush any in-flight utterance (no overlap)
        await _tts.speak('Thank you');
      } catch (e) {
        debugPrint('[voice] TTS speak failed (non-fatal): $e');
      }
    }();
  }

  /// Stop any in-flight speech (e.g. when leaving the scan screen). Best-effort.
  static Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {/* ignore */}
  }
}
