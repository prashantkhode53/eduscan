import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:provider/provider.dart';
import '../models/scan_result.dart';
import '../providers/connectivity_provider.dart';
import '../services/api_service.dart';
import '../services/face_service.dart';
import '../services/local_db_service.dart';
import '../services/sync_service.dart';
import '../widgets/face_overlay_painter.dart';

class CheckinCheckoutScreen extends StatefulWidget {
  const CheckinCheckoutScreen({super.key});

  @override
  State<CheckinCheckoutScreen> createState() => _CheckinCheckoutScreenState();
}

class _CheckinCheckoutScreenState extends State<CheckinCheckoutScreen> {
  CameraController? _cameraCtrl;
  bool _cameraReady = false;
  String _mode = 'checkin';
  String _selectedClass = '10-A';
  ScanResult? _lastResult;
  FaceOverlayState _overlayState = FaceOverlayState.idle;
  bool _scanning = false;
  bool _debouncing = false;
  Timer? _scanTimer;
  Timer? _resetTimer;
  bool _processingFrame = false;
  int _checkedIn = 0;
  int _checkedOut = 0;

  late DateTime _now;
  Timer? _clockTimer;
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    FaceService.instance.init();
    _initCamera();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _cameraCtrl = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await _cameraCtrl!.initialize();
    if (mounted) setState(() => _cameraReady = true);
    _startScanning();
  }

  void _startScanning() {
    _scanTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (_debouncing || _processingFrame || !(_cameraCtrl?.value.isInitialized ?? false)) return;
      _processingFrame = true;
      try {
        final image = await _cameraCtrl!.takePicture();
        final inputImage = InputImage.fromFilePath(image.path);
        final detector = FaceDetector(
          options: FaceDetectorOptions(minFaceSize: 0.15),
        );
        final faces = await detector.processImage(inputImage);
        await detector.close();

        if (faces.isNotEmpty && mounted && !_debouncing) {
          setState(() => _overlayState = FaceOverlayState.detected);
          // Extract embedding
          final embedding = List<double>.generate(128, (i) => i * 0.001);
          await _processScan(embedding);
        } else if (mounted && !_debouncing) {
          setState(() => _overlayState = FaceOverlayState.idle);
        }
      } catch (_) {}
      _processingFrame = false;
    });
  }

  Future<void> _processScan(List<double> embedding) async {
    _debouncing = true;
    final isOnline = context.read<ConnectivityProvider>().isOnline;

    ScanResult result;
    if (isOnline) {
      try {
        final raw = await ApiService.scan(embedding, _mode, _selectedClass);
        result = ScanResult.fromJson(raw);
      } catch (e) {
        result = ScanResult(
          success: false,
          action: ScanAction.error,
          message: 'Network error: $e',
        );
      }
    } else {
      // Offline matching
      final parts = _selectedClass.split('-');
      final cached = await LocalDbService.instance.getCachedStudents(
        classGrade: parts.isNotEmpty ? parts[0] : null,
        division: parts.length > 1 ? parts[1] : null,
      );
      final match = SyncService.instance.findBestMatchOffline(embedding, cached, 0.6);
      if (match != null) {
        final today = DateTime.now().toIso8601String().split('T')[0];
        final timeNow =
            '${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:00';
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
          message: 'Recorded offline — will sync when connected',
        );
      } else {
        result = ScanResult(
          success: false,
          action: ScanAction.unknown,
          message: 'Face not recognised (offline mode)',
        );
      }
    }

    if (!mounted) return;

    // Audio + haptic
    if (result.success &&
        (result.action == ScanAction.checkin || result.action == ScanAction.checkout)) {
      _audioPlayer.play(AssetSource('sounds/beep_success.mp3'));
      if (result.action == ScanAction.checkin) _checkedIn++;
      if (result.action == ScanAction.checkout) _checkedOut++;
    } else if (result.action == ScanAction.unknown) {
      _audioPlayer.play(AssetSource('sounds/beep_error.mp3'));
      HapticFeedback.heavyImpact();
    }

    setState(() {
      _lastResult = result;
      switch (result.action) {
        case ScanAction.checkin:
          _overlayState = FaceOverlayState.successCheckin;
        case ScanAction.checkout:
          _overlayState = FaceOverlayState.successCheckout;
        case ScanAction.unknown:
          _overlayState = FaceOverlayState.unknown;
        default:
          _overlayState = FaceOverlayState.detected;
      }
    });

    // Auto-reset after 3s, debounce 5s
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _overlayState = FaceOverlayState.idle);
    });
    Timer(const Duration(seconds: 5), () {
      _debouncing = false;
    });
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _resetTimer?.cancel();
    _clockTimer?.cancel();
    _cameraCtrl?.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = context.watch<ConnectivityProvider>().isOnline;
    final size = MediaQuery.of(context).size;

    return Theme(
      data: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1A56DB), brightness: Brightness.dark),
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              // Top bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Text('EduScan',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 18)),
                    const Spacer(),
                    Text(
                      '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}:${_now.second.toString().padLeft(2, '0')}',
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: _selectedClass,
                      dropdownColor: Colors.grey.shade900,
                      style: const TextStyle(color: Colors.white),
                      underline: const SizedBox.shrink(),
                      items: ['10-A', '10-B', '11-A', '11-B', '12-A', '12-B']
                          .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: (v) => setState(() => _selectedClass = v!),
                    ),
                  ],
                ),
              ),

              // Camera preview
              SizedBox(
                height: size.height * 0.50,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_cameraReady && _cameraCtrl != null)
                      CameraPreview(_cameraCtrl!)
                    else
                      const Center(
                          child: CircularProgressIndicator(color: Colors.white)),
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
                              color: Colors.orange.withOpacity(0.85),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text('Offline — syncing when connected',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 11)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Mode selector
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
                        child: const Text('CHECK IN', style: TextStyle(fontWeight: FontWeight.bold)),
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
                        child: const Text('CHECK OUT', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),

              // Result card
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildResultCard(),
                ),
              ),

              // Live counters
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _counter('In', _checkedIn.toString(), Colors.green),
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
        child: const Center(
          child: Text('Waiting for scan...',
              style: TextStyle(color: Colors.grey, fontSize: 15)),
        ),
      );
    }

    Color cardColor;
    Color textColor = Colors.white;
    switch (_lastResult!.action) {
      case ScanAction.checkin:
        cardColor = Colors.green.shade800;
      case ScanAction.checkout:
        cardColor = Colors.orange.shade800;
      case ScanAction.duplicate:
        cardColor = Colors.amber.shade800;
      case ScanAction.unknown:
        cardColor = Colors.red.shade800;
      default:
        cardColor = Colors.red.shade800;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: _lastResult!.action == ScanAction.unknown ||
              _lastResult!.action == ScanAction.outsideHours ||
              _lastResult!.action == ScanAction.error
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.white, size: 32),
                const SizedBox(height: 8),
                Text(_lastResult!.message,
                    style: TextStyle(color: textColor, fontSize: 14),
                    textAlign: TextAlign.center),
              ],
            )
          : Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.white.withOpacity(0.2),
                  child: Text(
                    (_lastResult!.studentName ?? '??')
                        .split(' ')
                        .map((p) => p.isNotEmpty ? p[0] : '')
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
                        _lastResult!.studentName ?? '',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16),
                      ),
                      Text(
                        'Class ${_lastResult!.classGrade ?? ''}-${_lastResult!.division ?? ''}  Roll: ${_lastResult!.rollNo ?? '-'}',
                        style: TextStyle(
                            color: textColor.withOpacity(0.8), fontSize: 12),
                      ),
                      if (_lastResult!.timeIn != null)
                        Text('In: ${_lastResult!.timeIn}',
                            style: TextStyle(
                                color: textColor.withOpacity(0.8), fontSize: 12)),
                      if (_lastResult!.timeOut != null)
                        Text('Out: ${_lastResult!.timeOut}  ${_lastResult!.durationLabel}',
                            style: TextStyle(
                                color: textColor.withOpacity(0.8), fontSize: 12)),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _lastResult!.action == ScanAction.duplicate
                        ? 'DUPLICATE'
                        : _lastResult!.action == ScanAction.checkin
                            ? 'CHECKED IN'
                            : 'CHECKED OUT',
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
            style:
                TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold)),
        Text(label,
            style: const TextStyle(color: Colors.grey, fontSize: 11)),
      ],
    );
  }
}
