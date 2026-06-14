import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/academy_api_service.dart';
import '../../services/face_service.dart';
import '../../services/voice_feedback_service.dart';
import '../../widgets/face_overlay_painter.dart';

class AcademyFaceScanScreen extends StatefulWidget {
  const AcademyFaceScanScreen({super.key});

  @override
  State<AcademyFaceScanScreen> createState() => _AcademyFaceScanScreenState();
}

class _AcademyFaceScanScreenState extends State<AcademyFaceScanScreen> {
  CameraController? _cameraCtrl;
  CameraDescription? _frontCamera;
  bool _cameraReady = false;
  String? _initError;     // non-null => init failed; show error + Retry instead of spinner

  String _mode = 'checkin';

  // Last scan result as raw map (avoids school-specific ScanResult model)
  Map<String, dynamic>? _lastResult;
  FaceOverlayState _overlayState = FaceOverlayState.idle;

  bool _processingFrame = false;
  bool _debouncing      = false;
  bool _streamRunning   = false;
  Timer? _debounceTimer;
  Timer? _overlayTimer;

  // ── InsightFace warmup ─────────────────────────────────────────────────────
  // Render's free tier sleeps the Python face service after ~15 min idle, and a
  // cold start takes 60-90 s to load the ArcFace model. We poll readiness on
  // entry and gate scanning until the service confirms it's awake, so the first
  // student doesn't hit a silent "service unavailable" failure.
  bool _scanReady     = false;
  bool _checkingReady = false;
  Timer? _warmupTimer;

  int _checkedIn  = 0;
  int _checkedOut = 0;

  late DateTime _now;
  Timer? _clockTimer;

  String _scanStatus = 'Looking for face...';

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _initCamera();
    _startWarmup();
    VoiceFeedbackService.warmUp();  // pre-init TTS so first "Thank you" is instant
    _clockTimer = Timer.periodic(
        const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  /// Polls InsightFace readiness every 3 s until it reports awake. Runs in
  /// parallel with camera init so the warm-up overlaps the camera permission /
  /// start latency. The probe itself wakes a sleeping Render container.
  void _startWarmup() {
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
      final ready = await AcademyApiService.checkScanReady();
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

  Future<void> _initCamera() async {
    if (mounted) setState(() { _initError = null; _cameraReady = false; });
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
      setState(() => _cameraReady = true);
      _startScanning();
    } catch (e) {
      debugPrint('[academy/scan] camera init failed: $e');
      await _cameraCtrl?.dispose();
      _cameraCtrl = null;
      if (mounted) setState(() => _initError = _friendlyCameraError(e));
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
    _streamRunning = true;
    _cameraCtrl!.startImageStream((CameraImage image) async {
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
        await _cameraCtrl!.stopImageStream();
        _streamRunning = false;
        final xFile     = await _cameraCtrl!.takePicture();
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
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
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

              // ── Camera preview ─────────────────────────────────────────
              SizedBox(
                height: size.height * 0.48,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_cameraReady && _cameraCtrl != null)
                      CameraPreview(_cameraCtrl!)
                    else if (_initError != null)
                      _buildCameraError()
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
      child: Row(
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
                  Text('In: $timeIn',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12)),
                if (timeOut != null)
                  Text(
                    'Out: $timeOut${durationLabel != null ? '  ($durationLabel)' : ''}',
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
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
    );
  }

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
                onPressed: _initCamera,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
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
