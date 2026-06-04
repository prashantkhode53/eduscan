import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/parent_auth_provider.dart';
import '../../services/face_service.dart';
import '../../services/fcm_service.dart';
import '../../services/parent_api_service.dart';
import '../../widgets/face_overlay_painter.dart';

class ParentLoginScreen extends StatefulWidget {
  const ParentLoginScreen({super.key});

  @override
  State<ParentLoginScreen> createState() => _ParentLoginScreenState();
}

class _ParentLoginScreenState extends State<ParentLoginScreen> {
  final _pageCtrl   = PageController();
  int   _step       = 0; // 0 = credentials, 1 = face scan

  // ── Step 0: credentials ────────────────────────────────────────────────────
  final _formKey    = GlobalKey<FormState>();
  final _slugCtrl   = TextEditingController();
  final _idCtrl     = TextEditingController();
  final _mobileCtrl = TextEditingController();
  bool _verifying   = false;

  // Session token returned from step 1 — kept in memory only (5-min TTL)
  String? _sessionToken;
  String? _studentName;
  String? _academyName;

  // ── Step 1: face scan ──────────────────────────────────────────────────────
  CameraController? _camCtrl;
  CameraDescription? _frontCam;
  bool _camReady        = false;
  bool _processingFrame = false;
  bool _autoCapturing   = false;
  bool _faceDone        = false;
  bool _submittingFace  = false;
  double _holdProgress  = 0.0;
  double _qualityScore  = 0.0;
  String _qualityHint   = '';
  FaceOverlayState _overlayState = FaceOverlayState.idle;
  Timer? _progressTicker;
  String? _faceError;

  @override
  void dispose() {
    _pageCtrl.dispose();
    _slugCtrl.dispose();
    _idCtrl.dispose();
    _mobileCtrl.dispose();
    _disposeCamera();
    super.dispose();
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  Future<void> _goToFaceScan() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _verifying = true; _faceError = null; });

    try {
      final data = await ParentApiService.checkCredentials(
        academySlug: _slugCtrl.text.trim(),
        studentId:   _idCtrl.text.trim(),
        mobile:      _mobileCtrl.text.trim(),
      );
      _sessionToken = data['session_token'] as String;
      _studentName  = data['student_name']  as String? ?? '';
      _academyName  = data['academy_name']  as String? ?? '';

      setState(() { _verifying = false; _step = 1; });
      _pageCtrl.animateToPage(1,
          duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      _initCamera();
    } catch (e) {
      setState(() { _verifying = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  void _goBack() {
    if (_step == 0) { Navigator.pop(context); return; }
    _disposeCamera();
    setState(() {
      _step         = 0;
      _faceDone     = false;
      _faceError    = null;
      _sessionToken = null;
      _qualityScore = 0;
      _holdProgress = 0;
      _overlayState = FaceOverlayState.idle;
    });
    _pageCtrl.animateToPage(0,
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  // ── Camera ─────────────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    if (_camCtrl != null) return;
    try {
      final cameras = await availableCameras();
      _frontCam = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      _camCtrl = CameraController(_frontCam!, ResolutionPreset.medium,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
      await _camCtrl!.initialize();
      if (mounted) setState(() => _camReady = true);
      _startStream();
    } catch (e) {
      if (mounted) {
        setState(() {
          _faceError = 'Camera error: $e';
        });
      }
    }
  }

  void _disposeCamera() {
    _progressTicker?.cancel();
    _progressTicker   = null;
    _camCtrl?.dispose();
    _camCtrl          = null;
    _camReady         = false;
    _autoCapturing    = false;
    _processingFrame  = false;
  }

  void _startStream() {
    if (_camCtrl == null || !_camCtrl!.value.isInitialized) return;
    _camCtrl!.startImageStream((image) async {
      if (_processingFrame || _faceDone) return;
      _processingFrame = true;
      try {
        final inputImage = FaceService.cameraImageToInputImage(image, _frontCam!);
        if (inputImage == null) return;
        final faces = await FaceService.detectFaces(inputImage);
        if (!mounted) return;

        if (faces.isEmpty) {
          setState(() {
            _overlayState = FaceOverlayState.idle;
            _qualityScore = 0;
            _qualityHint  = '';
          });
          _cancelHold();
          return;
        }

        if (faces.length > 1) {
          setState(() {
            _overlayState = FaceOverlayState.unknown;
            _qualityHint  = 'Multiple faces — stand alone';
          });
          _cancelHold();
          return;
        }

        final hint = FaceService.scanQualityHint(faces.first);
        if (hint != null) {
          setState(() {
            _overlayState = FaceOverlayState.idle;
            _qualityScore = 0;
            _qualityHint  = hint;
          });
          _cancelHold();
          return;
        }

        final quality = _computeQuality(faces.first);
        setState(() {
          _qualityScore = quality;
          _overlayState = quality >= 0.55
              ? FaceOverlayState.detected
              : FaceOverlayState.idle;
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

  double _computeQuality(dynamic face) {
    final yaw   = (face.headEulerAngleY as double? ?? 0).abs();
    final roll  = (face.headEulerAngleZ as double? ?? 0).abs();
    final pitch = (face.headEulerAngleX as double? ?? 0).abs();
    if (yaw > 25)  { _qualityHint = 'Look straight ahead'; return 0.0; }
    if (roll > 20) { _qualityHint = 'Hold your head level'; return 0.0; }
    if (pitch > 20){ _qualityHint = 'Look directly at camera'; return 0.0; }
    final sizeScore =
        (((face.boundingBox.width as num).toDouble() - 80) / 120).clamp(0.0, 1.0);
    if (sizeScore < 0.05) { _qualityHint = 'Move closer'; return 0.0; }
    final eyeScore =
        ((face.leftEyeOpenProbability  as double? ?? 1.0) +
         (face.rightEyeOpenProbability as double? ?? 1.0)) / 2.0;
    final score = (sizeScore * 0.35 +
        (1 - yaw / 25) * 0.25 + (1 - roll / 20) * 0.15 +
        (1 - pitch / 20) * 0.15 + eyeScore * 0.10).clamp(0.0, 1.0);
    _qualityHint = score < 0.55
        ? (sizeScore < 0.3 ? 'Move closer to camera' : 'Face the camera directly')
        : '';
    return score;
  }

  void _startHold() {
    if (_autoCapturing) return;
    _autoCapturing = true;
    _holdProgress  = 0.0;
    int elapsed    = 0;
    _progressTicker = Timer.periodic(const Duration(milliseconds: 50), (t) {
      if (!mounted) { t.cancel(); return; }
      elapsed += 50;
      setState(() => _holdProgress = (elapsed / 1500).clamp(0.0, 1.0));
      if (elapsed >= 1500) { t.cancel(); _doCapture(); }
    });
  }

  void _cancelHold() {
    _progressTicker?.cancel();
    _progressTicker = null;
    _autoCapturing  = false;
    if (mounted) setState(() => _holdProgress = 0.0);
  }

  Future<void> _doCapture() async {
    if (_camCtrl == null) { _autoCapturing = false; return; }
    try {
      await _camCtrl!.stopImageStream();
      final xFile = await _camCtrl!.takePicture();
      final bytes = await xFile.readAsBytes();
      final imageBase64 = base64Encode(bytes);

      setState(() {
        _faceDone      = true;
        _autoCapturing = false;
        _overlayState  = FaceOverlayState.successCheckin;
      });

      // Auto-submit face for verification
      await _submitFace(imageBase64);
    } catch (e) {
      _autoCapturing = false;
      if (mounted) {
        setState(() { _faceDone = false; _faceError = 'Capture failed: $e'; });
        _startStream();
      }
    }
  }

  Future<void> _submitFace(String imageBase64) async {
    if (_sessionToken == null || !mounted) return;
    setState(() { _submittingFace = true; _faceError = null; });

    try {
      final data = await ParentApiService.verifyFace(
        sessionToken:    _sessionToken!,
        faceImageBase64: imageBase64,
      );

      final auth = context.read<ParentAuthProvider>();
      await auth.completeLogin(
        token:       data['token']   as String,
        studentData: data['student'] as Map<String, dynamic>,
        academyData: data['academy'] as Map<String, dynamic>,
      );

      // Upload FCM token in background
      FcmService.uploadTokenIfParent();

      if (mounted) {
        Navigator.of(context)
            .pushNamedAndRemoveUntil('/parent/dashboard', (_) => false);
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        setState(() {
          _submittingFace = false;
          _faceDone       = false;
          _faceError      = msg;
          _overlayState   = FaceOverlayState.idle;
          _holdProgress   = 0;
          _qualityScore   = 0;
        });
        _startStream(); // let user retry
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back), onPressed: _goBack),
        title: Text(_step == 0 ? 'Parent Login' : 'Face Verification'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: (_step + 1) / 2,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ),
      body: PageView(
        controller: _pageCtrl,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _buildCredentialsStep(theme),
          _buildFaceStep(theme),
        ],
      ),
    );
  }

  // ── Step 0: Credentials ────────────────────────────────────────────────────

  Widget _buildCredentialsStep(ThemeData theme) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).padding.bottom + 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Icon
            Center(
              child: Container(
                width: 80, height: 80,
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.family_restroom,
                    size: 44, color: Colors.green),
              ),
            ),
            const SizedBox(height: 16),
            Text('Parent / Guardian',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('Enter your details to begin',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 32),

            // Academy Code
            TextFormField(
              controller: _slugCtrl,
              decoration: const InputDecoration(
                labelText: 'Academy Code',
                hintText:  'e.g. sunshine_tuition',
                prefixIcon: Icon(Icons.school_outlined),
                helperText: 'Provided by your academy admin',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.none,
              autocorrect: false,
              keyboardType: TextInputType.text,
              inputFormatters: [_AcademyCodeFormatter()],
              textInputAction: TextInputAction.next,
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Academy code is required' : null,
            ),
            const SizedBox(height: 16),

            // Student ID
            TextFormField(
              controller: _idCtrl,
              decoration: const InputDecoration(
                labelText: 'Student ID',
                hintText:  'e.g. ACF-2026-00001',
                prefixIcon: Icon(Icons.badge_outlined),
                helperText: 'Found on your enrollment receipt',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Student ID is required' : null,
            ),
            const SizedBox(height: 16),

            // Parent Mobile
            TextFormField(
              controller: _mobileCtrl,
              keyboardType: TextInputType.phone,
              maxLength: 10,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Parent Mobile Number',
                hintText:  '10-digit mobile number',
                prefixIcon: Icon(Icons.phone_outlined),
                helperText: 'The number registered with the academy',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _goToFaceScan(),
              validator: (v) => v == null || v.trim().length != 10
                  ? 'Enter a valid 10-digit mobile number'
                  : null,
            ),
            const SizedBox(height: 32),

            FilledButton.icon(
              onPressed: _verifying ? null : _goToFaceScan,
              icon: _verifying
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.arrow_forward),
              label: Text(_verifying ? 'Verifying...' : 'Continue to Face Scan'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                backgroundColor: Colors.green,
              ),
            ),
            const SizedBox(height: 24),

            // Help card
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.info_outline, size: 16,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Text('Where do I find these?',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13,
                            color: theme.colorScheme.primary)),
                  ]),
                  const SizedBox(height: 8),
                  _infoRow('Academy Code',
                      'Shared by your academy admin (printed on fee receipt)'),
                  _infoRow('Student ID',
                      'On enrollment receipt (e.g. ACF-2026-00001)'),
                  _infoRow('Mobile Number',
                      'Parent number given at the time of enrollment'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String detail) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('• ', style: TextStyle(fontSize: 12)),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                  children: [
                    TextSpan(text: '$label: ',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(text: detail),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  // ── Step 1: Face scan ──────────────────────────────────────────────────────

  Widget _buildFaceStep(ThemeData theme) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).padding.bottom + 16),
      child: Column(
        children: [
          // Student name confirmation banner
          if (_studentName != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline,
                      color: Colors.green, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Credentials verified for $_studentName · $_academyName',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w500,
                          color: Colors.green),
                    ),
                  ),
                ],
              ),
            ),

          // Camera
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: _camReady && _camCtrl != null
                  ? Stack(fit: StackFit.expand, children: [
                      CameraPreview(_camCtrl!),
                      CustomPaint(
                          painter: FaceOverlayPainter(
                              state: _overlayState,
                              holdProgress: _holdProgress)),
                      // Status overlay at bottom of camera
                      Positioned(
                        bottom: 12, left: 0, right: 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              _submittingFace
                                  ? 'Verifying your identity...'
                                  : _faceDone
                                      ? 'Face captured!'
                                      : _autoCapturing
                                          ? 'Hold still...'
                                          : _qualityHint.isNotEmpty
                                              ? _qualityHint
                                              : 'Position your face in the oval',
                              style: TextStyle(
                                color: _overlayState == FaceOverlayState.successCheckin
                                    ? Colors.greenAccent
                                    : Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ])
                  : Container(
                      color: Colors.black87,
                      child: const Center(
                          child: CircularProgressIndicator(color: Colors.white))),
            ),
          ),
          const SizedBox(height: 12),

          // Error message
          if (_faceError != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red.shade700, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_faceError!,
                        style: TextStyle(
                            fontSize: 13, color: Colors.red.shade700)),
                  ),
                ],
              ),
            ),

          // Quality indicator
          if (_qualityScore > 0 && !_submittingFace)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                const Text('Face quality: ',
                    style: TextStyle(fontSize: 12)),
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
              ]),
            ),

          // Submitting indicator
          if (_submittingFace) ...[
            const SizedBox(height: 8),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('Verifying your identity with InsightFace...',
                    style: TextStyle(fontSize: 13)),
              ],
            ),
            const SizedBox(height: 8),
          ],

          // Instructions
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.face_outlined, size: 16,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Look straight at the camera — it will scan automatically',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Allows only a–z, A–Z, and underscore.
/// Spaces are automatically converted to underscores; all other characters
/// (digits, punctuation, etc.) are silently dropped.
class _AcademyCodeFormatter extends TextInputFormatter {
  static final _invalid = RegExp(r'[^a-zA-Z_]');

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final filtered = newValue.text
        .replaceAll(' ', '_')
        .replaceAll(_invalid, '');
    return TextEditingValue(
      text: filtered,
      selection: TextSelection.collapsed(offset: filtered.length),
    );
  }
}
