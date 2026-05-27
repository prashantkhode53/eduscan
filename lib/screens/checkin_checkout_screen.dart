import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/scan_result.dart';
import '../providers/connectivity_provider.dart';
import '../services/api_service.dart';
import '../services/face_service.dart';
import '../services/local_db_service.dart';
import '../services/storage_service.dart';
import '../services/sync_service.dart';
import '../widgets/face_overlay_painter.dart';

class CheckinCheckoutScreen extends StatefulWidget {
  const CheckinCheckoutScreen({super.key});

  @override
  State<CheckinCheckoutScreen> createState() => _CheckinCheckoutScreenState();
}

class _CheckinCheckoutScreenState extends State<CheckinCheckoutScreen> {
  CameraController? _cameraCtrl;
  CameraDescription? _frontCamera;
  bool _cameraReady = false;

  String _mode = 'checkin';
  String? _kioskKey;

  ScanResult? _lastResult;
  FaceOverlayState _overlayState = FaceOverlayState.idle;

  // Prevents concurrent frame processing and rapid re-scans
  bool _processingFrame = false;
  bool _debouncing = false;
  Timer? _debounceTimer;
  Timer? _overlayTimer;

  int _checkedIn = 0;
  int _checkedOut = 0;

  late DateTime _now;
  Timer? _clockTimer;

  // Scan status text shown below the camera view
  String _scanStatus = 'Looking for face...';

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _loadKioskKey();
    _initCamera();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  Future<void> _loadKioskKey() async {
    _kioskKey = await StorageService.getKioskKey();
    if (_kioskKey == null || _kioskKey!.isEmpty) {
      try {
        final settings = await ApiService.getSettings();
        final key = settings['kiosk_api_key'] as String?;
        if (key != null && key.isNotEmpty) {
          _kioskKey = key;
          await StorageService.saveKioskKey(key);
        }
      } catch (e) {
        debugPrint('[scan] Failed to load kiosk key: $e');
      }
    }
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    _frontCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _cameraCtrl = CameraController(
      _frontCamera!,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await _cameraCtrl!.initialize();
    if (mounted) setState(() => _cameraReady = true);
    _startScanning();
  }

  void _startScanning() {
    _cameraCtrl!.startImageStream((CameraImage image) async {
      if (_debouncing || _processingFrame) return;
      _processingFrame = true;
      try {
        final inputImage =
            FaceService.cameraImageToInputImage(image, _frontCamera!);
        if (inputImage == null) return;

        final faces = await FaceService.detectFaces(inputImage);
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

        final face = faces.first;

        // Quality gate — skip low-quality frames instead of producing bad embeddings
        final hint = FaceService.scanQualityHint(face);
        if (hint != null) {
          setState(() {
            _overlayState = FaceOverlayState.idle;
            _scanStatus   = hint;
          });
          return;
        }

        // Single good-quality face — generate embedding and scan
        setState(() {
          _overlayState = FaceOverlayState.detected;
          _scanStatus   = 'Face detected — scanning...';
        });

        final embedding = FaceService.generateEmbedding(face);
        debugPrint('[scan] embedding generated, processing scan...');
        await _processScan(embedding);
      } catch (e) {
        debugPrint('[scan] frame error: $e');
      } finally {
        _processingFrame = false;
      }
    });
  }

  Future<void> _processScan(List<double> embedding) async {
    _debouncing = true;

    final isOnline = context.read<ConnectivityProvider>().isOnline;
    ScanResult result;

    if (isOnline) {
      try {
        final raw = await ApiService.scan(embedding, _mode, '');
        result = ScanResult.fromJson(raw);
        debugPrint('[scan] API result: action=${result.action} confidence=${result.confidence}');
      } catch (e) {
        result = ScanResult(
          success: false,
          action: ScanAction.error,
          message: 'Network error: $e',
        );
        debugPrint('[scan] API error: $e');
      }
    } else {
      // Offline matching against cached students
      final cached = await LocalDbService.instance.getCachedStudents();
      // Offline threshold matches the backend face_threshold setting (0.75)
      final match =
          SyncService.instance.findBestMatchOffline(embedding, cached, 0.75);
      if (match != null) {
        final today   = DateTime.now().toIso8601String().split('T')[0];
        final timeNow = _paddedTime(DateTime.now());
        await LocalDbService.instance.enqueueAttendance(
          studentId: match['id'] as String,
          date: today,
          timeIn: _mode == 'checkin' ? timeNow : null,
          timeOut: _mode == 'checkout' ? timeNow : null,
          status: 'present',
          confidenceIn: match['confidence'] as double?,
        );
        result = ScanResult(
          success: true,
          action: _mode == 'checkin' ? ScanAction.checkin : ScanAction.checkout,
          studentId: match['id'] as String,
          studentName: '${match['first_name']} ${match['last_name']}',
          classGrade: match['class_grade'] as String?,
          division: match['division'] as String?,
          rollNo: match['roll_no'] as int?,
          timeIn: timeNow,
          confidence: match['confidence'] as double?,
          message: 'Recorded offline — will sync when connected',
        );
      } else {
        result = ScanResult(
          success: false,
          action: ScanAction.unknown,
          message: 'No registered face found (offline mode)',
        );
      }
    }

    if (!mounted) return;

    // Haptic feedback
    switch (result.action) {
      case ScanAction.checkin:
      case ScanAction.checkout:
        HapticFeedback.lightImpact();
        if (result.action == ScanAction.checkin) _checkedIn++;
        if (result.action == ScanAction.checkout) _checkedOut++;
      case ScanAction.unknown:
      case ScanAction.error:
        HapticFeedback.heavyImpact();
      default:
        break;
    }

    // Status text
    final statusText = switch (result.action) {
      ScanAction.checkin   => 'Face matched successfully! Check-in recorded.',
      ScanAction.checkout  => 'Face matched successfully! Check-out recorded.',
      ScanAction.duplicate => 'Duplicate attendance within 10 minutes.',
      ScanAction.unknown   => 'Unknown face detected. No registered face found.',
      ScanAction.error     => 'Error. Try again.',
      _                    => result.message,
    };

    setState(() {
      _lastResult = result;
      _scanStatus = statusText;
      _overlayState = switch (result.action) {
        ScanAction.checkin  => FaceOverlayState.successCheckin,
        ScanAction.checkout => FaceOverlayState.successCheckout,
        _                   => FaceOverlayState.unknown,
      };
    });

    // Reset overlay after 3s
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _overlayState = FaceOverlayState.idle;
          _scanStatus   = 'Looking for face...';
        });
      }
    });

    // Debounce duration: 3s for success, 2s for failure/unknown
    final debounceSecs = (result.success &&
            (result.action == ScanAction.checkin ||
                result.action == ScanAction.checkout ||
                result.action == ScanAction.duplicate))
        ? 3
        : 2;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(Duration(seconds: debounceSecs), () {
      _debouncing = false;
      debugPrint('[scan] debounce cleared, ready for next scan');
    });
  }

  String _paddedTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _overlayTimer?.cancel();
    _clockTimer?.cancel();
    _cameraCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = context.watch<ConnectivityProvider>().isOnline;
    final size = MediaQuery.of(context).size;

    return Theme(
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Text(
                      'EduScan',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18),
                    ),
                    const Spacer(),
                    Text(
                      _paddedTime(_now),
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 14),
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
                    else
                      const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    CustomPaint(
                      painter: FaceOverlayPainter(state: _overlayState),
                    ),
                    if (!isOnline)
                      Positioned(
                        top: 8,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text(
                              'Offline — syncing when connected',
                              style: TextStyle(
                                  color: Colors.white, fontSize: 11),
                            ),
                          ),
                        ),
                      ),
                    // Scan status overlay at the bottom of camera
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
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
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

              // ── Live counters ──────────────────────────────────────────
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
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
    );
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
            Icon(Icons.face_outlined,
                size: 36, color: Colors.grey.shade600),
            const SizedBox(height: 8),
            Text(
              'Waiting for face scan...',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              'Position your face in the oval guide above',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
            ),
          ],
        ),
      );
    }

    final result = _lastResult!;
    Color cardColor;
    switch (result.action) {
      case ScanAction.checkin:
        cardColor = Colors.green.shade800;
      case ScanAction.checkout:
        cardColor = Colors.orange.shade800;
      case ScanAction.duplicate:
        cardColor = Colors.amber.shade900;
      case ScanAction.unknown:
      case ScanAction.error:
        cardColor = Colors.red.shade900;
      default:
        cardColor = Colors.red.shade900;
    }

    // Failure / unknown states
    if (result.action == ScanAction.unknown ||
        result.action == ScanAction.error ||
        result.action == ScanAction.outsideHours) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              result.action == ScanAction.unknown
                  ? Icons.no_accounts_outlined
                  : Icons.error_outline,
              color: Colors.white,
              size: 36,
            ),
            const SizedBox(height: 8),
            Text(
              result.action == ScanAction.unknown
                  ? 'Unknown Face Detected'
                  : 'Scan Error',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              result.message,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            if (result.confidence != null && result.confidence! > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Best match score: ${(result.confidence! * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 11),
                ),
              ),
          ],
        ),
      );
    }

    // Success states (checkin, checkout, duplicate)
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: Colors.white.withValues(alpha: 0.2),
            child: Text(
              (result.studentName ?? '??')
                  .split(' ')
                  .where((p) => p.isNotEmpty)
                  .map((p) => p[0])
                  .take(2)
                  .join()
                  .toUpperCase(),
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  result.studentName ?? '',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16),
                ),
                Text(
                  'Class ${result.classGrade ?? ''}-${result.division ?? ''}  Roll: ${result.rollNo ?? '-'}',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12),
                ),
                if (result.timeIn != null)
                  Text('In: ${result.timeIn}',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12)),
                if (result.timeOut != null)
                  Text(
                      'Out: ${result.timeOut}  ${result.durationLabel}',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12)),
                if (result.confidence != null)
                  Text(
                    'Match: ${(result.confidence! * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11),
                  ),
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
              switch (result.action) {
                ScanAction.checkin  => 'CHECKED IN',
                ScanAction.checkout => 'CHECKED OUT',
                ScanAction.duplicate => 'DUPLICATE',
                _ => 'INFO',
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

  Widget _counter(String label, String value, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                color: color,
                fontSize: 22,
                fontWeight: FontWeight.bold)),
        Text(label,
            style:
                const TextStyle(color: Colors.grey, fontSize: 11)),
      ],
    );
  }
}
