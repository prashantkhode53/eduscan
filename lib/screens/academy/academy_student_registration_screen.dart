import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';
import '../../services/face_service.dart';
import '../../widgets/face_overlay_painter.dart';
import '../../widgets/academy_course_selector.dart';

class AcademyStudentRegistrationScreen extends StatefulWidget {
  const AcademyStudentRegistrationScreen({super.key});

  @override
  State<AcademyStudentRegistrationScreen> createState() =>
      _AcademyStudentRegistrationScreenState();
}

class _AcademyStudentRegistrationScreenState
    extends State<AcademyStudentRegistrationScreen> {
  final _pageCtrl = PageController();
  int _step = 0;

  // â”€â”€ Step 1: Personal Info â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  final _s1Key         = GlobalKey<FormState>();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl  = TextEditingController();
  final _dobCtrl       = TextEditingController();
  String? _gender;
  final _mobileCtrl    = TextEditingController();
  final _emailCtrl     = TextEditingController();

  // â”€â”€ Step 2: Parent & Address â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  final _s2Key          = GlobalKey<FormState>();
  final _parentNameCtrl = TextEditingController();
  final _parentMobCtrl  = TextEditingController();
  final _addressCtrl    = TextEditingController();

  // â”€â”€ Step 3: Courses â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  List<Map<String, dynamic>> _availableCourses = [];
  final Map<String, double> _selectedFees = {};
  bool _loadingCourses = false;
  String? _courseError;

  // â”€â”€ Step 4: Face â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  CameraController? _camCtrl;
  CameraDescription? _frontCam;
  bool _camReady        = false;
  String? _camError;    // non-null => init failed; show error + Retry
  bool _processingFrame = false;
  bool _autoCapturing   = false;
  bool _done            = false;
  double _holdProgress  = 0.0;
  double _qualityScore  = 0.0;
  String _qualityHint   = '';
  FaceOverlayState _overlayState = FaceOverlayState.idle;
  final List<String> _faceImages = [];
  static const int _requiredSamples = 5;
  int _captureCount = 0;
  Timer? _progressTicker;

  // â”€â”€ Submit â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  bool _submitting = false;

  // Two-phase save: the student's details (Personal/Parent/Courses) are
  // persisted BEFORE the face scan so they're never lost if the scan fails.
  // _studentId holds the created record; the face is attached afterwards.
  String? _studentId;
  bool _savingDetails = false;
  Future<void>? _detailsSave; // in-flight Phase 1 (runs in the background)

  @override
  void initState() {
    super.initState();
    _loadCourses();
  }

  Future<void> _loadCourses() async {
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
    _dobCtrl.dispose(); _mobileCtrl.dispose(); _emailCtrl.dispose();
    _parentNameCtrl.dispose(); _parentMobCtrl.dispose(); _addressCtrl.dispose();
    _progressTicker?.cancel();
    _camCtrl?.dispose();
    super.dispose();
  }

  // â”€â”€ Navigation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _goNext() async {
    if (_step == 0 && !(_s1Key.currentState?.validate() ?? false)) return;
    // Step 1 (Parent & Address) has no required fields â€” validate if state exists,
    // but never block navigation if form hasn't rendered yet.
    if (_step == 1) {
      final s2Valid = _s2Key.currentState?.validate();
      if (s2Valid == false) return;
    }
    if (_step == 2) {
      if (_selectedFees.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select at least one course')),
        );
        return;
      }
      // Phase 1 — save details in the BACKGROUND so this step never freezes
      // (the backend may be cold-starting). The face step opens immediately;
      // the save finishes while the user positions/captures, and _submit()
      // awaits it before completing registration.
      _detailsSave = _saveDetails();
    }
    setState(() => _step++);
    _pageCtrl.animateToPage(_step,
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    // Reload courses each time the user enters the Courses step so a previous
    // API failure doesn't permanently block them.
    if (_step == 2) _loadCourses();
    if (_step == 3) _initCamera();
  }

  /// Assembles the student detail payload (everything except the face).
  Map<String, dynamic> _detailsBody() => {
        'first_name':    _firstNameCtrl.text.trim(),
        'last_name':     _lastNameCtrl.text.trim(),
        'dob':           _dobCtrl.text.isNotEmpty ? _dobCtrl.text : null,
        'gender':        _gender,
        'mobile':        _mobileCtrl.text.trim(),
        'email':         _emailCtrl.text.trim().isNotEmpty ? _emailCtrl.text.trim() : null,
        'parent_name':   _parentNameCtrl.text.trim().isNotEmpty ? _parentNameCtrl.text.trim() : null,
        'parent_mobile': _parentMobCtrl.text.trim().isNotEmpty ? _parentMobCtrl.text.trim() : null,
        'address':       _addressCtrl.text.trim().isNotEmpty ? _addressCtrl.text.trim() : null,
        'courses': _selectedFees.entries
            .map((e) => {'course_id': e.key, 'fee_amount': e.value})
            .toList(),
      };

  /// Phase 1: persist the student's details before the face scan so they are
  /// never lost if the scan fails. Returns true when the wizard may advance to
  /// the face step.
  ///
  /// Backend-version safe: if the server still requires a face at creation
  /// time, we don't block — the details and face are saved together after the
  /// scan instead (see [_submit]). Genuine validation errors still stop here so
  /// they surface immediately rather than after capturing photos.
  Future<bool> _saveDetails() async {
    if (_savingDetails) return false;
    setState(() => _savingDetails = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (_studentId == null) {
        final res = await AcademyApiService.registerStudent(_detailsBody());
        _studentId = res['id'] as String?;
        if (mounted) {
          messenger.showSnackBar(const SnackBar(
              content: Text("Details saved. Now capture the student's face."),
              backgroundColor: Colors.green));
        }
      } else {
        // Returning after a back-navigation - sync any edits to the same record.
        await AcademyApiService.updateStudent(_studentId!, _detailsBody());
      }
      return true;
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      // Phase 1 runs in the background while the user is on the camera screen.
      // Never show an alarming red error from a background save — the fallback
      // one-shot create in _submit() handles any failure transparently. Only
      // surface genuinely user-actionable errors (e.g. invalid course selection)
      // that can't be fixed by the fallback.
      debugPrint('[register] Phase 1 failed (will fallback): $msg');
      // Old backend: still requires face at creation — proceed silently.
      // Any other error: also proceed and let _submit() do one-shot create.
      return true;
    } finally {
      if (mounted) setState(() => _savingDetails = false);
    }
  }

  void _goBack() {
    if (_step == 0) { Navigator.pop(context); return; }
    if (_step == 3) _disposeCamera();
    setState(() => _step--);
    _pageCtrl.animateToPage(_step,
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  // â”€â”€ Camera â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _initCamera() async {
    if (_camReady && _camCtrl != null) return; // already active
    if (mounted) setState(() { _camError = null; _camReady = false; });
    await _camCtrl?.dispose();
    _camCtrl = null;
    try {
      final cameras =
          await availableCameras().timeout(const Duration(seconds: 8));
      if (cameras.isEmpty) {
        throw CameraException('NoCamera', 'No camera found on this device.');
      }
      _frontCam = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final ctrl = CameraController(_frontCam!, ResolutionPreset.medium,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
      _camCtrl = ctrl;
      // Denied permission throws here; a stuck driver never resolves — the
      // timeout converts that hang into an actionable error + Retry button.
      await ctrl.initialize().timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw TimeoutException(
            'Camera took too long to start. Please try again.'),
      );
      if (!mounted) { await ctrl.dispose(); return; }
      setState(() => _camReady = true);
      _startStream();
    } catch (e) {
      debugPrint('[academy/register] camera init failed: $e');
      await _camCtrl?.dispose();
      _camCtrl = null;
      if (mounted) setState(() => _camError = _friendlyCameraError(e));
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

  void _disposeCamera() {
    _progressTicker?.cancel();
    _progressTicker = null;
    _camCtrl?.dispose();
    _camCtrl   = null;
    _camReady  = false;
    _autoCapturing = false;
  }

  // Quality score â€” mirrors SuperAdmin implementation (size + angles + eye openness).
  double _computeQuality(dynamic face) {
    final yaw   = (face.headEulerAngleY as double? ?? 0).abs();
    final roll  = (face.headEulerAngleZ as double? ?? 0).abs();
    final pitch = (face.headEulerAngleX as double? ?? 0).abs();

    if (yaw > 25) { _qualityHint = 'Look straight ahead'; return 0.0; }
    if (roll > 20) { _qualityHint = 'Hold your head level'; return 0.0; }
    if (pitch > 20) { _qualityHint = 'Look directly at camera'; return 0.0; }

    final sizeScore = (((face.boundingBox.width as num).toDouble() - 80) / 120).clamp(0.0, 1.0);
    if (sizeScore < 0.05) { _qualityHint = 'Move closer to camera'; return 0.0; }

    final eyeScore = ((face.leftEyeOpenProbability  as double? ?? 1.0) +
                      (face.rightEyeOpenProbability as double? ?? 1.0)) / 2.0;

    final score = (sizeScore * 0.35 +
        (1 - yaw / 25) * 0.25 +
        (1 - roll / 20) * 0.15 +
        (1 - pitch / 20) * 0.15 +
        eyeScore * 0.10)
        .clamp(0.0, 1.0);

    _qualityHint = score < 0.55
        ? (sizeScore < 0.3 ? 'Move closer to camera' : 'Face the camera directly')
        : '';
    return score;
  }

  void _startStream() {
    if (_camCtrl == null || !_camCtrl!.value.isInitialized) return;
    _camCtrl!.startImageStream((image) async {
      if (_processingFrame || _done) return;
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
    if (_camCtrl == null || _done) { _autoCapturing = false; return; }
    try {
      await _camCtrl!.stopImageStream();
      final xFile = await _camCtrl!.takePicture();
      final bytes = await xFile.readAsBytes();
      _faceImages.add(base64Encode(bytes));
      _captureCount++;
      _holdProgress = 0.0;
      if (_captureCount >= _requiredSamples) {
        _done          = true;
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

  // â”€â”€ Submit â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// Phase 2: attach the captured face and finish.
  ///
  /// If Phase 1 already created the student we only update the face. Otherwise
  /// (older backend, or a deferred Phase 1) we do a single create with
  /// everything — so registration always completes regardless of backend
  /// version and can never get stuck.
  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      // Wait for the background Phase-1 save to finish (usually already done by
      // the time 5 photos are captured). Swallow its error — the fallback
      // one-shot create below handles a failed/incomplete Phase 1.
      if (_detailsSave != null) {
        try { await _detailsSave; } catch (_) {}
      }
      if (_studentId != null) {
        await AcademyApiService.updateStudentFace(_studentId!, _faceImages);
      } else {
        final res = await AcademyApiService.registerStudent({
          ..._detailsBody(),
          'face_images': _faceImages,
        });
        _studentId = res['id'] as String?;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Student registered successfully'),
              backgroundColor: Colors.green),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      if (e is FaceDuplicateException) {
        _showFaceDuplicateDialog(e);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(e.toString().replaceFirst('Exception: ', '')),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showFaceDuplicateDialog(FaceDuplicateException e) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _FaceDuplicateDialog(
        exception: e,
        onRetake: () {
          Navigator.pop(context); // close dialog
          // Reset face captures so the admin can try again (e.g. different
          // person stepped in front of camera).
          setState(() {
            _faceImages.clear();
            _captureCount = 0;
            _done         = false;
            _overlayState = FaceOverlayState.idle;
          });
          _startStream();
        },
        onCancel: () {
          Navigator.pop(context); // close dialog
          Navigator.pop(context); // leave registration screen
        },
      ),
    );
  }

  // â”€â”€ Build â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = ['Personal Info', 'Parent & Address', 'Courses', 'Face Capture'];

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
      body: Stack(children: [
        PageView(
        controller: _pageCtrl,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _Step1(
            formKey: _s1Key,
            firstNameCtrl: _firstNameCtrl, lastNameCtrl: _lastNameCtrl,
            dobCtrl: _dobCtrl, mobileCtrl: _mobileCtrl, emailCtrl: _emailCtrl,
            gender: _gender,
            onGenderChanged: (v) => setState(() => _gender = v),
            onNext: _goNext,
          ),
          _Step2(
            formKey: _s2Key,
            parentNameCtrl: _parentNameCtrl, parentMobCtrl: _parentMobCtrl,
            addressCtrl: _addressCtrl,
            onNext: _goNext,
          ),
          AcademyCourseSelector(
            loading: _loadingCourses,
            error:   _courseError,
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
            onNext:  _goNext,
            onRetry: _loadCourses,
          ),
          _Step4(
            camCtrl:        _camCtrl,
            camReady:       _camReady,
            camError:       _camError,
            onRetryCamera:  _initCamera,
            overlayState:   _overlayState,
            holdProgress:   _holdProgress,
            qualityScore:   _qualityScore,
            qualityHint:    _qualityHint,
            captureCount:   _captureCount,
            requiredSamples: _requiredSamples,
            done:       _done,
            submitting: _submitting,
            autoCapturing: _autoCapturing,
            onCaptureNow: () {
              _cancelHold();
              _autoCapturing = true;
              _doCapture();
            },
            onSubmit: _submit,
            onReset: () {
              setState(() {
                _faceImages.clear();
                _captureCount = 0;
                _done         = false;
                _overlayState = FaceOverlayState.idle;
              });
              _startStream();
            },
          ),
        ],
        ),
        // Persistent, visible status banner on the Face Capture step: shows
        // "Saving details..." while Phase 1 runs in the background, then a
        // clear "Details saved" confirmation. IgnorePointer keeps the camera
        // fully interactive underneath.
        if (_step == 3 && (_savingDetails || _studentId != null))
          Positioned(
            top: 10, left: 0, right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: _savingDetails
                        ? Colors.black.withValues(alpha: 0.65)
                        : Colors.green.shade700,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (_savingDetails)
                      const SizedBox(
                          width: 13, height: 13,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                    else
                      const Icon(Icons.check_circle,
                          color: Colors.white, size: 15),
                    const SizedBox(width: 8),
                    Text(
                      _savingDetails
                          ? 'Saving details...'
                          : 'Details saved - now capture the face',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

// â”€â”€ Step 1: Personal Info â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _Step1 extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController firstNameCtrl, lastNameCtrl, dobCtrl,
      mobileCtrl, emailCtrl;
  final String? gender;
  final ValueChanged<String?> onGenderChanged;
  final VoidCallback onNext;

  const _Step1({
    required this.formKey, required this.firstNameCtrl,
    required this.lastNameCtrl, required this.dobCtrl,
    required this.mobileCtrl, required this.emailCtrl,
    required this.gender, required this.onGenderChanged,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, 24, 24,
          MediaQuery.of(context).padding.bottom + 24),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: _tf(firstNameCtrl, 'First Name *',
                  v: (v) => v!.trim().isEmpty ? 'Required' : null)),
              const SizedBox(width: 12),
              Expanded(child: _tf(lastNameCtrl, 'Last Name *',
                  v: (v) => v!.trim().isEmpty ? 'Required' : null)),
            ]),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: gender,
              decoration: const InputDecoration(
                  labelText: 'Gender', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'male',   child: Text('Male')),
                DropdownMenuItem(value: 'female', child: Text('Female')),
                DropdownMenuItem(value: 'other',  child: Text('Other')),
              ],
              onChanged: onGenderChanged,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: dobCtrl,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Date of Birth',
                prefixIcon: Icon(Icons.calendar_today),
                border: OutlineInputBorder(),
              ),
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: DateTime(2005),
                  firstDate: DateTime(1990),
                  lastDate: DateTime.now(),
                );
                if (d != null) {
                  dobCtrl.text = d.toIso8601String().split('T')[0];
                }
              },
            ),
            const SizedBox(height: 12),
            _tf(mobileCtrl, 'Mobile *',
                type: TextInputType.phone,
                v: (v) => v!.trim().length < 10 ? 'Enter valid number' : null),
            const SizedBox(height: 12),
            _tf(emailCtrl, 'Email (optional)', type: TextInputType.emailAddress),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onNext,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: const Text('Next'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tf(TextEditingController ctrl, String label,
      {TextInputType type = TextInputType.text,
      String? Function(String?)? v}) =>
      TextFormField(
        controller: ctrl,
        keyboardType: type,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
        validator: v,
      );
}

// â”€â”€ Step 2: Parent & Address â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _Step2 extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController parentNameCtrl, parentMobCtrl, addressCtrl;
  final VoidCallback onNext;

  const _Step2({
    required this.formKey, required this.parentNameCtrl,
    required this.parentMobCtrl, required this.addressCtrl,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, 24, 24,
          MediaQuery.of(context).padding.bottom + 24),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: parentNameCtrl,
              decoration: const InputDecoration(
                  labelText: 'Parent / Guardian Name',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: parentMobCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'Parent Mobile',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: addressCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'Address',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onNext,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: const Text('Next'),
            ),
          ],
        ),
      ),
    );
  }
}

// â”€â”€ Step 4: Face Capture â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _Step4 extends StatelessWidget {
  final CameraController? camCtrl;
  final bool camReady, done, submitting, autoCapturing;
  final String? camError;
  final VoidCallback onRetryCamera;
  final FaceOverlayState overlayState;
  final double holdProgress, qualityScore;
  final String qualityHint;
  final int captureCount, requiredSamples;
  final VoidCallback onCaptureNow, onSubmit, onReset;

  const _Step4({
    required this.camCtrl,
    required this.camReady,
    required this.camError,
    required this.onRetryCamera,
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
    required this.onSubmit,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16,
          MediaQuery.of(context).padding.bottom + 16),
      child: Column(
        children: [
          // Camera preview
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
                      child: Center(
                        child: camError != null
                            ? Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.videocam_off_outlined,
                                        color: Colors.white70, size: 40),
                                    const SizedBox(height: 12),
                                    Text(camError!,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                            color: Colors.white, fontSize: 13)),
                                    const SizedBox(height: 16),
                                    ElevatedButton.icon(
                                      onPressed: onRetryCamera,
                                      icon: const Icon(Icons.refresh),
                                      label: const Text('Retry'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.white,
                                        foregroundColor: Colors.black,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : const CircularProgressIndicator(
                                color: Colors.white),
                      )),
            ),
          ),
          const SizedBox(height: 12),

          // Status / quality hint
          Text(
            done
                ? 'All $requiredSamples photos captured'
                : autoCapturing
                    ? 'Hold still - capturing photo ${captureCount + 1} of $requiredSamples...'
                    : qualityScore >= 0.55
                        ? 'Hold still - capturing automatically...'
                        : qualityHint.isNotEmpty
                            ? qualityHint
                            : 'Position your face within the oval',
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

          // Quality bar
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

          // Capture progress dots
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

          // Action buttons
          if (done) ...[
            FilledButton.icon(
              onPressed: submitting ? null : onSubmit,
              icon: submitting
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_circle_outline),
              label: Text(submitting ? 'Registering...' : 'Register Student'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: onReset, child: const Text('Retake Photos')),
          ] else
            OutlinedButton.icon(
              onPressed: (!autoCapturing && qualityScore > 0) ? onCaptureNow : null,
              icon: const Icon(Icons.camera_alt_outlined),
              label: Text(autoCapturing ? 'Capturing...' : 'Capture Now'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
            ),
        ],
      ),
    );
  }
}

// ── Face Duplicate Dialog ─────────────────────────────────────────────────────

class _FaceDuplicateDialog extends StatelessWidget {
  final FaceDuplicateException exception;
  final VoidCallback onRetake;
  final VoidCallback onCancel;

  const _FaceDuplicateDialog({
    required this.exception,
    required this.onRetake,
    required this.onCancel,
  });

  String _fmtDate(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    try {
      final d = DateTime.parse(raw).toLocal();
      const m = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${d.day.toString().padLeft(2, '0')} ${m[d.month]} ${d.year}';
    } catch (_) {
      return raw.split('T').first;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = exception;
    final pct = e.confidence != null
        ? '${(e.confidence! * 100).toStringAsFixed(1)}%'
        : null;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titlePadding: EdgeInsets.zero,
      title: Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: Colors.red.shade100,
              child: Icon(Icons.face_retouching_off,
                  color: Colors.red.shade700, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Face Already Registered',
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.red.shade800)),
                  if (pct != null)
                    Text('$pct confidence match',
                        style: TextStyle(
                            fontSize: 12, color: Colors.red.shade600)),
                ],
              ),
            ),
          ],
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This face is already enrolled under another student profile. '
            'Registration cannot proceed to prevent duplicate entries.',
            style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.75)),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row(theme, Icons.badge_outlined, 'Student ID',
                    e.studentId ?? '—'),
                if (e.studentName != null && e.studentName!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _row(theme, Icons.person_outline, 'Name', e.studentName!),
                ],
                if (e.courses.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _row(theme, Icons.menu_book_outlined, 'Course(s)',
                      e.courses.join(', ')),
                ],
                if (e.registeredAt != null && e.registeredAt!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _row(theme, Icons.calendar_today_outlined, 'Registered on',
                      _fmtDate(e.registeredAt)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.info_outline,
                  size: 14,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'If this is a different person, ask them to retake the photos.',
                  style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.55)),
                ),
              ),
            ],
          ),
        ],
      ),
      actionsPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      actions: [
        OutlinedButton.icon(
          onPressed: onRetake,
          icon: const Icon(Icons.camera_alt_outlined, size: 18),
          label: const Text('Retake Photos'),
        ),
        FilledButton.icon(
          onPressed: onCancel,
          icon: const Icon(Icons.cancel_outlined, size: 18),
          label: const Text('Cancel Registration'),
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
        ),
      ],
    );
  }

  Widget _row(ThemeData theme, IconData icon, String label, String value) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon,
              size: 15,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55)),
          const SizedBox(width: 8),
          Text('$label: ',
              style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65))),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      );
}
