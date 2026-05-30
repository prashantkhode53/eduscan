import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';
import '../../services/face_service.dart';
import '../../widgets/face_overlay_painter.dart';
import 'dart:async';

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

  // ── Step 1: Personal Info ─────────────────────────────────────────────────
  final _s1Key         = GlobalKey<FormState>();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl  = TextEditingController();
  final _dobCtrl       = TextEditingController();
  String? _gender;
  final _mobileCtrl    = TextEditingController();
  final _emailCtrl     = TextEditingController();

  // ── Step 2: Parent & Address ──────────────────────────────────────────────
  final _s2Key          = GlobalKey<FormState>();
  final _parentNameCtrl = TextEditingController();
  final _parentMobCtrl  = TextEditingController();
  final _addressCtrl    = TextEditingController();

  // ── Step 3: Courses ───────────────────────────────────────────────────────
  List<Map<String, dynamic>> _availableCourses = [];
  final Map<String, double> _selectedFees = {};
  bool _loadingCourses = false;
  String? _courseError;

  // ── Step 4: Face ──────────────────────────────────────────────────────────
  CameraController? _camCtrl;
  CameraDescription? _frontCam;
  bool _camReady        = false;
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

  // ── Submit ────────────────────────────────────────────────────────────────
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadCourses();
  }

  Future<void> _loadCourses() async {
    setState(() { _loadingCourses = true; _courseError = null; });
    try {
      final data = await AcademyApiService.getCourses();
      _availableCourses = data.cast<Map<String, dynamic>>();
    } catch (e) {
      _courseError = e.toString().replaceFirst('Exception: ', '');
    }
    setState(() => _loadingCourses = false);
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

  // ── Navigation ────────────────────────────────────────────────────────────

  void _goNext() {
    if (_step == 0 && !(_s1Key.currentState?.validate() ?? false)) return;
    // Step 1 (Parent & Address) has no required fields — validate if state exists,
    // but never block navigation if form hasn't rendered yet.
    if (_step == 1) {
      final s2Valid = _s2Key.currentState?.validate();
      if (s2Valid == false) return;
    }
    if (_step == 2 && _selectedFees.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one course')),
      );
      return;
    }
    setState(() => _step++);
    _pageCtrl.animateToPage(_step,
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    // Reload courses each time the user enters the Courses step so a previous
    // API failure doesn't permanently block them.
    if (_step == 2) _loadCourses();
    if (_step == 3) _initCamera();
  }

  void _goBack() {
    if (_step == 0) { Navigator.pop(context); return; }
    if (_step == 3) _disposeCamera();
    setState(() => _step--);
    _pageCtrl.animateToPage(_step,
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  // ── Camera ────────────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    if (_camCtrl != null) return; // guard: don't re-init if already active
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
    _progressTicker = null;
    _camCtrl?.dispose();
    _camCtrl   = null;
    _camReady  = false;
    _autoCapturing = false;
  }

  // Quality score — mirrors SuperAdmin implementation (size + angles + eye openness).
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

  // ── Submit ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      final courses = _selectedFees.entries
          .map((e) => {'course_id': e.key, 'fee_amount': e.value})
          .toList();

      await AcademyApiService.registerStudent({
        'first_name':    _firstNameCtrl.text.trim(),
        'last_name':     _lastNameCtrl.text.trim(),
        'dob':           _dobCtrl.text.isNotEmpty ? _dobCtrl.text : null,
        'gender':        _gender,
        'mobile':        _mobileCtrl.text.trim(),
        'email':         _emailCtrl.text.trim().isNotEmpty ? _emailCtrl.text.trim() : null,
        'parent_name':   _parentNameCtrl.text.trim().isNotEmpty ? _parentNameCtrl.text.trim() : null,
        'parent_mobile': _parentMobCtrl.text.trim().isNotEmpty ? _parentMobCtrl.text.trim() : null,
        'address':       _addressCtrl.text.trim().isNotEmpty ? _addressCtrl.text.trim() : null,
        'courses':       courses,
        'face_images':   _faceImages,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Student registered successfully'),
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

  // ── Build ─────────────────────────────────────────────────────────────────

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
      body: PageView(
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
          _Step3(
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
    );
  }
}

// ── Step 1: Personal Info ─────────────────────────────────────────────────────

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

// ── Step 2: Parent & Address ──────────────────────────────────────────────────

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

// ── Step 3: Course Selection ──────────────────────────────────────────────────
// Uses StatefulWidget so each course fee TextEditingController is stable across
// parent rebuilds — no more controller recreation on every setState.

class _Step3 extends StatefulWidget {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> courses;
  final Map<String, double> selectedFees;
  final void Function(String courseId, double defaultFee, bool selected) onToggle;
  final void Function(String courseId, double fee) onFeeChanged;
  final VoidCallback onNext;
  final VoidCallback onRetry;

  const _Step3({
    required this.loading,
    this.error,
    required this.courses,
    required this.selectedFees,
    required this.onToggle,
    required this.onFeeChanged,
    required this.onNext,
    required this.onRetry,
  });

  @override
  State<_Step3> createState() => _Step3State();
}

class _Step3State extends State<_Step3> {
  // Stable controllers keyed by course ID.
  // Created when a course is first selected; disposed when deselected.
  final Map<String, TextEditingController> _ctrls = {};

  @override
  void didUpdateWidget(_Step3 old) {
    super.didUpdateWidget(old);
    // Create controllers for newly selected courses
    for (final entry in widget.selectedFees.entries) {
      if (!_ctrls.containsKey(entry.key)) {
        _ctrls[entry.key] = TextEditingController(
            text: entry.value.toStringAsFixed(0));
      }
    }
    // Dispose controllers for deselected courses
    final removed = _ctrls.keys
        .where((k) => !widget.selectedFees.containsKey(k))
        .toList();
    for (final k in removed) {
      _ctrls[k]!.dispose();
      _ctrls.remove(k);
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 56,
                  color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text('Could not load courses',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(widget.error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: widget.onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (widget.courses.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.menu_book_outlined, size: 64),
              const SizedBox(height: 12),
              const Text('No courses available.',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Text('Add courses in Course Master first.'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Go Back')),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                      onPressed: widget.onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh')),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: widget.courses.length,
            itemBuilder: (_, i) {
              final c          = widget.courses[i];
              final id         = c['id'] as String;
              final defaultFee = (c['default_fee'] as num).toDouble();
              final selected   = widget.selectedFees.containsKey(id);

              return Card(
                key: ValueKey(id),
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: selected
                      ? BorderSide(color: theme.colorScheme.primary, width: 2)
                      : BorderSide.none,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Checkbox(
                            value: selected,
                            onChanged: (v) =>
                                widget.onToggle(id, defaultFee, v == true),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c['name'] as String,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold)),
                                if (c['subject'] != null)
                                  Text(c['subject'] as String,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: theme.colorScheme.onSurface
                                              .withValues(alpha: 0.6))),
                              ],
                            ),
                          ),
                          Text(
                            '₹${defaultFee.toStringAsFixed(0)}/${c['schedule']}',
                            style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      if (selected) ...[
                        const Divider(),
                        Row(
                          children: [
                            const Text('Fee for this student: ',
                                style: TextStyle(fontSize: 13)),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 110,
                              child: TextFormField(
                                // Stable controller — survives parent rebuilds
                                controller: _ctrls[id],
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                  prefixText: '₹ ',
                                ),
                                onChanged: (v) {
                                  final fee = double.tryParse(v);
                                  if (fee != null) widget.onFeeChanged(id, fee);
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '(Default: ₹${defaultFee.toStringAsFixed(0)})',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.5)),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16,
              MediaQuery.of(context).padding.bottom + 16),
          child: Column(
            children: [
              if (widget.selectedFees.isNotEmpty)
                Text(
                  '${widget.selectedFees.length} course${widget.selectedFees.length > 1 ? 's' : ''} selected  ·  '
                  'Total: ₹${widget.selectedFees.values.fold(0.0, (a, b) => a + b).toStringAsFixed(0)}/mo',
                  style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold),
                ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: widget.selectedFees.isEmpty ? null : widget.onNext,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                child: const Text('Next — Face Capture'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Step 4: Face Capture ──────────────────────────────────────────────────────

class _Step4 extends StatelessWidget {
  final CameraController? camCtrl;
  final bool camReady, done, submitting, autoCapturing;
  final FaceOverlayState overlayState;
  final double holdProgress, qualityScore;
  final String qualityHint;
  final int captureCount, requiredSamples;
  final VoidCallback onCaptureNow, onSubmit, onReset;

  const _Step4({
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
                      child: const Center(
                          child: CircularProgressIndicator(
                              color: Colors.white))),
            ),
          ),
          const SizedBox(height: 12),

          // Status / quality hint
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
              label: Text(submitting ? 'Registering…' : 'Register Student'),
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
