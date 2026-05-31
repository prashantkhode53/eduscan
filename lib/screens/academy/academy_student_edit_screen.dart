import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';
import '../../services/face_service.dart';
import '../../widgets/face_overlay_painter.dart';
import '../../widgets/academy_course_selector.dart';

/// 3-step wizard: (0) Personal Info  (1) Courses  (2) Face update.
/// Returns true via Navigator.pop when the student is successfully updated.
class AcademyStudentEditScreen extends StatefulWidget {
  final String studentId;
  final String studentName;

  const AcademyStudentEditScreen({
    super.key,
    required this.studentId,
    required this.studentName,
  });

  @override
  State<AcademyStudentEditScreen> createState() =>
      _AcademyStudentEditScreenState();
}

class _AcademyStudentEditScreenState
    extends State<AcademyStudentEditScreen> {
  final _pageCtrl = PageController();
  int _step = 0;

  // ── Initial data load ──────────────────────────────────────────────────────
  bool _initialLoading = true;
  String? _loadError;

  // ── Step 0: Personal Info ──────────────────────────────────────────────────
  final _s0Key          = GlobalKey<FormState>();
  final _firstNameCtrl  = TextEditingController();
  final _lastNameCtrl   = TextEditingController();
  final _mobileCtrl     = TextEditingController();
  final _emailCtrl      = TextEditingController();
  final _dobCtrl        = TextEditingController();
  final _parentNameCtrl = TextEditingController();
  final _parentMobCtrl  = TextEditingController();
  final _addressCtrl    = TextEditingController();
  String? _gender;

  // ── Step 1: Courses ────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _availableCourses = [];
  final Map<String, double> _selectedFees = {};
  bool _loadingCourses = false;
  String? _courseError;

  // ── Step 2: Face ───────────────────────────────────────────────────────────
  bool _hasFaceData   = false;
  bool _isRescanning  = false;

  CameraController? _camCtrl;
  CameraDescription? _frontCam;
  bool _camReady        = false;
  bool _processingFrame = false;
  bool _autoCapturing   = false;
  bool _faceDone        = false;
  double _holdProgress  = 0.0;
  double _qualityScore  = 0.0;
  String _qualityHint   = '';
  FaceOverlayState _overlayState = FaceOverlayState.idle;
  final List<String> _faceImages = [];
  static const int _requiredSamples = 5;
  int _captureCount = 0;
  Timer? _progressTicker;

  // ── Submit ─────────────────────────────────────────────────────────────────
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    if (!mounted) return;
    setState(() { _initialLoading = true; _loadError = null; });
    try {
      final results = await Future.wait([
        AcademyApiService.getStudentById(widget.studentId),
        AcademyApiService.getCourses(),
      ]);

      final studentData = results[0] as Map<String, dynamic>;
      final courses     = (results[1] as List).cast<Map<String, dynamic>>();

      // Pre-populate personal info
      _firstNameCtrl.text  = studentData['first_name']   as String? ?? '';
      _lastNameCtrl.text   = studentData['last_name']    as String? ?? '';
      _mobileCtrl.text     = studentData['mobile']       as String? ?? '';
      _emailCtrl.text      = studentData['email']        as String? ?? '';
      _parentNameCtrl.text = studentData['parent_name']  as String? ?? '';
      _parentMobCtrl.text  = studentData['parent_mobile'] as String? ?? '';
      _addressCtrl.text    = studentData['address']      as String? ?? '';
      // DOB: strip ISO timestamp → YYYY-MM-DD
      final rawDob = studentData['dob']?.toString() ?? '';
      _dobCtrl.text = rawDob.contains('T') ? rawDob.split('T')[0] : rawDob;
      _gender = studentData['gender'] as String?;

      // Pre-populate courses from active enrolments
      final enrollments = (studentData['courses'] as List? ?? [])
          .cast<Map<String, dynamic>>()
          .where((c) => c['status'] == 'active')
          .toList();

      final fees = <String, double>{};
      for (final e in enrollments) {
        final id  = e['course_id'] as String?;
        final fee = double.tryParse(e['fee_amount']?.toString() ?? '');
        if (id != null && fee != null) fees[id] = fee;
      }

      final embedding = studentData['face_embedding'];
      final hasFace   = embedding is List && embedding.isNotEmpty;

      if (!mounted) return;
      setState(() {
        _availableCourses = courses;
        _selectedFees
          ..clear()
          ..addAll(fees);
        _hasFaceData    = hasFace;
        _initialLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError      = e.toString().replaceFirst('Exception: ', '');
        _initialLoading = false;
      });
    }
  }

  Future<void> _reloadCourses() async {
    if (!mounted) return;
    setState(() { _loadingCourses = true; _courseError = null; });
    try {
      final data = await AcademyApiService.getCourses();
      if (!mounted) return;
      setState(() {
        _availableCourses = data.cast<Map<String, dynamic>>();
        _loadingCourses   = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _courseError    = e.toString().replaceFirst('Exception: ', '');
        _loadingCourses = false;
      });
    }
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _firstNameCtrl.dispose(); _lastNameCtrl.dispose();
    _mobileCtrl.dispose();    _emailCtrl.dispose();
    _dobCtrl.dispose();
    _parentNameCtrl.dispose(); _parentMobCtrl.dispose();
    _addressCtrl.dispose();
    _progressTicker?.cancel();
    _camCtrl?.dispose();
    super.dispose();
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _goNext() {
    if (_step == 0) {
      if (!(_s0Key.currentState?.validate() ?? false)) return;
    }
    if (_step == 1 && _selectedFees.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one course')),
      );
      return;
    }
    setState(() => _step++);
    _pageCtrl.animateToPage(_step,
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    // Auto-start camera only on face step when student has no face data yet
    if (_step == 2 && !_hasFaceData) _initCamera();
  }

  void _goBack() {
    if (_step == 0) { Navigator.pop(context); return; }
    if (_step == 2) _disposeCamera();
    setState(() {
      _step--;
      if (_step < 2) {
        _isRescanning = false;
        _faceImages.clear();
        _captureCount = 0;
        _faceDone     = false;
        _overlayState = FaceOverlayState.idle;
        _qualityScore = 0;
        _holdProgress = 0;
      }
    });
    _pageCtrl.animateToPage(_step,
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _disposeCamera() {
    _progressTicker?.cancel();
    _progressTicker  = null;
    _camCtrl?.dispose();
    _camCtrl         = null;
    _camReady        = false;
    _autoCapturing   = false;
    _processingFrame = false;
  }

  double _computeQuality(dynamic face) {
    final yaw   = (face.headEulerAngleY as double? ?? 0).abs();
    final roll  = (face.headEulerAngleZ as double? ?? 0).abs();
    final pitch = (face.headEulerAngleX as double? ?? 0).abs();

    if (yaw > 25)  { _qualityHint = 'Look straight ahead'; return 0.0; }
    if (roll > 20) { _qualityHint = 'Hold your head level'; return 0.0; }
    if (pitch > 20){ _qualityHint = 'Look directly at camera'; return 0.0; }

    final sizeScore =
        (((face.boundingBox.width as num).toDouble() - 80) / 120)
            .clamp(0.0, 1.0);
    if (sizeScore < 0.05) { _qualityHint = 'Move closer to camera'; return 0.0; }

    final eyeScore =
        ((face.leftEyeOpenProbability  as double? ?? 1.0) +
         (face.rightEyeOpenProbability as double? ?? 1.0)) / 2.0;

    final score = (sizeScore * 0.35 +
        (1 - yaw / 25)   * 0.25 +
        (1 - roll / 20)  * 0.15 +
        (1 - pitch / 20) * 0.15 +
        eyeScore         * 0.10)
        .clamp(0.0, 1.0);

    _qualityHint = score < 0.55
        ? (sizeScore < 0.3 ? 'Move closer to camera' : 'Face the camera directly')
        : '';
    return score;
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
          setState(() { _overlayState = FaceOverlayState.idle; _qualityScore = 0; _qualityHint = ''; });
          _cancelHold();
          return;
        }

        final quality = _computeQuality(faces.first);
        setState(() {
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

  void _startHold() {
    if (_autoCapturing) return;
    _autoCapturing = true;
    _holdProgress  = 0.0;
    const holdMs   = 1500;
    const tickMs   = 50;
    int elapsed    = 0;
    _progressTicker = Timer.periodic(const Duration(milliseconds: tickMs), (t) {
      if (!mounted) { t.cancel(); return; }
      elapsed += tickMs;
      setState(() => _holdProgress = (elapsed / holdMs).clamp(0.0, 1.0));
      if (elapsed >= holdMs) { t.cancel(); _doCapture(); }
    });
  }

  void _cancelHold() {
    _progressTicker?.cancel();
    _progressTicker = null;
    _autoCapturing  = false;
    if (mounted) setState(() => _holdProgress = 0.0);
  }

  Future<void> _doCapture() async {
    if (_camCtrl == null || _faceDone) { _autoCapturing = false; return; }
    try {
      await _camCtrl!.stopImageStream();
      final xFile = await _camCtrl!.takePicture();
      final bytes = await xFile.readAsBytes();
      _faceImages.add(base64Encode(bytes));
      _captureCount++;
      _holdProgress = 0.0;
      if (_captureCount >= _requiredSamples) {
        _faceDone      = true;
        _autoCapturing = false;
        setState(() => _overlayState = FaceOverlayState.successCheckin);
      } else {
        _autoCapturing = false;
        setState(() {});
        _startStream();
      }
    } catch (_) {
      _autoCapturing = false;
      if (mounted) _startStream();
    }
  }

  // ── Submit ─────────────────────────────────────────────────────────────────

  Future<void> _submit({bool withNewFace = false}) async {
    setState(() => _submitting = true);
    try {
      final courses = _selectedFees.entries
          .map((e) => {'course_id': e.key, 'fee_amount': e.value})
          .toList();

      final body = <String, dynamic>{
        'first_name':    _firstNameCtrl.text.trim(),
        'last_name':     _lastNameCtrl.text.trim(),
        'mobile':        _mobileCtrl.text.trim(),
        'email':         _emailCtrl.text.trim().isNotEmpty ? _emailCtrl.text.trim() : null,
        'dob':           _dobCtrl.text.isNotEmpty ? _dobCtrl.text : null,
        'gender':        _gender,
        'parent_name':   _parentNameCtrl.text.trim().isNotEmpty ? _parentNameCtrl.text.trim() : null,
        'parent_mobile': _parentMobCtrl.text.trim().isNotEmpty  ? _parentMobCtrl.text.trim()  : null,
        'address':       _addressCtrl.text.trim().isNotEmpty    ? _addressCtrl.text.trim()    : null,
        'courses':       courses,
      };
      if (withNewFace && _faceImages.isNotEmpty) {
        body['face_images'] = _faceImages;
      }

      await AcademyApiService.updateStudent(widget.studentId, body);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Student updated successfully'),
              backgroundColor: Colors.green),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
        );
        setState(() => _submitting = false);
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const steps = ['Personal Info', 'Update Courses', 'Update Face'];

    if (_initialLoading) {
      return Scaffold(
        appBar: AppBar(title: Text('Edit ${widget.studentName}')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: Text('Edit ${widget.studentName}')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_outlined, size: 56, color: theme.colorScheme.error),
                const SizedBox(height: 12),
                Text('Failed to load student data',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(_loadError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                const SizedBox(height: 20),
                FilledButton.icon(
                    onPressed: _loadAll,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry')),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back), onPressed: _goBack),
        title: Text(steps[_step]),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: (_step + 1) / steps.length,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ),
      body: PageView(
        controller: _pageCtrl,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          // ── Step 0: Personal Info ──────────────────────────────────────────
          _buildPersonalInfoStep(theme),

          // ── Step 1: Courses ────────────────────────────────────────────────
          AcademyCourseSelector(
            loading: _loadingCourses,
            error: _courseError,
            courses: _availableCourses,
            selectedFees: _selectedFees,
            onToggle: (courseId, defaultFee, selected) {
              setState(() {
                if (selected) {
                  _selectedFees[courseId] = defaultFee;
                } else {
                  _selectedFees.remove(courseId);
                }
              });
            },
            onFeeChanged: (courseId, fee) =>
                setState(() => _selectedFees[courseId] = fee),
            onNext: _goNext,
            onRetry: _reloadCourses,
            nextLabel: 'Continue to Face Update',
          ),

          // ── Step 2: Face ───────────────────────────────────────────────────
          _FaceStep(
            hasFaceData: _hasFaceData,
            isRescanning: _isRescanning,
            onStartRescan: () {
              setState(() {
                _isRescanning = true;
                _faceImages.clear();
                _captureCount = 0;
                _faceDone     = false;
                _overlayState = FaceOverlayState.idle;
                _qualityScore = 0;
                _holdProgress = 0;
              });
              _initCamera();
            },
            onKeepFace: _submitting ? null : () => _submit(withNewFace: false),
            camCtrl:        _camCtrl,
            camReady:       _camReady,
            overlayState:   _overlayState,
            holdProgress:   _holdProgress,
            qualityScore:   _qualityScore,
            qualityHint:    _qualityHint,
            captureCount:   _captureCount,
            requiredSamples: _requiredSamples,
            done:          _faceDone,
            submitting:    _submitting,
            autoCapturing: _autoCapturing,
            onCaptureNow: () {
              _cancelHold();
              _autoCapturing = true;
              _doCapture();
            },
            onSubmitWithFace: () => _submit(withNewFace: true),
            onReset: () {
              setState(() {
                _faceImages.clear();
                _captureCount = 0;
                _faceDone     = false;
                _overlayState = FaceOverlayState.idle;
              });
              _startStream();
            },
          ),
        ],
      ),
    );
  }

  // ── Step 0 widget ──────────────────────────────────────────────────────────

  Widget _buildPersonalInfoStep(ThemeData theme) {
    return Form(
      key: _s0Key,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            24, 16, 24, MediaQuery.of(context).padding.bottom + 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Read-only student ID
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                children: [
                  Icon(Icons.badge_outlined, size: 16,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('Student ID',
                      style: TextStyle(fontSize: 12,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6))),
                  const Spacer(),
                  Text(widget.studentId,
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                ],
              ),
            ),
            const SizedBox(height: 16),

            Row(children: [
              Expanded(child: _tf(_firstNameCtrl, 'First Name *',
                  v: (v) => v!.trim().isEmpty ? 'Required' : null)),
              const SizedBox(width: 12),
              Expanded(child: _tf(_lastNameCtrl, 'Last Name *',
                  v: (v) => v!.trim().isEmpty ? 'Required' : null)),
            ]),
            const SizedBox(height: 12),

            _tf(_mobileCtrl, 'Mobile *',
                type: TextInputType.phone,
                v: (v) => v!.trim().length < 10 ? 'Enter valid mobile number' : null),
            const SizedBox(height: 12),

            _tf(_emailCtrl, 'Email (optional)', type: TextInputType.emailAddress),
            const SizedBox(height: 12),

            DropdownButtonFormField<String>(
              value: _gender,
              decoration: const InputDecoration(
                  labelText: 'Gender', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'male',   child: Text('Male')),
                DropdownMenuItem(value: 'female', child: Text('Female')),
                DropdownMenuItem(value: 'other',  child: Text('Other')),
              ],
              onChanged: (v) => setState(() => _gender = v),
            ),
            const SizedBox(height: 12),

            TextFormField(
              controller: _dobCtrl,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Date of Birth',
                prefixIcon: Icon(Icons.calendar_today),
                border: OutlineInputBorder(),
              ),
              onTap: () async {
                DateTime initial = DateTime(2005);
                if (_dobCtrl.text.isNotEmpty) {
                  try { initial = DateTime.parse(_dobCtrl.text); } catch (_) {}
                }
                final d = await showDatePicker(
                  context: context,
                  initialDate: initial,
                  firstDate: DateTime(1990),
                  lastDate: DateTime.now(),
                );
                if (d != null) {
                  setState(() =>
                      _dobCtrl.text = d.toIso8601String().split('T')[0]);
                }
              },
            ),
            const SizedBox(height: 12),

            _tf(_parentNameCtrl, 'Parent / Guardian Name'),
            const SizedBox(height: 12),

            _tf(_parentMobCtrl, 'Parent Mobile', type: TextInputType.phone),
            const SizedBox(height: 12),

            TextFormField(
              controller: _addressCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'Address', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 24),

            FilledButton(
              onPressed: _goNext,
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
              child: const Text('Next'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tf(
    TextEditingController ctrl,
    String label, {
    TextInputType type = TextInputType.text,
    String? Function(String?)? v,
  }) =>
      TextFormField(
        controller: ctrl,
        keyboardType: type,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
        validator: v,
      );
}

// ── Face step widget ──────────────────────────────────────────────────────────

class _FaceStep extends StatelessWidget {
  final bool hasFaceData;
  final bool isRescanning;
  final VoidCallback onStartRescan;
  final VoidCallback? onKeepFace;

  final CameraController? camCtrl;
  final bool camReady, done, submitting, autoCapturing;
  final FaceOverlayState overlayState;
  final double holdProgress, qualityScore;
  final String qualityHint;
  final int captureCount, requiredSamples;
  final VoidCallback onCaptureNow, onSubmitWithFace, onReset;

  const _FaceStep({
    required this.hasFaceData,
    required this.isRescanning,
    required this.onStartRescan,
    this.onKeepFace,
    required this.camCtrl,
    required this.camReady,
    required this.overlayState,
    required this.holdProgress,
    required this.qualityScore,
    required this.qualityHint,
    required this.captureCount,
    required this.requiredSamples,
    required this.done,
    required this.submitting,
    required this.autoCapturing,
    required this.onCaptureNow,
    required this.onSubmitWithFace,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    if (hasFaceData && !isRescanning) return _buildKeepOrRescan(context);
    return _buildCameraCapture(context);
  }

  Widget _buildKeepOrRescan(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 40, 24, MediaQuery.of(context).padding.bottom + 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.green.withValues(alpha: 0.12),
            ),
            child: const Icon(Icons.face_retouching_natural,
                size: 44, color: Colors.green),
          ),
          const SizedBox(height: 20),
          Text('Face Already Registered',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            "This student's face is on record. Keep it, or capture new photos to update it.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
          ),
          const SizedBox(height: 40),
          FilledButton.icon(
            onPressed: onKeepFace,
            icon: submitting
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.check_circle_outline),
            label: Text(submitting ? 'Saving…' : 'Keep Current Face & Save'),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50)),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: submitting ? null : onStartRescan,
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Re-scan Face'),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(50)),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraCapture(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).padding.bottom + 16),
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: camReady && camCtrl != null
                  ? Stack(fit: StackFit.expand, children: [
                      CameraPreview(camCtrl!),
                      CustomPaint(
                          painter: FaceOverlayPainter(
                              state: overlayState,
                              holdProgress: holdProgress)),
                    ])
                  : Container(
                      color: Colors.black87,
                      child: const Center(
                          child: CircularProgressIndicator(color: Colors.white))),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            done
                ? 'All $requiredSamples photos captured!'
                : autoCapturing
                    ? 'Hold still — capturing ${captureCount + 1} of $requiredSamples…'
                    : qualityScore >= 0.55
                        ? 'Hold still — auto-capturing…'
                        : qualityHint.isNotEmpty
                            ? qualityHint
                            : 'Position your face in the oval',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: done
                  ? Colors.green
                  : qualityScore >= 0.55
                      ? theme.colorScheme.primary
                      : Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 8),
          if (qualityScore > 0)
            Row(children: [
              const Text('Quality: ', style: TextStyle(fontSize: 12)),
              Expanded(
                child: LinearProgressIndicator(
                  value: qualityScore,
                  color: qualityScore >= 0.55 ? Colors.green : Colors.orange,
                  backgroundColor: Colors.grey.shade200,
                ),
              ),
              const SizedBox(width: 8),
              Text('${(qualityScore * 100).toInt()}%',
                  style: const TextStyle(fontSize: 12)),
            ]),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(requiredSamples, (i) {
              final captured = i < captureCount;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                margin: const EdgeInsets.symmetric(horizontal: 5),
                width: captured ? 20 : 13,
                height: captured ? 20 : 13,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: captured ? Colors.green : Colors.grey.shade300,
                ),
                child: captured
                    ? const Icon(Icons.check, size: 12, color: Colors.white)
                    : null,
              );
            }),
          ),
          const SizedBox(height: 16),
          if (done) ...[
            FilledButton.icon(
              onPressed: submitting ? null : onSubmitWithFace,
              icon: submitting
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_circle_outline),
              label: Text(submitting ? 'Saving…' : 'Save with New Face'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: onReset, child: const Text('Retake Photos')),
          ] else
            OutlinedButton.icon(
              onPressed: (!autoCapturing && qualityScore > 0) ? onCaptureNow : null,
              icon: const Icon(Icons.camera_alt_outlined),
              label: Text(autoCapturing ? 'Capturing…' : 'Capture Now'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
            ),
        ],
      ),
    );
  }
}
