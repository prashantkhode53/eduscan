import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img_lib;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter, TextInputFormatter;
import '../../services/academy_api_service.dart';
import '../../services/face_service.dart';
import '../../widgets/academic_year_filter.dart';
import '../../widgets/face_overlay_painter.dart';
import '../../widgets/academy_course_selector.dart';
import '../../utils/date_utils.dart' as du;

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

  // â”€â”€ Step 3: Academic Year filter + Courses â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Academic Year is selected at the top of the Courses step and is used ONLY to
  // filter the available course list (and is saved as the student's
  // academic_year_id). No default — the admin must pick a year before courses load.
  List<Map<String, dynamic>> _academicYears = [];
  bool _yearsLoading = false;
  String? _selectedYearId;
  List<Map<String, dynamic>> _availableCourses = [];
  // subjectId → custom fee (primary enrollment state)
  final Map<String, double> _selectedSubjectFees = {};
  // courseId → subjects list (lazy-loaded on first expand)
  final Map<String, List<Map<String, dynamic>>> _subjectsByCourse = {};
  final Set<String> _expandedCourses = {};
  final Set<String> _subjectsLoadingFor = {};
  final Map<String, String> _subjectsError = {};
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
  static const int _requiredSamples = 3;
  int _captureCount = 0;
  Timer? _progressTicker;

  // â”€â”€ Submit â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  bool _submitting        = false;
  bool _checkingDuplicate = false;

  // Stall detection: if the scanner makes no progress for >12s, show retry UI.
  bool      _scanStalled    = false;
  bool      _faceDetected   = false; // true whenever a face is in frame
  DateTime? _noProgressSince;
  Timer?    _stallCheckTimer;

  // Two-phase save: the student's details (Personal/Parent/Courses) are
  // persisted BEFORE the face scan so they're never lost if the scan fails.
  // _studentId holds the created record; the face is attached afterwards.
  String? _studentId;
  bool _savingDetails = false;
  Future<void>? _detailsSave;  // in-flight Phase 1 (runs in the background)
  Future<void>? _embedDone;   // pre-started embed kicked off after last capture

  @override
  void initState() {
    super.initState();
    _loadAcademicYears();
  }

  // Load the academic-year options for the Courses-step filter. No year is
  // pre-selected — the admin must choose one before any courses are loaded.
  Future<void> _loadAcademicYears() async {
    if (!mounted) return;
    setState(() => _yearsLoading = true);
    try {
      final years = await AcademyApiService.getAcademicYears();
      if (!mounted) return;
      setState(() {
        _academicYears = years.where((y) => y['status'] == 'active').toList();
        _yearsLoading  = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _yearsLoading = false);
    }
  }

  // Called when the admin picks a year in the Courses step. Filters the course
  // list to that year and resets any course/subject selections made under a
  // previously chosen year.
  void _onYearSelected(String? yearId) {
    if (yearId == null || yearId == _selectedYearId) return;
    setState(() {
      _selectedYearId = yearId;
      _availableCourses = [];
      _selectedSubjectFees.clear();
      _subjectsByCourse.clear();
      _expandedCourses.clear();
      _subjectsError.clear();
      _courseError = null;
    });
    _loadCourses();
  }

  Future<void> _loadCourses() async {
    if (!mounted || _selectedYearId == null) return;
    setState(() { _loadingCourses = true; _courseError = null; });
    try {
      final data =
          await AcademyApiService.getCourses(academicYearId: _selectedYearId);
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

  // Shown on the Courses step before an academic year is chosen.
  Widget _buildPickYearPrompt(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_note_outlined,
                  size: 56,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
              const SizedBox(height: 12),
              Text('Select an academic year',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text('Choose an academic year above to see its courses.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
            ],
          ),
        ),
      );

  Future<void> _loadSubjects(String courseId) async {
    if (_subjectsByCourse.containsKey(courseId) &&
        !_subjectsError.containsKey(courseId)) {
      // Already loaded successfully — just toggle expand
      setState(() {
        if (_expandedCourses.contains(courseId)) {
          _expandedCourses.remove(courseId);
        } else {
          _expandedCourses.add(courseId);
        }
      });
      return;
    }
    if (_subjectsLoadingFor.contains(courseId)) return;
    setState(() {
      _expandedCourses.add(courseId);
      _subjectsLoadingFor.add(courseId);
      _subjectsError.remove(courseId);
    });
    try {
      final data = await AcademyApiService.getSubjectsByCourse(courseId);
      if (!mounted) return;
      setState(() {
        _subjectsByCourse[courseId] = data;
        _subjectsLoadingFor.remove(courseId);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _subjectsError[courseId] = e.toString().replaceFirst('Exception: ', '');
        _subjectsLoadingFor.remove(courseId);
      });
    }
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _firstNameCtrl.dispose(); _lastNameCtrl.dispose();
    _dobCtrl.dispose(); _mobileCtrl.dispose(); _emailCtrl.dispose();
    _parentNameCtrl.dispose(); _parentMobCtrl.dispose(); _addressCtrl.dispose();
    _stallCheckTimer?.cancel();
    _progressTicker?.cancel();
    _camCtrl?.dispose();
    super.dispose();
  }

  // â”€â”€ Navigation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _goNext() async {
    // Guard against double-tap while the duplicate check is in flight.
    if (_checkingDuplicate) return;

    if (_step == 0) {
      if (!(_s1Key.currentState?.validate() ?? false)) return;

      // Duplicate-name check — only when DOB is provided. Name alone is not
      // unique enough to block. Network errors are swallowed so a backend
      // outage never prevents a legitimate registration.
      final dob = _dobCtrl.text.trim();
      if (dob.isNotEmpty) {
        setState(() => _checkingDuplicate = true);
        try {
          final dup = await AcademyApiService.checkStudentDuplicate(
            firstName: _firstNameCtrl.text.trim(),
            lastName:  _lastNameCtrl.text.trim(),
            dob:       dob,
          );
          if (!mounted) return;
          if (dup != null) {
            setState(() => _checkingDuplicate = false);
            final proceed = await _showStudentDuplicateDialog(dup);
            if (!proceed) return; // user chose not to continue
          }
        } catch (_) {
          // Non-fatal — proceed silently on any error.
        } finally {
          if (mounted) setState(() => _checkingDuplicate = false);
        }
      }
    }

    // Step 1 (Parent & Address) has no required fields — validate if state exists,
    // but never block navigation if form hasn't rendered yet.
    if (_step == 1) {
      final s2Valid = _s2Key.currentState?.validate();
      if (s2Valid == false) return;
    }
    if (_step == 2) {
      if (_selectedYearId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select an academic year')),
        );
        return;
      }
      if (_selectedSubjectFees.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select at least one subject')),
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
    // Courses load when the admin picks an academic year on the Courses step
    // (see _onYearSelected) — nothing to fetch on step entry.
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
        'subjects': _selectedSubjectFees.entries
            .map((e) => {'subject_id': e.key, 'fee_amount': e.value})
            .toList(),
        'academic_year_id': _selectedYearId,
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
      // Phase 1 runs in the background while the user is on the camera screen.
      // Never show an alarming red error from a background save — the fallback
      // one-shot create in _submit() handles any failure transparently. We log
      // the type + ref so a Phase-1 failure is still diagnosable post-deploy.
      final ref = e is ApiException ? e.errorRef : null;
      debugPrint('[register] Phase 1 failed (will fallback to one-shot create): '
          '${e.runtimeType} -> $e${ref != null ? ' [ref: $ref]' : ''}');
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
    _stallCheckTimer?.cancel();
    _stallCheckTimer = null;
    _progressTicker?.cancel();
    _progressTicker  = null;
    // Must clear this before disposing — if a frame callback is mid-flight
    // the finally block will still reset it, but clearing here prevents any
    // new stream on the next _initCamera() from being silently blocked.
    _processingFrame = false;
    _camCtrl?.dispose();
    _camCtrl      = null;
    _camReady     = false;
    _autoCapturing  = false;
    _faceDetected   = false;
    _scanStalled    = false;
  }

  Future<void> _retryCapture() async {
    // 1 — Immediately clear stuck flags so UI is responsive
    _processingFrame = false;
    _stallCheckTimer?.cancel();
    _stallCheckTimer = null;
    _progressTicker?.cancel();
    _progressTicker  = null;
    _noProgressSince = null;

    setState(() {
      _scanStalled   = false;
      _faceDetected  = false;
      _qualityScore  = 0;
      _qualityHint   = 'Restarting scanner...';
      _overlayState  = FaceOverlayState.idle;
      _holdProgress  = 0;
      _autoCapturing = false;
      _camReady      = false;
      // Reset scan progress so the restart is a clean slate
      _done          = false;
      _captureCount  = 0;
    });
    _faceImages.clear();
    _embedDone = null;

    // 2 — Stop the image stream explicitly BEFORE dispose. Without this,
    //     some Android HALs leave the stream open internally, causing the
    //     new controller's startImageStream to accept the call but never
    //     deliver frames — making the camera look alive but detection dead.
    final oldCtrl = _camCtrl;
    _camCtrl = null;
    try { await oldCtrl?.stopImageStream(); } catch (_) {}
    try { await oldCtrl?.dispose(); } catch (_) {}

    // 3 — Give the camera HAL time to fully release the sensor
    await Future.delayed(const Duration(milliseconds: 700));

    if (mounted) await _initCamera();
  }

  // Quality score — relaxed thresholds so natural phone-holding angles and
  // glasses wearers are not hard-blocked. Returns a minimum of 0.15 whenever
  // a face is in frame so that “Capture Now” is always available as a manual
  // override (auto-capture still requires ≥ 0.55).
  double _computeQuality(dynamic face) {
    final yaw   = (face.headEulerAngleY as double? ?? 0).abs();
    final roll  = (face.headEulerAngleZ as double? ?? 0).abs();
    final pitch = (face.headEulerAngleX as double? ?? 0).abs();

    // Relaxed angle limits: 35/28/25 (was 25/20/20). When exceeded the face
    // is too skewed for a good embedding but the user may still manual-capture.
    if (yaw > 35) {
      _qualityHint = 'Look straight ahead';
      return 0.15;
    }
    if (roll > 25) {
      _qualityHint = 'Hold your head level';
      return 0.15;
    }
    if (pitch > 28) {
      _qualityHint = 'Hold the phone at eye level';
      return 0.15;
    }

    final sizeScore =
        (((face.boundingBox.width as num).toDouble() - 80) / 120).clamp(0.0, 1.0);
    if (sizeScore < 0.05) {
      _qualityHint = 'Move closer to camera';
      return 0.15;
    }

    final leftEye  = face.leftEyeOpenProbability  as double? ?? 1.0;
    final rightEye = face.rightEyeOpenProbability as double? ?? 1.0;
    final eyeScore = (leftEye + rightEye) / 2.0;

    final score = (sizeScore * 0.35 +
            (1 - (yaw / 35).clamp(0.0, 1.0)) * 0.25 +
            (1 - (roll / 25).clamp(0.0, 1.0)) * 0.15 +
            (1 - (pitch / 28).clamp(0.0, 1.0)) * 0.15 +
            eyeScore * 0.10)
        .clamp(0.0, 1.0);

    if (score < 0.55) {
      if (sizeScore < 0.3) {
        _qualityHint = 'Move closer to camera';
      } else if (eyeScore < 0.5) {
        _qualityHint = 'Keep eyes open — reduce glare on glasses';
      } else if (pitch > 15) {
        _qualityHint = 'Hold the phone at eye level';
      } else {
        _qualityHint = 'Face the camera directly';
      }
    } else {
      _qualityHint = '';
    }

    // Never drop below 0.15 when a face is present — keeps Capture Now active.
    return score.clamp(0.15, 1.0);
  }

  void _startStream() {
    if (_camCtrl == null || !_camCtrl!.value.isInitialized) return;

    // Stall detection: 2-second tick. If quality hasn't been good for 12s,
    // surface the Refresh & Retry banner so the user always has an action.
    _noProgressSince = DateTime.now();
    _scanStalled     = false;
    _stallCheckTimer?.cancel();
    _stallCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || _done) return;
      final elapsed = DateTime.now().difference(_noProgressSince!);
      final stalled = elapsed > const Duration(seconds: 12);
      if (stalled != _scanStalled) setState(() => _scanStalled = stalled);
    });

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
            _faceDetected = false;
          });
          _cancelHold();
          return;
        }

        final quality = _computeQuality(faces.first);
        setState(() {
          _qualityScore = quality;
          _faceDetected = true;
          _overlayState =
              quality >= 0.55 ? FaceOverlayState.detected : FaceOverlayState.idle;
        });
        if (quality >= 0.55 && !_autoCapturing) {
          _startHold();
        } else if (quality < 0.55) {
          _cancelHold();
        }
      } catch (_) {
        // Swallow frame errors — the stream continues on the next frame.
      } finally {
        // CRITICAL: always reset so the next frame can be processed.
        // Without finally, any early `return` above leaves _processingFrame
        // permanently true, silently blocking all subsequent frames.
        _processingFrame = false;
      }
    });
  }

  void _startHold() {
    if (_autoCapturing) return;
    // Good-quality frame — reset stall clock and dismiss any stall warning.
    _noProgressSince = DateTime.now();
    if (_scanStalled && mounted) setState(() => _scanStalled = false);
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

  /// Compress a raw JPEG to max 640 px on the long edge at 85 % quality.
  /// InsightFace crops the face region internally — full resolution is wasted.
  /// Runs on the calling isolate; the image package is pure Dart so no
  /// platform-channel overhead.
  static List<int> _compressJpeg(List<int> rawBytes) {
    final decoded = img_lib.decodeImage(Uint8List.fromList(rawBytes));
    if (decoded == null) return rawBytes;
    final resized = decoded.width > decoded.height
        ? img_lib.copyResize(decoded, width: 640)
        : img_lib.copyResize(decoded, height: 640);
    return img_lib.encodeJpg(resized, quality: 85);
  }

  Future<void> _doCapture() async {
    if (_camCtrl == null || _done) { _autoCapturing = false; return; }
    try {
      await _camCtrl!.stopImageStream();
      final xFile  = await _camCtrl!.takePicture();
      final raw    = await xFile.readAsBytes();
      final compressed = await Future(() => _compressJpeg(raw));
      _faceImages.add(base64Encode(compressed));
      _captureCount++;
      _holdProgress = 0.0;
      // Each successful capture resets the stall clock.
      _noProgressSince = DateTime.now();
      if (_scanStalled && mounted) setState(() => _scanStalled = false);
      if (_captureCount >= _requiredSamples) {
        _done          = true;
        _autoCapturing = false;
        setState(() => _overlayState = FaceOverlayState.successCheckin);
        // Start embedding immediately — hides InsightFace latency while the
        // user reads the success state and reaches for the button.
        _embedDone = _beginEmbed();
      } else {
        _autoCapturing = false;
        setState(() {});
        _startStream();
      }
    } catch (e) {
      // A capture/encode failure here is recoverable — log it and resume the
      // stream so the user can simply try again rather than getting stuck.
      debugPrint('[register] capture failed (will resume stream): ${e.runtimeType} -> $e');
      _autoCapturing = false;
      if (mounted) _startStream();
    }
  }

  /// Background embed: called immediately after the final capture so the
  /// InsightFace round-trip runs while the user taps "Register Student".
  /// Errors are NOT swallowed — _submit() awaits this and handles them.
  Future<void> _beginEmbed() async {
    if (_detailsSave != null) {
      try { await _detailsSave; } catch (_) {}
    }
    if (_studentId != null) {
      await AcademyApiService.updateStudentFace(_studentId!, _faceImages);
    }
    // If _studentId is still null (rare Phase-1 failure), _submit() falls
    // through to the one-shot create path which also embeds.
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
      if (_embedDone != null && _studentId != null) {
        // Pre-embed already in flight since the final capture — just await it.
        debugPrint('[register] submit: awaiting pre-started embed for $_studentId');
        await _embedDone;
      } else {
        // Fallback: pre-embed didn't start (Phase 1 hadn't produced an id yet).
        if (_detailsSave != null) {
          try { await _detailsSave; } catch (_) {}
        }
        if (_studentId != null) {
          debugPrint('[register] submit: attaching face to existing student '
              '$_studentId (${_faceImages.length} images)');
          await AcademyApiService.updateStudentFace(_studentId!, _faceImages);
        } else {
          debugPrint('[register] submit: one-shot create with face '
              '(${_faceImages.length} images) — Phase 1 had not produced an id');
          final res = await AcademyApiService.registerStudent({
            ..._detailsBody(),
            'face_images': _faceImages,
          });
          _studentId = res['id'] as String?;
        }
      }

      if (mounted) {
        debugPrint('[register] submit: success, studentId=$_studentId');
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
        final msg = _describeError(e, 'submit');
        // Server/database faults carry a reference code worth reading — give
        // those a longer on-screen time than a quick "try again" hint.
        final isServerFault = e is ApiException && e.isServerFault;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.red,
            duration: Duration(seconds: isServerFault ? 8 : 4),
          ),
        );
      }
    }
  }

  /// Maps any error thrown by the registration API calls into a clear,
  /// user-facing message, and logs the raw error (type + detail) for
  /// post-deployment diagnosis. Each failure mode reads distinctly instead of
  /// collapsing into a single generic line.
  String _describeError(Object e, String phase) {
    debugPrint('[register] $phase FAILED: ${e.runtimeType} -> $e');
    if (e is ApiException) {
      // The backend already returns a specific, user-safe reason. For server /
      // database / schema faults, surface the reference code so it can be
      // reported to support and matched in the server logs.
      if (e.isServerFault &&
          e.errorRef != null &&
          !e.message.contains(e.errorRef!)) {
        return '${e.message} (ref: ${e.errorRef})';
      }
      return e.message;
    }
    if (e is TimeoutException) {
      return 'The server took too long to respond — it may be waking up. '
          'Please check your connection and try again.';
    }
    final s = e.toString();
    if (s.contains('No internet connection') ||
        s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        s.contains('Network is unreachable') ||
        s.contains('Connection refused')) {
      return 'Network connection failed. Please check your internet and try again.';
    }
    return s.replaceFirst('Exception: ', '');
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

  /// Shows the “student already exists” dialog and returns true if the admin
  /// chose to continue anyway, false if they cancelled.
  Future<bool> _showStudentDuplicateDialog(Map<String, dynamic> dup) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _StudentDuplicateDialog(student: dup),
        ) ??
        false;
  }

  // â”€â”€ Build â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = ['Personal Info', 'Parent & Address', 'Courses', 'Face Capture'];

    return PopScope(
      canPop: false,
      // Route the system back button through _goBack() so camera disposal
      // and step navigation always happen — same as the AppBar back button.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _goBack();
      },
      child: Scaffold(
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
            checkingDuplicate: _checkingDuplicate,
          ),
          _Step2(
            formKey: _s2Key,
            parentNameCtrl: _parentNameCtrl, parentMobCtrl: _parentMobCtrl,
            addressCtrl: _addressCtrl,
            onNext: _goNext,
          ),
          Column(
            children: [
              AcademicYearFilter(
                years:      _academicYears,
                loading:    _yearsLoading,
                selectedId: _selectedYearId,
                onChanged:  _onYearSelected,
              ),
              Expanded(
                child: _selectedYearId == null
                    ? _buildPickYearPrompt(theme)
                    : AcademyCourseSelector(
                        loading:            _loadingCourses,
                        error:              _courseError,
                        courses:            _availableCourses,
                        subjectsByCourse:   _subjectsByCourse,
                        selectedSubjectFees: _selectedSubjectFees,
                        expandedCourses:    _expandedCourses,
                        subjectsLoadingFor: _subjectsLoadingFor,
                        subjectsError:      _subjectsError,
                        onCourseExpand:     _loadSubjects,
                        onSubjectToggle: (subjectId, defaultFee, selected) {
                          setState(() {
                            if (selected) {
                              _selectedSubjectFees[subjectId] = defaultFee;
                            } else {
                              _selectedSubjectFees.remove(subjectId);
                            }
                          });
                        },
                        onSubjectFeeChanged: (subjectId, fee) =>
                            setState(() => _selectedSubjectFees[subjectId] = fee),
                        onNext:  _goNext,
                        onRetry: _loadCourses,
                      ),
              ),
            ],
          ),
          _Step4(
            camCtrl:         _camCtrl,
            camReady:        _camReady,
            camError:        _camError,
            onRetryCamera:   _initCamera,
            overlayState:    _overlayState,
            holdProgress:    _holdProgress,
            qualityScore:    _qualityScore,
            qualityHint:     _qualityHint,
            captureCount:    _captureCount,
            requiredSamples: _requiredSamples,
            done:            _done,
            submitting:      _submitting,
            autoCapturing:   _autoCapturing,
            faceDetected:    _faceDetected,
            scanStalled:     _scanStalled,
            onRetryCapture:  _retryCapture,
            onCaptureNow: () {
              _cancelHold();
              _autoCapturing = true;
              _doCapture();
            },
            onSubmit: _submit,
            onReset: () {
              _processingFrame = false; // clear any stuck frame before new stream
              setState(() {
                _faceImages.clear();
                _captureCount = 0;
                _done         = false;
                _overlayState = FaceOverlayState.idle;
                _scanStalled  = false;
                _faceDetected = false;
                _qualityScore = 0;
                _qualityHint  = '';
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
      ), // Scaffold
    ); // PopScope
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
  final bool checkingDuplicate;

  const _Step1({
    required this.formKey, required this.firstNameCtrl,
    required this.lastNameCtrl, required this.dobCtrl,
    required this.mobileCtrl, required this.emailCtrl,
    required this.gender, required this.onGenderChanged,
    required this.onNext,
    this.checkingDuplicate = false,
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
                maxLength: 10,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                v: (v) => v == null || v.trim().length != 10
                    ? 'Enter 10-digit mobile number' : null),
            const SizedBox(height: 12),
            _tf(emailCtrl, 'Email (optional)', type: TextInputType.emailAddress),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: checkingDuplicate ? null : onNext,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: checkingDuplicate
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Next'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tf(TextEditingController ctrl, String label,
      {TextInputType type = TextInputType.text,
      String? Function(String?)? v,
      int? maxLength,
      List<TextInputFormatter>? inputFormatters}) =>
      TextFormField(
        controller: ctrl,
        keyboardType: type,
        maxLength: maxLength,
        inputFormatters: inputFormatters,
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
              maxLength: 10,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                  labelText: 'Parent Mobile',
                  border: OutlineInputBorder()),
              validator: (v) => v != null && v.trim().isNotEmpty &&
                      v.trim().length != 10
                  ? 'Enter 10-digit mobile number'
                  : null,
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
  final bool faceDetected, scanStalled;
  final String? camError;
  final VoidCallback onRetryCamera;
  final VoidCallback onRetryCapture;
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
    required this.faceDetected,
    required this.scanStalled,
    required this.onRetryCapture,
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

          // Quality bar (shown when face is in frame)
          if (faceDetected && !done)
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

          // Stall warning — shown after 12 s with no good-quality frame
          if (scanStalled && !done) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.shade300),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: Colors.amber.shade800, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      faceDetected
                          ? 'Auto-capture is taking longer than usual. '
                            'Improve lighting or remove glasses glare, '
                            'then tap Capture Now or Refresh & Retry.'
                          : 'Face not detected. Ensure your face is clearly '
                            'visible, then tap Refresh & Retry Scan.',
                      style: TextStyle(
                          fontSize: 12, color: Colors.amber.shade900),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],

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
          ] else ...[
            // Capture Now — enabled whenever a face is in frame (faceDetected),
            // even if quality is too low for auto-capture. This lets the admin
            // manually override for glasses / glare / lighting scenarios.
            OutlinedButton.icon(
              onPressed: (!autoCapturing && faceDetected) ? onCaptureNow : null,
              icon: const Icon(Icons.camera_alt_outlined),
              label: Text(autoCapturing ? 'Capturing...' : 'Capture Now'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
            ),
            // Refresh & Retry — always available (not just on stall) so users
            // can recover from a frozen stream or persistent glare at any time.
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onRetryCapture,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh & Retry Scan'),
              style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(40)),
            ),
          ],
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

  String _fmtDate(String? raw) => du.fmtDate(raw);

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

// ── Student Duplicate Dialog ──────────────────────────────────────────────────

class _StudentDuplicateDialog extends StatelessWidget {
  final Map<String, dynamic> student;
  const _StudentDuplicateDialog({required this.student});

  String _fmtDate(dynamic raw) => du.fmtDate(raw?.toString());

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final id      = student['id']   as String? ?? '—';
    final name    = student['name'] as String? ?? '';
    final dob     = _fmtDate(student['dob']);
    final regDate = _fmtDate(student['registered_at']);
    final rawCourses = student['courses'];
    final courses = rawCourses is List
        ? rawCourses.map((e) => e.toString()).toList()
        : <String>[];

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titlePadding: EdgeInsets.zero,
      title: Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: Colors.orange.shade100,
              child: Icon(Icons.person_search_outlined,
                  color: Colors.orange.shade800, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Student Already Exists',
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade900)),
                  Text('Same name & date of birth found',
                      style: TextStyle(
                          fontSize: 12, color: Colors.orange.shade700)),
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
            'A registered student with the same First Name, Last Name, and '
            'Date of Birth already exists in this academy.',
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
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _dupRow(theme, Icons.badge_outlined, 'Student ID', id),
                if (name.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _dupRow(theme, Icons.person_outline, 'Name', name),
                ],
                if (dob.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _dupRow(theme, Icons.cake_outlined, 'Date of Birth', dob),
                ],
                if (courses.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _dupRow(theme, Icons.menu_book_outlined, 'Course(s)',
                      courses.join(', ')),
                ],
                if (regDate.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _dupRow(theme, Icons.calendar_today_outlined,
                      'Registered on', regDate),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 14, color: Colors.orange.shade700),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Proceeding will create a second record for the same person.',
                  style: TextStyle(
                      fontSize: 11, color: Colors.orange.shade800),
                ),
              ),
            ],
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.arrow_forward, size: 18),
          label: const Text('Continue Anyway'),
          style: OutlinedButton.styleFrom(
              foregroundColor: Colors.orange.shade800,
              side: BorderSide(color: Colors.orange.shade400)),
        ),
      ],
    );
  }

  Widget _dupRow(ThemeData theme, IconData icon, String label, String value) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15,
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
