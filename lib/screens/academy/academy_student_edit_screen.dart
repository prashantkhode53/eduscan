import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter, TextInputFormatter, Clipboard, ClipboardData;
import '../../services/academy_api_service.dart';
import '../../services/face_service.dart';
import '../../widgets/face_overlay_painter.dart';
import '../../widgets/academy_course_selector.dart';
import '../../models/subject.dart';

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

  // ── Step 1: Courses / Subjects ──────────────────────────────────────────────
  List<Map<String, dynamic>> _availableCourses = [];
  // subjectId → custom fee (primary enrollment state)
  final Map<String, double> _selectedSubjectFees = {};
  // courseId → subjects list (lazy-loaded on first expand; pre-loaded for enrolled)
  final Map<String, List<Map<String, dynamic>>> _subjectsByCourse = {};
  // Courses pre-populated from enrollment data only (not full subject list).
  // These must be re-fetched on first expand so newly added subjects appear.
  final Set<String> _enrollmentOnlyCourses = {};
  final Set<String> _expandedCourses = {};
  final Set<String> _subjectsLoadingFor = {};
  final Map<String, String> _subjectsError = {};
  bool _loadingCourses = false;
  String? _courseError;
  // The academic year the student was enrolled under (drives course filter)
  String? _studentAcademicYearId;

  // ── Step 2: Face ───────────────────────────────────────────────────────────
  bool _hasFaceData   = false;
  bool _isRescanning  = false;

  CameraController? _camCtrl;
  CameraDescription? _frontCam;
  bool _camReady        = false;
  String? _camError;
  bool _processingFrame = false;
  bool _autoCapturing   = false;
  bool _faceDone        = false;
  bool _faceDetected    = false;
  bool _scanStalled     = false;
  double _holdProgress  = 0.0;
  double _qualityScore  = 0.0;
  String _qualityHint   = '';
  FaceOverlayState _overlayState = FaceOverlayState.idle;
  final List<String> _faceImages = [];
  static const int _requiredSamples = 5;
  int _captureCount = 0;
  Timer? _progressTicker;
  Timer? _stallTimer;
  DateTime? _noProgressSince;

  // ── Master password (fallback login) ──────────────────────────────────────
  bool   _masterPasswordEnabled = false;
  bool   _settingPassword       = false;
  bool   _revokingPassword      = false;
  final  _newPasswordCtrl       = TextEditingController();
  bool   _newPasswordObscure    = true;
  String? _masterPasswordError;

  // ── Login status (read-only display) ──────────────────────────────────────
  String? _studentStatus;
  String? _lastLogin;

  // ── Scroll controller for step-0 form ─────────────────────────────────────
  final _step0ScrollCtrl = ScrollController();

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
      final studentData = await AcademyApiService.getStudentById(widget.studentId);

      // Use the student's own academic_year_id to filter courses correctly.
      final yearId = studentData['academic_year_id'] as String?;

      // Load courses filtered to the student's academic year (parallel with subject loads).
      final courses = (await AcademyApiService.getCourses(academicYearId: yearId))
          .cast<Map<String, dynamic>>();

      // Pre-populate personal info
      _firstNameCtrl.text  = studentData['first_name']    as String? ?? '';
      _lastNameCtrl.text   = studentData['last_name']     as String? ?? '';
      _mobileCtrl.text     = studentData['mobile']        as String? ?? '';
      _emailCtrl.text      = studentData['email']         as String? ?? '';
      _parentNameCtrl.text = studentData['parent_name']   as String? ?? '';
      _parentMobCtrl.text  = studentData['parent_mobile'] as String? ?? '';
      _addressCtrl.text    = studentData['address']       as String? ?? '';
      final rawDob = studentData['dob']?.toString() ?? '';
      _dobCtrl.text = rawDob.contains('T') ? rawDob.split('T')[0] : rawDob;
      _gender                = studentData['gender'] as String?;
      _masterPasswordEnabled = studentData['fallback_password_enabled'] as bool? ?? false;
      _studentStatus         = studentData['status'] as String? ?? 'active';
      _lastLogin             = studentData['last_login'] as String?;

      // Restore subject-level enrollments from enrolled_subjects (new API field).
      final rawSubjects = studentData['enrolled_subjects'] as List?;
      final enrolled = (rawSubjects ?? [])
          .cast<Map<String, dynamic>>()
          .map(EnrolledSubject.fromJson)
          .where((s) => s.status == 'active')
          .toList();

      final subjectFees = <String, double>{};
      final enrolledByCourse = <String, List<Map<String, dynamic>>>{};
      for (final s in enrolled) {
        subjectFees[s.subjectId] = s.feeAmount;
        enrolledByCourse.putIfAbsent(s.courseId, () => []).add({
          'id':          s.subjectId,
          'course_id':   s.courseId,
          'name':        s.subjectName,
          'default_fee': s.feeAmount,
          'is_active':   true,
        });
      }

      // If no enrolled_subjects (legacy student), fall back to course-level data.
      if (enrolled.isEmpty) {
        final legacyEnrollments = (studentData['courses'] as List? ?? [])
            .cast<Map<String, dynamic>>()
            .where((c) => c['status'] == 'active')
            .toList();
        for (final e in legacyEnrollments) {
          // Legacy: pre-load subjects for each enrolled course so the selector
          // can show them. We do this eagerly only for already-enrolled courses.
          final cid = e['course_id'] as String?;
          if (cid == null) continue;
          try {
            final subs = await AcademyApiService.getSubjectsByCourse(cid);
            if (!mounted) return;
            enrolledByCourse[cid] = subs;
          } catch (_) {}
        }
        // Legacy path fetches the full subject list — no re-fetch needed on expand.
        _enrollmentOnlyCourses.clear();
      } else {
        // Non-legacy: subjectsByCourse has only enrolled subjects.
        // Mark them so _loadSubjects fetches the full list on first expand.
        _enrollmentOnlyCourses
          ..clear()
          ..addAll(enrolledByCourse.keys);
      }

      final embedding = studentData['face_embedding'];
      final hasFace   = embedding is List && embedding.isNotEmpty;

      if (!mounted) return;
      setState(() {
        _studentAcademicYearId = yearId;
        _availableCourses = courses;
        _selectedSubjectFees
          ..clear()
          ..addAll(subjectFees);
        _subjectsByCourse
          ..clear()
          ..addAll(enrolledByCourse);
        // Pre-expand courses that have enrolled subjects so admin sees them immediately.
        _expandedCourses
          ..clear()
          ..addAll(enrolledByCourse.keys);
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
      final data = await AcademyApiService.getCourses(academicYearId: _studentAcademicYearId);
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

  Future<void> _loadSubjects(String courseId) async {
    // Toggle collapse if already fully loaded (not enrollment-only).
    if (_subjectsByCourse.containsKey(courseId) &&
        !_subjectsError.containsKey(courseId) &&
        !_enrollmentOnlyCourses.contains(courseId)) {
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
      _enrollmentOnlyCourses.remove(courseId); // now fully loaded
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
    _mobileCtrl.dispose();    _emailCtrl.dispose();
    _dobCtrl.dispose();
    _parentNameCtrl.dispose(); _parentMobCtrl.dispose();
    _addressCtrl.dispose();
    _newPasswordCtrl.dispose();
    _step0ScrollCtrl.dispose();
    _stallTimer?.cancel();
    _progressTicker?.cancel();
    _camCtrl?.dispose();
    super.dispose();
  }

  // ── Master password actions ────────────────────────────────────────────────

  Future<void> _setMasterPassword() async {
    final pwd = _newPasswordCtrl.text.trim();
    if (pwd.length < 6) {
      setState(() => _masterPasswordError = 'Password must be at least 6 characters');
      return;
    }
    setState(() { _settingPassword = true; _masterPasswordError = null; });
    try {
      await AcademyApiService.setStudentMasterPassword(widget.studentId, pwd);
      _newPasswordCtrl.clear();
      if (mounted) {
        setState(() {
          _settingPassword       = false;
          _masterPasswordEnabled = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Fallback password set. Share it with the parent manually.'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _settingPassword      = false;
          _masterPasswordError  = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _revokeMasterPassword() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Revoke Password'),
        content: const Text(
            'This will disable the password login option for this parent. Continue?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Revoke')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() { _revokingPassword = true; _masterPasswordError = null; });
    try {
      await AcademyApiService.deleteStudentMasterPassword(widget.studentId);
      if (mounted) {
        setState(() {
          _revokingPassword      = false;
          _masterPasswordEnabled = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Fallback password revoked.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _revokingPassword     = false;
          _masterPasswordError  = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _generatePassword() async {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
    final rng = Random.secure();
    final pwd = List.generate(8, (_) => chars[rng.nextInt(chars.length)]).join();

    setState(() { _settingPassword = true; _masterPasswordError = null; });
    try {
      await AcademyApiService.setStudentMasterPassword(widget.studentId, pwd);
      if (!mounted) return;
      setState(() {
        _settingPassword       = false;
        _masterPasswordEnabled = true;
      });
      // Show the generated password once so admin can share it
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Password Generated'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Share this password with the parent. It will not be shown again.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade300),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        pwd,
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 4,
                            color: Colors.orange.shade800),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy_outlined, size: 20),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: pwd));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Password copied')),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _settingPassword     = false;
          _masterPasswordError = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _goNext() {
    if (_step == 0) {
      if (!(_s0Key.currentState?.validate() ?? false)) return;
    }
    if (_step == 1 && _selectedSubjectFees.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one subject')),
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
    if (_camReady && _camCtrl != null) return;
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
      await ctrl.initialize().timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw TimeoutException(
            'Camera took too long to start. Please try again.'),
      );
      if (!mounted) { await ctrl.dispose(); return; }
      setState(() => _camReady = true);
      _startStream();
    } catch (e) {
      debugPrint('[academy/edit] camera init failed: $e');
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
    _stallTimer?.cancel();
    _stallTimer      = null;
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
    _noProgressSince = null;
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || _faceDone) return;
      final np = _noProgressSince;
      if (np != null && DateTime.now().difference(np).inSeconds >= 12) {
        if (!_scanStalled && mounted) setState(() => _scanStalled = true);
      }
    });

    if (_camCtrl == null || !_camCtrl!.value.isInitialized) return;
    _camCtrl!.startImageStream((image) async {
      if (_processingFrame || _faceDone) return;
      _processingFrame = true;
      try {
        final inputImage = FaceService.cameraImageToInputImage(image, _frontCam!);
        if (inputImage == null) return;
        final faces = await FaceService.detectFaces(inputImage);
        if (!mounted) return;
        _noProgressSince = null;

        if (faces.isEmpty) {
          setState(() {
            _overlayState = FaceOverlayState.idle;
            _qualityScore = 0;
            _qualityHint  = '';
            _faceDetected = false;
            _scanStalled  = false;
          });
          _cancelHold();
          return;
        }

        final quality = _computeQuality(faces.first);
        setState(() {
          _qualityScore = quality;
          _faceDetected = quality >= 0.55;
          _scanStalled  = false;
          _overlayState = quality >= 0.55
              ? FaceOverlayState.detected
              : FaceOverlayState.idle;
        });
        if (quality >= 0.55 && !_autoCapturing) {
          _startHold();
        } else if (quality < 0.55) {
          _cancelHold();
        }
      } catch (_) {
        _noProgressSince ??= DateTime.now();
      } finally {
        _processingFrame = false;
      }
    });
  }

  Future<void> _retryCapture() async {
    if (!mounted) return;
    _processingFrame = false;
    _stallTimer?.cancel();
    _stallTimer = null;
    _progressTicker?.cancel();
    _progressTicker  = null;
    _autoCapturing   = false;
    _noProgressSince = null;

    setState(() {
      _faceDetected = false;
      _scanStalled  = false;
      _overlayState = FaceOverlayState.idle;
      _qualityScore = 0;
      _holdProgress = 0;
      _qualityHint  = 'Restarting scanner…';
      _camReady     = false;
      _faceDone     = false;
      _captureCount = 0;
    });
    _faceImages.clear();

    // Stop stream THEN dispose so the HAL cleanly releases before reinit.
    final oldCtrl = _camCtrl;
    _camCtrl = null;
    try { await oldCtrl?.stopImageStream(); } catch (_) {}
    try { await oldCtrl?.dispose(); } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;

    setState(() => _qualityHint = '');
    await _initCamera();
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
      final body = <String, dynamic>{
        'first_name':      _firstNameCtrl.text.trim(),
        'last_name':       _lastNameCtrl.text.trim(),
        'mobile':          _mobileCtrl.text.trim(),
        'email':           _emailCtrl.text.trim().isNotEmpty ? _emailCtrl.text.trim() : null,
        'dob':             _dobCtrl.text.isNotEmpty ? _dobCtrl.text : null,
        'gender':          _gender,
        'parent_name':     _parentNameCtrl.text.trim().isNotEmpty ? _parentNameCtrl.text.trim() : null,
        'parent_mobile':   _parentMobCtrl.text.trim().isNotEmpty  ? _parentMobCtrl.text.trim()  : null,
        'address':         _addressCtrl.text.trim().isNotEmpty    ? _addressCtrl.text.trim()    : null,
        'academic_year_id': _studentAcademicYearId,
        'subjects': _selectedSubjectFees.entries
            .map((e) => {'subject_id': e.key, 'fee_amount': e.value})
            .toList(),
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
            loading:             _loadingCourses,
            error:               _courseError,
            courses:             _availableCourses,
            subjectsByCourse:    _subjectsByCourse,
            selectedSubjectFees: _selectedSubjectFees,
            expandedCourses:     _expandedCourses,
            subjectsLoadingFor:  _subjectsLoadingFor,
            subjectsError:       _subjectsError,
            onCourseExpand:      _loadSubjects,
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
            onNext:    _goNext,
            onRetry:   _reloadCourses,
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
                _faceDetected = false;
                _scanStalled  = false;
                _overlayState = FaceOverlayState.idle;
                _qualityScore = 0;
                _holdProgress = 0;
              });
              _initCamera();
            },
            onKeepFace: _submitting ? null : () => _submit(withNewFace: false),
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
            done:          _faceDone,
            faceDetected:  _faceDetected,
            scanStalled:   _scanStalled,
            submitting:    _submitting,
            autoCapturing: _autoCapturing,
            onCaptureNow: () {
              _cancelHold();
              _autoCapturing = true;
              _doCapture();
            },
            onSubmitWithFace: () => _submit(withNewFace: true),
            onRetryCapture: _retryCapture,
            onReset: () {
              _processingFrame = false;
              setState(() {
                _faceImages.clear();
                _captureCount = 0;
                _faceDone     = false;
                _faceDetected = false;
                _scanStalled  = false;
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
        controller: _step0ScrollCtrl,
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
                maxLength: 10,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                v: (v) => v == null || v.trim().length != 10
                    ? 'Enter 10-digit mobile number' : null),
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

            _tf(_parentMobCtrl, 'Parent Mobile',
                type: TextInputType.phone,
                maxLength: 10,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                v: (v) => v != null && v.trim().isNotEmpty &&
                        v.trim().length != 10
                    ? 'Enter 10-digit mobile number' : null),
            const SizedBox(height: 12),

            TextFormField(
              controller: _addressCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'Address', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 24),

            // ── Login status (read-only) ───────────────────────────────────
            _LoginStatusCard(
              hasFace:          _hasFaceData,
              passwordEnabled:  _masterPasswordEnabled,
              accountStatus:    _studentStatus ?? 'active',
              lastLogin:        _lastLogin,
            ),
            const SizedBox(height: 16),

            // ── Fallback login password (admin-only) ───────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _masterPasswordEnabled
                      ? Colors.orange.shade300
                      : theme.colorScheme.outlineVariant,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Icon(Icons.lock_outline,
                        size: 18,
                        color: _masterPasswordEnabled
                            ? Colors.orange.shade700
                            : theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Fallback Login Password',
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: _masterPasswordEnabled
                                  ? Colors.orange.shade700
                                  : theme.colorScheme.onSurface)),
                    ),
                    if (_masterPasswordEnabled)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Text('Active',
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.orange.shade700,
                                fontWeight: FontWeight.w600)),
                      ),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                    _masterPasswordEnabled
                        ? 'A password is set. The parent can use it if face scan fails.'
                        : 'Set a password so the parent can log in without face scan.',
                    style: TextStyle(
                        fontSize: 12,
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                  ),
                  const SizedBox(height: 12),

                  // Set / update password
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _newPasswordCtrl,
                        obscureText: _newPasswordObscure,
                        keyboardType: TextInputType.visiblePassword,
                        textInputAction: TextInputAction.done,
                        onTap: () {
                          // Scroll to bottom so the field is never hidden behind the keyboard
                          Future.delayed(const Duration(milliseconds: 300), () {
                            if (_step0ScrollCtrl.hasClients) {
                              _step0ScrollCtrl.animateTo(
                                _step0ScrollCtrl.position.maxScrollExtent,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOut,
                              );
                            }
                          });
                        },
                        onFieldSubmitted: (_) => _setMasterPassword(),
                        decoration: InputDecoration(
                          labelText: _masterPasswordEnabled
                              ? 'New Password'
                              : 'Set Password',
                          hintText: 'Min 6 characters',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          suffixIcon: IconButton(
                            icon: Icon(_newPasswordObscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined),
                            onPressed: () => setState(
                                () => _newPasswordObscure = !_newPasswordObscure),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _settingPassword ? null : _setMasterPassword,
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.orange.shade700),
                      child: _settingPassword
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text(_masterPasswordEnabled ? 'Update' : 'Set'),
                    ),
                  ]),

                  const SizedBox(height: 8),
                  // Generate random password button
                  OutlinedButton.icon(
                    onPressed: _settingPassword ? null : _generatePassword,
                    icon: const Icon(Icons.shuffle_outlined, size: 16),
                    label: const Text('Generate Password'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange.shade700,
                      side: BorderSide(color: Colors.orange.shade300),
                    ),
                  ),

                  // Revoke button — only visible when password is active
                  if (_masterPasswordEnabled) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _revokingPassword ? null : _revokeMasterPassword,
                      icon: _revokingPassword
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.lock_open_outlined, size: 16),
                      label: const Text('Revoke Password'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                        side: BorderSide(color: Colors.red.shade300),
                      ),
                    ),
                  ],

                  if (_masterPasswordError != null) ...[
                    const SizedBox(height: 8),
                    Text(_masterPasswordError!,
                        style: TextStyle(
                            fontSize: 12, color: Colors.red.shade700)),
                  ],
                ],
              ),
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
    int? maxLength,
    List<TextInputFormatter>? inputFormatters,
  }) =>
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

// ── Face step widget ──────────────────────────────────────────────────────────

class _FaceStep extends StatelessWidget {
  final bool hasFaceData;
  final bool isRescanning;
  final VoidCallback onStartRescan;
  final VoidCallback? onKeepFace;

  final CameraController? camCtrl;
  final bool camReady, done, faceDetected, scanStalled, submitting, autoCapturing;
  final String? camError;
  final VoidCallback onRetryCamera;
  final FaceOverlayState overlayState;
  final double holdProgress, qualityScore;
  final String qualityHint;
  final int captureCount, requiredSamples;
  final VoidCallback onCaptureNow, onSubmitWithFace, onReset;
  final Future<void> Function() onRetryCapture;

  const _FaceStep({
    required this.hasFaceData,
    required this.isRescanning,
    required this.onStartRescan,
    this.onKeepFace,
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
    required this.faceDetected,
    required this.scanStalled,
    required this.submitting,
    required this.autoCapturing,
    required this.onCaptureNow,
    required this.onSubmitWithFace,
    required this.onRetryCapture,
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
          if (scanStalled && !done)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.shade400),
              ),
              child: Row(children: [
                Icon(Icons.warning_amber_rounded, color: Colors.amber.shade800, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Face detection stalled. Tap Refresh & Retry.',
                      style: TextStyle(fontSize: 12)),
                ),
              ]),
            ),
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
          ] else ...[
            OutlinedButton.icon(
              onPressed: (!autoCapturing && faceDetected) ? onCaptureNow : null,
              icon: const Icon(Icons.camera_alt_outlined),
              label: Text(autoCapturing ? 'Capturing…' : 'Capture Now'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onRetryCapture,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh & Retry Scan'),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Login Status Card ──────────────────────────────────────────────────────────

class _LoginStatusCard extends StatelessWidget {
  final bool hasFace;
  final bool passwordEnabled;
  final String accountStatus;
  final String? lastLogin;

  const _LoginStatusCard({
    required this.hasFace,
    required this.passwordEnabled,
    required this.accountStatus,
    this.lastLogin,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    String _formatDate(String? iso) {
      if (iso == null || iso.isEmpty) return 'Never';
      try {
        final dt = DateTime.parse(iso).toLocal();
        final d  = dt.day.toString().padLeft(2, '0');
        final mo = dt.month.toString().padLeft(2, '0');
        final yr = dt.year.toString();
        final h  = dt.hour.toString().padLeft(2, '0');
        final mi = dt.minute.toString().padLeft(2, '0');
        return '$d/$mo/$yr $h:$mi';
      } catch (_) {
        return 'Unknown';
      }
    }

    final isActive = accountStatus == 'active';

    return Container(
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
            Icon(Icons.verified_user_outlined,
                size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text('Login Status',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: theme.colorScheme.primary)),
          ]),
          const SizedBox(height: 12),
          _StatusRow(
            label: 'Face Login',
            value: hasFace ? 'Registered' : 'Not Registered',
            icon: hasFace
                ? Icons.face_retouching_natural
                : Icons.face_retouching_off_outlined,
            ok: hasFace,
          ),
          const SizedBox(height: 8),
          _StatusRow(
            label: 'Password Login',
            value: passwordEnabled ? 'Enabled' : 'Disabled',
            icon: passwordEnabled ? Icons.lock_outlined : Icons.lock_open_outlined,
            ok: passwordEnabled,
          ),
          const SizedBox(height: 8),
          _StatusRow(
            label: 'Account Status',
            value: isActive ? 'Active' : accountStatus[0].toUpperCase() + accountStatus.substring(1),
            icon: isActive ? Icons.check_circle_outline : Icons.block_outlined,
            ok: isActive,
          ),
          const SizedBox(height: 8),
          _StatusRow(
            label: 'Last Login',
            value: _formatDate(lastLogin),
            icon: Icons.access_time_outlined,
            ok: lastLogin != null,
            neutral: true,
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool ok;
  final bool neutral;

  const _StatusRow({
    required this.label,
    required this.value,
    required this.icon,
    required this.ok,
    this.neutral = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = neutral
        ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)
        : ok
            ? Colors.green.shade700
            : Colors.red.shade600;

    return Row(
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 8),
        SizedBox(
          width: 110,
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7))),
        ),
        Text(value,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color)),
      ],
    );
  }
}
