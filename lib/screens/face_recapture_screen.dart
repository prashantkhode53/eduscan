import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../services/face_service.dart';
import '../widgets/face_overlay_painter.dart';

/// Full-screen camera capture for re-registering a student's face.
/// Collects [_requiredSamples] JPEG images and returns them as base64 strings.
/// Returns null if the user cancels.
class FaceRecaptureScreen extends StatefulWidget {
  const FaceRecaptureScreen({super.key});

  @override
  State<FaceRecaptureScreen> createState() => _FaceRecaptureScreenState();
}

class _FaceRecaptureScreenState extends State<FaceRecaptureScreen> {
  CameraController? _cameraCtrl;
  CameraDescription? _frontCamera;
  bool _cameraReady = false;

  Face? _detectedFace;
  FaceOverlayState _overlayState = FaceOverlayState.idle;
  bool _processingFrame = false;
  double _qualityScore = 0;
  String _qualityHint = '';
  bool _autoCapturing = false;
  double _holdProgress = 0.0;

  Timer? _progressTicker;

  final List<String> _sampleImages = [];
  static const int _requiredSamples = 5;
  int _captureCount = 0;
  bool _done = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
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
    _startStream();
  }

  void _startStream() {
    if (_cameraCtrl == null || !_cameraCtrl!.value.isInitialized) return;
    _cameraCtrl!.startImageStream((CameraImage image) async {
      if (_processingFrame || _done) return;
      _processingFrame = true;
      try {
        final inputImage = FaceService.cameraImageToInputImage(image, _frontCamera!);
        if (inputImage == null) return;
        final faces = await FaceService.detectFaces(inputImage);
        if (!mounted) return;

        if (faces.isEmpty) {
          setState(() {
            _detectedFace = null;
            _qualityScore = 0;
            _overlayState = FaceOverlayState.idle;
          });
          _cancelHold();
          return;
        }

        final face = faces.first;
        final quality = _computeQuality(face);
        setState(() {
          _detectedFace = face;
          _qualityScore = quality;
          _overlayState = quality >= 0.55 ? FaceOverlayState.detected : FaceOverlayState.idle;
        });

        if (quality >= 0.55 && !_autoCapturing) {
          _startHold();
        } else if (quality < 0.55) {
          _cancelHold();
        }
      } catch (_) {}
      _processingFrame = false;
    });
  }

  double _computeQuality(Face face) {
    final yaw   = (face.headEulerAngleY ?? 0.0).abs();
    final roll  = (face.headEulerAngleZ ?? 0.0).abs();
    final pitch = (face.headEulerAngleX ?? 0.0).abs();

    if (yaw > 25)  { _qualityHint = 'Look straight ahead'; return 0.0; }
    if (roll > 20) { _qualityHint = 'Hold your head level'; return 0.0; }
    if (pitch > 20){ _qualityHint = 'Raise your chin'; return 0.0; }

    final sizeScore = ((face.boundingBox.width - 80) / 120).clamp(0.0, 1.0);
    if (sizeScore < 0.05) { _qualityHint = 'Move closer'; return 0.0; }

    final angleScore = (1.0 - yaw / 25.0).clamp(0.0, 1.0);
    final rollScore  = (1.0 - roll / 20.0).clamp(0.0, 1.0);
    final pitchScore = (1.0 - pitch / 20.0).clamp(0.0, 1.0);
    final eyeScore   = ((face.leftEyeOpenProbability ?? 1.0) +
                        (face.rightEyeOpenProbability ?? 1.0)) / 2.0;
    final score = (sizeScore * 0.35 + angleScore * 0.25 + rollScore * 0.15 +
                   pitchScore * 0.15 + eyeScore * 0.10).clamp(0.0, 1.0);
    _qualityHint = score < 0.55 ? 'Face the camera directly' : '';
    return score;
  }

  void _startHold() {
    if (_autoCapturing) return;
    _autoCapturing = true;
    _holdProgress = 0.0;
    const holdMs = 1500;
    const tickMs = 50;
    int elapsed = 0;
    _progressTicker = Timer.periodic(const Duration(milliseconds: tickMs), (t) {
      if (!mounted) { t.cancel(); return; }
      elapsed += tickMs;
      setState(() => _holdProgress = (elapsed / holdMs).clamp(0.0, 1.0));
      if (elapsed >= holdMs) {
        t.cancel();
        _progressTicker = null;
        _doCapture();
      }
    });
  }

  void _cancelHold() {
    _progressTicker?.cancel();
    _progressTicker = null;
    _autoCapturing = false;
    if (mounted) setState(() => _holdProgress = 0.0);
  }

  Future<void> _doCapture() async {
    if (!mounted || _cameraCtrl == null || _done) {
      _autoCapturing = false;
      return;
    }
    try {
      await _cameraCtrl!.stopImageStream();
      final xFile = await _cameraCtrl!.takePicture();
      final bytes = await xFile.readAsBytes();
      _sampleImages.add(base64Encode(bytes));
      _captureCount++;
      _holdProgress = 0.0;

      if (_captureCount >= _requiredSamples) {
        _done = true;
        _autoCapturing = false;
        if (mounted) setState(() => _overlayState = FaceOverlayState.successCheckin);
      } else {
        _autoCapturing = false;
        if (mounted) setState(() {});
        _startStream();
      }
    } catch (e) {
      debugPrint('[recapture] error: $e');
      _autoCapturing = false;
      if (mounted) _startStream();
    }
  }

  void _reset() {
    _cancelHold();
    setState(() {
      _sampleImages.clear();
      _captureCount = 0;
      _done = false;
      _overlayState = FaceOverlayState.idle;
      _qualityScore = 0;
      _detectedFace = null;
    });
    _startStream();
  }

  String get _statusText {
    if (_done) return 'All $_requiredSamples photos captured. Tap "Use Photos".';
    if (_autoCapturing) return 'Capturing ${_captureCount + 1} of $_requiredSamples — hold still…';
    if (_detectedFace != null && _qualityScore >= 0.55) return 'Hold still — auto-capturing…';
    if (_detectedFace != null && _qualityHint.isNotEmpty) return _qualityHint;
    return 'Position your face in the oval';
  }

  @override
  void dispose() {
    _progressTicker?.cancel();
    _cameraCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Re-register Face'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context, null),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Camera preview
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: _cameraReady && _cameraCtrl != null
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          CameraPreview(_cameraCtrl!),
                          CustomPaint(
                            painter: FaceOverlayPainter(
                              state: _overlayState,
                              holdProgress: _holdProgress,
                            ),
                          ),
                        ],
                      )
                    : Container(
                        color: Colors.black87,
                        child: const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),

            // Status
            Text(
              _statusText,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: _done
                    ? Colors.green
                    : (_detectedFace != null && _qualityScore >= 0.55
                        ? theme.colorScheme.primary
                        : Colors.grey.shade600),
              ),
            ),
            const SizedBox(height: 12),

            // Quality bar
            if (_qualityScore > 0)
              Row(
                children: [
                  const Text('Quality: ', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: _qualityScore,
                      color: _qualityScore >= 0.55 ? Colors.green : Colors.orange,
                      backgroundColor: Colors.grey.shade200,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${(_qualityScore * 100).toInt()}%',
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
            const SizedBox(height: 12),

            // Sample dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_requiredSamples, (i) {
                final done = i < _captureCount;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  width: done ? 20 : 13,
                  height: done ? 20 : 13,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done ? Colors.green : Colors.grey.shade300,
                  ),
                  child: done
                      ? const Icon(Icons.check, size: 12, color: Colors.white)
                      : null,
                );
              }),
            ),
            const SizedBox(height: 20),

            // Action buttons
            if (_done) ...[
              FilledButton.icon(
                onPressed: _submitting
                    ? null
                    : () => Navigator.pop(context, List<String>.unmodifiable(_sampleImages)),
                icon: _submitting
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check_circle_outline),
                label: const Text('Use Photos'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _reset,
                child: const Text('Retake'),
              ),
            ] else
              OutlinedButton.icon(
                onPressed: (_detectedFace != null && !_autoCapturing)
                    ? () {
                        _cancelHold();
                        _autoCapturing = true;
                        _doCapture();
                      }
                    : null,
                icon: const Icon(Icons.camera_alt_outlined),
                label: Text(_autoCapturing ? 'Capturing…' : 'Capture Now'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),
          ],
        ),
      ),
    );
  }
}
