import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../services/academy_api_service.dart';
import '../../services/face_service.dart';
import '../../services/voice_feedback_service.dart';
import '../../utils/date_utils.dart' as du;
import '../../widgets/face_overlay_painter.dart';

class AcademyFaceScanScreen extends StatefulWidget {
  const AcademyFaceScanScreen({super.key});

  @override
  State<AcademyFaceScanScreen> createState() => _AcademyFaceScanScreenState();
}

class _AcademyFaceScanScreenState extends State<AcademyFaceScanScreen>
    with WidgetsBindingObserver {
  // A successful match always scores >= threshold. When it lands only just
  // above the line (within this band), the recognition is borderline — a common
  // sign the student's appearance changed (new glasses, shaved beard). We still
  // record attendance but nudge them to keep the face clear / update the profile.
  static const double _lowConfidenceBand = 0.07;
  // Used only if the backend response omits `threshold` (older deployments).
  static const double _fallbackThreshold = 0.60;

  CameraController? _cameraCtrl;
  CameraDescription? _frontCamera;
  bool _cameraReady = false;
  String? _initError;     // non-null => init failed; show error + Retry instead of spinner

  // True when the camera/scan loop is intentionally stopped and waiting for the
  // user to resume — e.g. after the app was backgrounded (Android releases the
  // camera) and lifecycle could not auto-recover, or the camera stopped for any
  // reason. Drives the manual "Refresh" overlay so the user is never stuck on a
  // frozen preview with no way out.
  bool _paused = false;
  // Guards against overlapping camera (re)initialisations from rapid
  // resume/connectivity events firing back-to-back.
  bool _initializing = false;

  String _mode = 'checkin';

  // Last scan result as raw map (avoids school-specific ScanResult model)
  Map<String, dynamic>? _lastResult;
  FaceOverlayState _overlayState = FaceOverlayState.idle;

  bool _processingFrame = false;
  bool _debouncing      = false;
  bool _streamRunning   = false;
  Timer? _debounceTimer;
  Timer? _overlayTimer;

  // ── 24/7 kiosk watchdog ─────────────────────────────────────────────────────
  // This screen is designed to stay open continuously (kiosk attendance). Over a
  // long run, the camera stream can stop delivering frames for reasons we can't
  // all enumerate (driver hiccup, OS camera preemption, throttling). The
  // watchdog records the time of the last *delivered* frame and, if the stream
  // goes silent while we're not legitimately mid-scan/paused, rebuilds the
  // camera automatically so the kiosk self-heals without an operator present.
  DateTime _lastFrameAt = DateTime.now();
  Timer?   _watchdogTimer;
  Timer?   _recycleTimer;
  Timer?   _heartbeatTimer;
  bool     _recovering = false;   // drives the brief "Recovering scanner…" banner
  // No frames for this long (while a scan is NOT in flight) ⇒ assume the stream
  // is dead and rebuild. Comfortably longer than a normal scan round-trip.
  static const Duration _watchdogStaleAfter = Duration(seconds: 20);
  static const Duration _watchdogInterval   = Duration(seconds: 10);
  // Proactively recycle the camera periodically to dodge long-run HAL
  // degradation. A clean rebuild costs ~1-2 s and keeps the driver healthy.
  static const Duration _recycleEvery       = Duration(hours: 3);
  static const Duration _heartbeatEvery     = Duration(minutes: 1);

  // ── InsightFace warmup ─────────────────────────────────────────────────────
  // Render's free tier sleeps the Python face service after ~15 min idle, and a
  // cold start takes 60-90 s to load the ArcFace model. We poll readiness on
  // entry and gate scanning until the service confirms it's awake, so the first
  // student doesn't hit a silent "service unavailable" failure.
  bool _scanReady     = false;
  bool _checkingReady = false;
  Timer? _warmupTimer;

  // Watches for the network coming back so the scan can recover on its own:
  // when connectivity is restored we re-probe InsightFace readiness (which also
  // wakes a sleeping container) and resume the camera if it had stopped.
  StreamSubscription<ConnectivityResult>? _connSub;

  // ── Kiosk lock mode ─────────────────────────────────────────────────────────
  // When locked, the screen becomes a student-only scanning station: no back /
  // navigation, system bars hidden (immersive), and Android screen-pinning
  // requested so Home/Recents are blocked at the OS level where allowed.
  // Students can only pick Check In / Check Out and scan. Unlocking requires the
  // academy user's password (verified by the backend).
  bool _locked = false;
  bool _unlocking = false;
  // When true, unlocking requires the academy password; when false, lock/unlock
  // is a free toggle. Controlled by the academy setting `face_scan_secure`
  // (Settings → "Face Scan Attendance – Secure by Password"). Defaults to
  // secure until the real value loads.
  bool _secureUnlock = true;
  static const MethodChannel _kioskChannel =
      MethodChannel('eduscan/kiosk');

  int _checkedIn  = 0;
  int _checkedOut = 0;

  late DateTime _now;
  Timer? _clockTimer;

  String _scanStatus = 'Looking for face...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _now = DateTime.now();
    _loadSecureSetting();
    _startConnectivityWatch();
    _clockTimer = Timer.periodic(
        const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    // Run the exact same initialisation that a fresh "Face Scan Attendance"
    // button tap triggers. Refresh and app-resume call this same method, so the
    // three paths are guaranteed to behave identically.
    _startSession();
  }

  /// The canonical "Face Scan Attendance" start sequence — the single source of
  /// truth shared by the initial open (button tap), the manual Refresh button,
  /// and automatic app-resume. Re-runnable: every step is idempotent / safe to
  /// repeat (warm-up cancels a stale timer, camera init collapses overlapping
  /// calls, TTS warm-up is guarded). This is what makes a refresh or a resume
  /// behave exactly like clicking the button again — with no extra user tap.
  void _startSession() {
    // Clear the scan-loop guard flags. These gate the image-stream callback
    // (`if (_debouncing || _processingFrame) return;`). They are normally reset
    // by the post-scan debounce timer, but a resume / reconnect / refresh can
    // start a NEW stream while a debounce from the previous stream is still
    // pending (or its timer was cancelled mid-flight). If either flag is left
    // `true`, every frame of the new stream early-returns forever: the preview
    // stays live but no scan is ever processed — the screen "freezes" on the
    // last result. Resetting here makes every start path begin scannable.
    _debounceTimer?.cancel();
    _overlayTimer?.cancel();
    _debouncing      = false;
    _processingFrame = false;
    // Keep the screen awake for the whole session so it never dims/locks while
    // an operator is scanning a queue of students. Best-effort: a failure here
    // must never block the camera from starting. Re-asserted on resume because
    // the wakelock is dropped while backgrounded.
    WakelockPlus.enable().catchError(
        (e) => debugPrint('[academy/scan] wakelock enable failed: $e'));
    // Re-probe readiness from scratch: the face service may have slept while we
    // were backgrounded or offline, so always re-warm rather than trusting a
    // stale "ready" flag.
    _scanReady = false;
    _startWarmup();
    VoiceFeedbackService.warmUp();  // pre-init TTS so first "Thank you" is instant
    _startKioskGuards();            // watchdog + periodic recycle + heartbeat
    _initCamera();
  }

  // ── App lifecycle ───────────────────────────────────────────────────────────
  // Android tears down the camera when the app goes to the background, leaving a
  // dead controller and a frozen preview on return. We proactively release it on
  // pause and rebuild it on resume so the scan recovers automatically.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _suspendCamera();
        break;
      case AppLifecycleState.resumed:
        _resumeCamera();
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Tears down the camera + timers when leaving the foreground, but keeps the
  /// screen mounted. Marks the session paused so that if auto-resume can't
  /// recover (e.g. permission revoked while away) the Refresh overlay is shown.
  void _suspendCamera() {
    _debounceTimer?.cancel();
    _overlayTimer?.cancel();
    _cancelKioskGuards();        // re-armed by _startSession on resume
    _recovering = false;         // a pending recovery is moot once suspended
    _debouncing = false;
    if (_streamRunning && _cameraCtrl != null &&
        _cameraCtrl!.value.isInitialized) {
      try { _cameraCtrl!.stopImageStream(); } catch (_) {}
    }
    _streamRunning = false;
    VoiceFeedbackService.stop();
    final ctrl = _cameraCtrl;
    _cameraCtrl = null;
    ctrl?.dispose();
    if (mounted) {
      setState(() {
        _cameraReady = true;     // suppress the spinner; we'll show the resume state
        _paused      = true;
        _overlayState = FaceOverlayState.idle;
        _scanStatus  = 'Paused — resuming…';
      });
    }
  }

  /// Rebuilds the camera and scan loop after returning to the foreground.
  /// Runs the same full start sequence as a fresh "Face Scan Attendance" tap so
  /// the screen recovers automatically with no extra user interaction.
  void _resumeCamera() {
    if (!mounted) return;
    _startSession();
  }

  /// Polls InsightFace readiness every 3 s until it reports awake. Runs in
  /// parallel with camera init so the warm-up overlaps the camera permission /
  /// start latency. The probe itself wakes a sleeping Render container.
  void _startWarmup() {
    _warmupTimer?.cancel();   // avoid stacking timers across resume/reconnect
    _pollReady();
    _warmupTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_scanReady) {
        _warmupTimer?.cancel();
        return;
      }
      _pollReady();
    });
  }

  Future<void> _pollReady() async {
    if (_checkingReady || _scanReady) return;
    _checkingReady = true;
    try {
      // Defensive timeout: checkScanReady() already times out internally, but a
      // belt-and-suspenders guard here ensures _checkingReady can never get
      // stuck `true` over a 24h run and silently kill readiness polling.
      final ready = await AcademyApiService.checkScanReady()
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
      if (!mounted) return;
      if (ready) {
        setState(() {
          _scanReady = true;
          if (_overlayState == FaceOverlayState.idle) {
            _scanStatus = 'Looking for face...';
          }
        });
        _warmupTimer?.cancel();
      }
    } finally {
      _checkingReady = false;
    }
  }

  /// Recovers the scan automatically when the network returns. A dropped
  /// connection makes scan/readiness calls fail; on reconnect we re-probe the
  /// face service (waking it if asleep) and restart the camera if it had stopped.
  void _startConnectivityWatch() {
    _connSub = Connectivity().onConnectivityChanged.listen((result) {
      final online = result == ConnectivityResult.mobile  ||
                     result == ConnectivityResult.wifi     ||
                     result == ConnectivityResult.ethernet;
      if (!online || !mounted) return;
      // Back online: re-warm the face service and make sure scanning is running.
      _scanReady = false;
      _startWarmup();
      if (_paused || (!_streamRunning && _initError == null)) {
        _initCamera();
      } else if (_streamRunning) {
        // The stream is live but may be gated by a guard flag left set when the
        // network dropped mid-scan (a scan/readiness call failed during the
        // debounce window, so the timer that clears `_debouncing` never had a
        // chance to restart a healthy loop). Clear the guards so the existing
        // stream's frames start processing again instead of silently freezing.
        _debounceTimer?.cancel();
        _debouncing      = false;
        _processingFrame = false;
      }
    });
  }

  // ── 24/7 kiosk guards: watchdog + periodic recycle + heartbeat ──────────────

  /// (Re)start the long-run safety timers. Idempotent — cancels any existing
  /// timers first so resume/refresh never stacks duplicates. Called from
  /// `_startSession`, so every start path is protected.
  void _startKioskGuards() {
    _cancelKioskGuards();
    _lastFrameAt = DateTime.now(); // reset so a fresh start isn't seen as stale

    // Watchdog: if frames stop arriving while we should be scanning, rebuild.
    _watchdogTimer = Timer.periodic(_watchdogInterval, (_) {
      if (!mounted) return;
      // Don't fire while legitimately not scanning: paused, mid-scan (debounce/
      // processing), or camera not up. A scan round-trip is brief and updates
      // _lastFrameAt continuously via skipped frames, so genuine scanning never
      // trips the watchdog.
      if (_paused || _initError != null || _recovering) return;
      if (_debouncing || _processingFrame) return;
      final silent = DateTime.now().difference(_lastFrameAt);
      if (_streamRunning && silent >= _watchdogStaleAfter) {
        debugPrint('[academy/scan] watchdog: no frame for '
            '${silent.inSeconds}s — auto-restarting camera');
        _recoverScanner();
      }
    });

    // Proactive camera recycle to avoid long-run driver degradation.
    _recycleTimer = Timer.periodic(_recycleEvery, (_) {
      if (!mounted || _paused || _recovering) return;
      // Only recycle when idle (not mid-scan) so we never interrupt a capture.
      if (_debouncing || _processingFrame) return;
      debugPrint('[academy/scan] periodic camera recycle');
      _recoverScanner();
    });

    // Heartbeat log so a field freeze is diagnosable from logcat.
    _heartbeatTimer = Timer.periodic(_heartbeatEvery, (_) {
      if (!mounted) return;
      final ago = DateTime.now().difference(_lastFrameAt).inSeconds;
      debugPrint('[academy/scan] heartbeat: stream=$_streamRunning '
          'paused=$_paused ready=$_scanReady lastFrame=${ago}s ago '
          'in=$_checkedIn out=$_checkedOut');
    });
  }

  void _cancelKioskGuards() {
    _watchdogTimer?.cancel();   _watchdogTimer  = null;
    _recycleTimer?.cancel();    _recycleTimer   = null;
    _heartbeatTimer?.cancel();  _heartbeatTimer = null;
  }

  /// Auto-recovery: flash a brief banner and rebuild the camera + scan loop.
  /// Used by the watchdog and the periodic recycle. Guarded by `_recovering`
  /// so overlapping triggers collapse into one rebuild.
  void _recoverScanner() {
    if (_recovering || !mounted) return;
    _recovering = true;
    setState(() => _scanStatus = 'Recovering scanner…');
    // _initCamera fully tears down and rebuilds the controller + stream. Clear
    // the recovering flag once it returns (success or handled error).
    _initCamera().whenComplete(() {
      if (mounted) {
        setState(() => _recovering = false);
      } else {
        _recovering = false;
      }
    });
  }

  // ── Kiosk lock mode ─────────────────────────────────────────────────────────

  /// Load the academy's "Secure by Password" flag. Defaults to secure on any
  /// failure so we never accidentally allow password-free unlock.
  Future<void> _loadSecureSetting() async {
    final secure = await AcademyApiService.isFaceScanSecure();
    if (mounted) setState(() => _secureUnlock = secure);
  }

  /// Enter lock mode: hide system bars (immersive sticky) and request Android
  /// screen-pinning so Home/Recents are blocked where the device allows it.
  /// Pinning is best-effort — if unavailable, the in-app lock (no back, hidden
  /// nav) still confines the student to this page.
  Future<void> _lock() async {
    setState(() => _locked = true);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    try {
      await _kioskChannel.invokeMethod('startLockTask');
    } catch (e) {
      debugPrint('[academy/scan] screen pinning unavailable: $e');
    }
  }

  /// Unlock entry point from the top-bar button. When the academy has disabled
  /// password protection (`face_scan_secure = false`), unlock immediately;
  /// otherwise prompt for the password.
  Future<void> _handleUnlockTap() async {
    if (_secureUnlock) {
      await _promptUnlock();
    } else {
      await _unlock();
    }
  }

  /// Prompt for the academy user's password and, if valid, exit lock mode.
  Future<void> _promptUnlock() async {
    final passCtrl = TextEditingController();
    bool visible = false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          title: const Text('Unlock Scanner'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter the academy account password to exit kiosk mode.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                obscureText: !visible,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Password',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                        visible ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setDlg(() => visible = !visible),
                  ),
                ),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Unlock')),
          ],
        );
      }),
    );

    if (ok != true || !mounted) return;
    final password = passCtrl.text;
    if (password.isEmpty) return;

    setState(() => _unlocking = true);
    bool valid = false;
    try {
      valid = await AcademyApiService.verifyAttendancePassword(password);
    } catch (e) {
      debugPrint('[academy/scan] unlock verify failed: $e');
    }
    if (!mounted) return;
    setState(() => _unlocking = false);

    if (valid) {
      await _unlock();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Incorrect password'),
        backgroundColor: Colors.red,
      ));
    }
  }

  /// Exit lock mode: stop screen-pinning and restore the normal system UI.
  Future<void> _unlock() async {
    try {
      await _kioskChannel.invokeMethod('stopLockTask');
    } catch (_) {/* no-op if pinning wasn't active */}
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (mounted) setState(() => _locked = false);
  }

  Future<void> _initCamera() async {
    if (_initializing) return;          // collapse overlapping resume/reconnect calls
    _initializing = true;
    if (mounted) {
      setState(() { _initError = null; _cameraReady = false; _paused = false; });
    }
    // Discard any half-built controller from a previous failed attempt.
    await _cameraCtrl?.dispose();
    _cameraCtrl = null;
    try {
      final cameras =
          await availableCameras().timeout(const Duration(seconds: 8));
      if (cameras.isEmpty) {
        throw CameraException('NoCamera', 'No camera found on this device.');
      }
      _frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final ctrl = CameraController(
        _frontCamera!,
        // 640×480 is ample for a 112×112 ArcFace crop and cuts upload/encode
        // time ~4× vs. medium (1280×720) with no recognition-accuracy loss.
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      _cameraCtrl = ctrl;
      // A denied permission throws synchronously here; a stuck driver never
      // resolves — the timeout converts that hang into an actionable error.
      await ctrl.initialize().timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw TimeoutException(
            'Camera took too long to start. Please try again.'),
      );
      if (!mounted) { await ctrl.dispose(); return; }
      setState(() { _cameraReady = true; _paused = false; });
      _startScanning();
    } catch (e) {
      debugPrint('[academy/scan] camera init failed: $e');
      await _cameraCtrl?.dispose();
      _cameraCtrl = null;
      if (mounted) {
        setState(() { _initError = _friendlyCameraError(e); _paused = true; });
      }
    } finally {
      _initializing = false;
    }
  }

  String _friendlyCameraError(Object e) {
    if (e is CameraException) {
      switch (e.code) {
        case 'CameraAccessDenied':
        case 'CameraAccessDeniedWithoutPrompt':
        case 'CameraAccessRestricted':
          return 'Camera permission denied. Enable camera access in your '
              'device Settings, then tap Retry.';
        case 'NoCamera':
          return 'No camera found on this device.';
      }
      return 'Camera error: ${e.description ?? e.code}';
    }
    if (e is TimeoutException) {
      return e.message ?? 'Camera initialization timed out. Please try again.';
    }
    return 'Could not start camera: $e';
  }

  void _startScanning() {
    final ctrl = _cameraCtrl;
    // Defensive: a resume/reconnect race can leave the controller torn down
    // between the readiness check and here. Rather than crash (force-unwrap) and
    // freeze on a dead preview, surface the manual Refresh path.
    if (ctrl == null || !ctrl.value.isInitialized) {
      _streamRunning = false;
      if (mounted) {
        setState(() {
          _paused     = true;
          _scanStatus = 'Camera stopped. Tap Refresh to resume.';
        });
      }
      return;
    }
    _streamRunning = true;
    ctrl.startImageStream((CameraImage image) async {
      // Watchdog liveness: every delivered frame proves the stream is alive,
      // even ones we skip while debouncing/processing. If this stops updating,
      // the watchdog rebuilds the camera.
      _lastFrameAt = DateTime.now();
      if (_debouncing || _processingFrame) return;
      _processingFrame = true;
      try {
        final inputImage =
            FaceService.cameraImageToInputImage(image, _frontCamera!);
        if (inputImage == null) return;

        final faces = await FaceService.detectFacesForScan(inputImage);
        if (!mounted) return;

        if (faces.isEmpty) {
          if (!_debouncing) {
            setState(() {
              _overlayState = FaceOverlayState.idle;
              _scanStatus   = 'Looking for face...';
            });
          }
          return;
        }

        if (faces.length > 1) {
          setState(() {
            _overlayState = FaceOverlayState.unknown;
            _scanStatus   = 'Multiple faces detected. Please stand alone.';
          });
          return;
        }

        final hint = FaceService.scanQualityHint(faces.first);
        if (hint != null) {
          setState(() {
            _overlayState = FaceOverlayState.idle;
            _scanStatus   = hint;
          });
          return;
        }

        // Face is good, but hold off until the recognition service is awake —
        // otherwise the capture would fail with "service unavailable". Nudge
        // the readiness check so we wake the container while the user waits.
        if (!_scanReady) {
          setState(() {
            _overlayState = FaceOverlayState.idle;
            _scanStatus   = 'Warming up face recognition…';
          });
          _pollReady();
          return;
        }

        setState(() {
          _overlayState = FaceOverlayState.detected;
          _scanStatus   = 'Face detected — scanning...';
        });

        // Stop stream, capture JPEG, send to academy scan API
        await ctrl.stopImageStream();
        _streamRunning = false;
        final xFile     = await ctrl.takePicture();
        final bytes     = await xFile.readAsBytes();
        final imgBase64 = base64Encode(bytes);
        await _processScan(imgBase64);
      } catch (e) {
        debugPrint('[academy/scan] frame error: $e');
      } finally {
        _processingFrame = false;
      }
    });
  }

  Future<void> _processScan(String imageBase64) async {
    _debouncing = true;

    Map<String, dynamic> result;
    try {
      result = await AcademyApiService.scanFace(imageBase64, _mode);
    } catch (e) {
      result = {
        'success': false,
        'action': 'error',
        'message': 'Network error: $e',
      };
    }

    if (!mounted) return;

    final action  = result['action'] as String? ?? 'error';
    final success = result['success'] as bool? ?? false;

    // Haptic feedback
    if (success && (action == 'checkin' || action == 'checkout' || action == 'duplicate')) {
      HapticFeedback.lightImpact();
      if (action == 'checkin')  _checkedIn++;
      if (action == 'checkout') _checkedOut++;
    } else {
      HapticFeedback.heavyImpact();
    }

    // Spoken "Thank you" — ONLY for a newly recorded check-in/out. Deliberately
    // excludes 'duplicate' (no replay within the 10-min window) and every
    // failure/validation case. Fire-and-forget + error-safe, so it can never
    // block the UI, delay scanning, or affect the attendance result.
    if (success && (action == 'checkin' || action == 'checkout')) {
      VoiceFeedbackService.thankYou();
    }

    final statusText = switch (action) {
      'checkin'   => 'Face matched! Check-in recorded.',
      'checkout'  => 'Face matched! Check-out recorded.',
      'duplicate' => 'Already recorded (10 min window).',
      'ambiguous' => 'Ambiguous match. Try again.',
      'unknown'   => 'Face not recognised. Try again.',
      'error'     => 'Error. Try again.',
      _           => result['message'] as String? ?? '',
    };

    setState(() {
      _lastResult   = result;
      _scanStatus   = statusText;
      _overlayState = switch (action) {
        'checkin'  => FaceOverlayState.successCheckin,
        'checkout' => FaceOverlayState.successCheckout,
        _          => FaceOverlayState.unknown,
      };
    });

    // Result card visible for 2.5 s — stream restarts independently at 0.8 s.
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) {
        setState(() {
          _overlayState = FaceOverlayState.idle;
          _scanStatus   = 'Looking for face...';
        });
      }
    });

    // Success: 800 ms is enough to prevent the same person re-triggering before
    // they step away; the result card stays visible for the full overlay timer.
    // Failure: 500 ms gives quick retry without hammering the API.
    final debounceMs = (success &&
            (action == 'checkin' || action == 'checkout' || action == 'duplicate'))
        ? 800
        : 500;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(Duration(milliseconds: debounceMs), () {
      _debouncing = false;
      if (!_streamRunning && mounted && _cameraCtrl != null) {
        _startScanning();
      }
    });
  }

  String _paddedTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';

  void _stopCamera() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _overlayTimer?.cancel();
    _overlayTimer = null;
    _warmupTimer?.cancel();
    _warmupTimer = null;
    _cancelKioskGuards();
    VoiceFeedbackService.stop();  // silence any in-flight "Thank you" on exit
    if (_streamRunning && _cameraCtrl != null &&
        _cameraCtrl!.value.isInitialized) {
      try { _cameraCtrl!.stopImageStream(); } catch (_) {}
    }
    _streamRunning = false;
    _cameraCtrl?.dispose();
    _cameraCtrl = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connSub?.cancel();
    // Release the screen-wake lock so the rest of the app reverts to normal
    // dimming/lock behaviour once we leave the scan screen.
    WakelockPlus.disable().catchError((_) {});
    // Safety net: never leave the device pinned / bars hidden if this screen is
    // torn down while still in lock mode.
    if (_locked) {
      _kioskChannel.invokeMethod('stopLockTask').catchError((_) {});
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _clockTimer?.cancel();
    _stopCamera();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Locked = student kiosk: swallow the back gesture/button entirely so
        // the student can't leave. Exit requires tapping unlock + password.
        if (_locked) return;
        _stopCamera();
        Navigator.of(context).pop();
      },
      child: Theme(
      data: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A56DB),
          brightness: Brightness.dark,
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              // ── Top bar ────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    // Back is hidden while locked so the student can't leave.
                    if (!_locked)
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () {
                          _stopCamera();
                          Navigator.pop(context);
                        },
                      )
                    else
                      const SizedBox(width: 8),
                    const Text(
                      'Attendance Scan',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18),
                    ),
                    const Spacer(),
                    Text(
                      _paddedTime(_now),
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    const SizedBox(width: 4),
                    // Lock / unlock toggle — always visible in the upper corner.
                    _unlocking
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            ),
                          )
                        : IconButton(
                            tooltip: _locked ? 'Unlock' : 'Lock (kiosk mode)',
                            icon: Icon(
                              _locked ? Icons.lock : Icons.lock_open,
                              color: _locked
                                  ? Colors.amberAccent
                                  : Colors.white,
                            ),
                            onPressed:
                                _locked ? _handleUnlockTap : _lock,
                          ),
                  ],
                ),
              ),

              // ── Warmup banner ──────────────────────────────────────────
              if (!_scanReady)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  color: Colors.amber.shade900,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Warming up face recognition… first scan may take '
                          'up to a minute.',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),

              // ── Recovering banner (watchdog / periodic recycle) ────────
              if (_recovering)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  color: Colors.blueGrey.shade800,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      ),
                      SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Recovering scanner… one moment.',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),

              // ── Camera preview ─────────────────────────────────────────
              SizedBox(
                height: size.height * 0.48,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_initError != null)
                      _buildCameraError()
                    else if (_paused)
                      _buildPausedOverlay()
                    else if (_cameraReady && _cameraCtrl != null)
                      CameraPreview(_cameraCtrl!)
                    else
                      const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    CustomPaint(
                      painter: FaceOverlayPainter(state: _overlayState),
                    ),
                    // Scan status overlay
                    Positioned(
                      bottom: 8,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            _scanStatus,
                            style: TextStyle(
                              color: _overlayState == FaceOverlayState.successCheckin ||
                                      _overlayState == FaceOverlayState.successCheckout
                                  ? Colors.greenAccent
                                  : _overlayState == FaceOverlayState.unknown
                                      ? Colors.redAccent
                                      : Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Mode selector ──────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _mode == 'checkin'
                              ? Colors.green.shade600
                              : Colors.grey.shade800,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(44),
                        ),
                        onPressed: () => setState(() => _mode = 'checkin'),
                        child: const Text('CHECK IN',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _mode == 'checkout'
                              ? Colors.orange.shade600
                              : Colors.grey.shade800,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(44),
                        ),
                        onPressed: () => setState(() => _mode = 'checkout'),
                        child: const Text('CHECK OUT',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Result card ────────────────────────────────────────────
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildResultCard(),
                ),
              ),

              // ── Session counters ───────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _counter('In',  _checkedIn.toString(),  Colors.green),
                    _counter('Out', _checkedOut.toString(), Colors.orange),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      ), // Theme
    ); // PopScope
  }

  /// True when a successful match scored only just above the configured
  /// threshold — borderline recognition that usually means the student's
  /// appearance has changed. Drives the "keep your face visible" warning.
  bool _isLowConfidenceMatch(Map<String, dynamic> result) {
    final confidence = (result['confidence'] as num?)?.toDouble();
    if (confidence == null) return false;
    final threshold =
        (result['threshold'] as num?)?.toDouble() ?? _fallbackThreshold;
    return confidence >= threshold &&
        confidence < threshold + _lowConfidenceBand;
  }

  Widget _buildLowConfidenceWarning() => Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Colors.white, size: 18),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                'Please keep your face clearly visible. Changes in appearance '
                '(such as glasses or a shaved beard) may affect face '
                'recognition. If the issue continues, please update your face '
                'profile.',
                style: TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ],
        ),
      );

  Widget _buildResultCard() {
    if (_lastResult == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.face_outlined, size: 36, color: Colors.grey.shade600),
            const SizedBox(height: 8),
            Text('Waiting for face scan...',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
            const SizedBox(height: 4),
            Text('Position your face in the oval guide above',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
          ],
        ),
      );
    }

    final result  = _lastResult!;
    final action  = result['action'] as String? ?? 'error';
    final success = result['success'] as bool? ?? false;
    final message = result['message'] as String? ?? '';
    final confidence = (result['confidence'] as num?)?.toDouble();
    final student = result['student'] as Map<String, dynamic>?;

    final Color cardColor = switch (action) {
      'checkin'   => Colors.green.shade800,
      'checkout'  => Colors.orange.shade800,
      'duplicate' => Colors.amber.shade900,
      'ambiguous' => Colors.deepOrange.shade900,
      _           => Colors.red.shade900,
    };

    // Ambiguous
    if (action == 'ambiguous') {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: cardColor, borderRadius: BorderRadius.circular(12)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_search, color: Colors.white, size: 36),
            const SizedBox(height: 8),
            const Text('Ambiguous Match',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(message,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center),
          ],
        ),
      );
    }

    // Unknown / error
    if (!success || action == 'unknown' || action == 'error') {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: cardColor, borderRadius: BorderRadius.circular(12)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              action == 'unknown'
                  ? Icons.no_accounts_outlined
                  : Icons.error_outline,
              color: Colors.white,
              size: 36,
            ),
            const SizedBox(height: 8),
            Text(
              action == 'unknown' ? 'Face Not Recognised' : 'Scan Error',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(message,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center),
            if (confidence != null && confidence > 0) ...[
              const SizedBox(height: 4),
              Text(
                'Best match: ${(confidence * 100).toStringAsFixed(1)}%',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ],
        ),
      );
    }

    // Success: checkin, checkout, duplicate
    final studentName = student != null
        ? '${student['first_name']} ${student['last_name']}'
        : '';
    final initials = studentName
        .trim()
        .split(' ')
        .where((p) => p.isNotEmpty)
        .map((p) => p[0])
        .take(2)
        .join()
        .toUpperCase();
    final courses   = student?['courses'] as String? ?? '';
    final studentId = student?['id'] as String? ?? '';
    final timeIn    = result['time_in']    as String?;
    final timeOut   = result['time_out']   as String?;
    final durMins   = (result['duration_mins'] as num?)?.toInt();

    String? durationLabel;
    if (durMins != null) {
      final h = durMins ~/ 60;
      final m = durMins  % 60;
      durationLabel = h > 0 ? '${h}h ${m}m' : '${m}m';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: cardColor, borderRadius: BorderRadius.circular(12)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: Colors.white.withValues(alpha: 0.2),
                child: Text(initials,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(studentName,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16)),
                    if (studentId.isNotEmpty)
                      Text(studentId,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11)),
                    if (courses.isNotEmpty)
                      Text(courses,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    if (timeIn != null)
                      Text('In: ${du.fmtTimeOfDay(timeIn)}',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                    if (timeOut != null)
                      Text(
                        'Out: ${du.fmtTimeOfDay(timeOut)}${durationLabel != null ? '  ($durationLabel)' : ''}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    if (confidence != null)
                      Text('Match: ${(confidence * 100).toStringAsFixed(1)}%',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  switch (action) {
                    'checkin'   => 'CHECKED IN',
                    'checkout'  => 'CHECKED OUT',
                    'duplicate' => 'DUPLICATE',
                    _           => 'INFO',
                  },
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 10),
                ),
              ),
            ],
          ),
          if (_isLowConfidenceMatch(result)) _buildLowConfidenceWarning(),
        ],
      ),
    );
  }

  /// Full manual recovery: runs the same start sequence as a fresh "Face Scan
  /// Attendance" tap (re-warm the face service, rebuild the camera + scan loop).
  /// Wired to every Refresh/Retry button so the user is never stuck.
  void _refresh() => _startSession();

  Widget _buildCameraError() => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined,
                  color: Colors.white70, size: 40),
              const SizedBox(height: 12),
              Text(
                _initError ?? 'Camera unavailable',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
              ),
            ],
          ),
        ),
      );

  /// Shown when the camera/scan was stopped (e.g. app was backgrounded) and is
  /// waiting on the user to resume. Gives a clear manual recovery path so the
  /// preview can never stay frozen with no way forward.
  Widget _buildPausedOverlay() => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.pause_circle_outline,
                  color: Colors.white70, size: 40),
              const SizedBox(height: 12),
              const Text(
                'Camera paused.\nTap Refresh to resume scanning.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _counter(String label, String value, Color color) => Column(
        children: [
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 22, fontWeight: FontWeight.bold)),
          Text(label,
              style: const TextStyle(color: Colors.grey, fontSize: 11)),
        ],
      );
}
