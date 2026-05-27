import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/student.dart';
import '../providers/student_provider.dart';
import '../services/face_service.dart';
import '../widgets/face_overlay_painter.dart';

class StudentRegistrationScreen extends StatefulWidget {
  const StudentRegistrationScreen({super.key});

  @override
  State<StudentRegistrationScreen> createState() =>
      _StudentRegistrationScreenState();
}

class _StudentRegistrationScreenState extends State<StudentRegistrationScreen> {
  int _currentStep = 0;
  final _formKey1 = GlobalKey<FormState>();
  final _formKey2 = GlobalKey<FormState>();
  final _formKey3 = GlobalKey<FormState>();

  // Step 1
  final _firstNameCtrl = TextEditingController();
  final _middleNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  DateTime? _dob;
  String _gender = 'Male';
  String? _bloodGroup;
  final _nationalityCtrl = TextEditingController();
  final _govtIdCtrl = TextEditingController();

  // Step 2
  final _institutionCtrl = TextEditingController();
  String _academicYear = '2024-25';
  final _classGradeCtrl = TextEditingController();
  String _division = 'A';
  final _rollNoCtrl = TextEditingController();
  final _streamCtrl = TextEditingController();
  DateTime? _admissionDate;

  // Step 3
  final _parentNameCtrl = TextEditingController();
  String _parentRelation = 'Father';
  final _mobileCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _allergiesCtrl = TextEditingController();
  final _medicalCtrl = TextEditingController();
  final _emergencyCtrl = TextEditingController();
  final _transportCtrl = TextEditingController();

  // Step 4 — face capture
  CameraController? _cameraCtrl;
  CameraDescription? _frontCamera;
  bool _cameraReady = false;
  Face? _detectedFace;
  FaceOverlayState _overlayState = FaceOverlayState.idle;
  final List<List<double>> _samples = [];
  int _autoCaptures = 0;
  // 5 samples → better averaged embedding, reduces per-sample noise
  static const int _requiredSamples = 5;
  bool _processingFrame = false;
  double _brightnessScore = 0;
  String _qualityHint = '';
  bool _autoCapturing = false;
  double _holdProgress = 0.0;
  Timer? _progressTicker;
  Timer? _nextCaptureTimer;
  List<double>? _finalEmbedding;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
  }

  // ── Validation ─────────────────────────────────────────────────────────────

  bool _validateCurrentStep() {
    switch (_currentStep) {
      case 0:
        if (_firstNameCtrl.text.trim().isEmpty) {
          _snack('First name is required');
          return false;
        }
        if (_lastNameCtrl.text.trim().isEmpty) {
          _snack('Last name is required');
          return false;
        }
        if (_dob == null) {
          _snack('Date of birth is required');
          return false;
        }
        if (!(_formKey1.currentState?.validate() ?? false)) return false;
        return true;

      case 1:
        if (_institutionCtrl.text.trim().isEmpty) {
          _snack('Institution name is required');
          return false;
        }
        if (_classGradeCtrl.text.trim().isEmpty) {
          _snack('Class / Grade is required');
          return false;
        }
        if (_admissionDate == null) {
          _snack('Admission date is required');
          return false;
        }
        if (!(_formKey2.currentState?.validate() ?? false)) return false;
        return true;

      case 2:
        if (_parentNameCtrl.text.trim().isEmpty) {
          _snack('Parent / Guardian name is required');
          return false;
        }
        if (_mobileCtrl.text.trim().isEmpty) {
          _snack('Mobile number is required');
          return false;
        }
        if (!(_formKey3.currentState?.validate() ?? false)) return false;
        return true;

      case 3:
        if (_finalEmbedding == null) {
          _snack('Please complete face capture before submitting');
          return false;
        }
        return true;

      default:
        return true;
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red.shade700),
    );
  }

  // ── Camera ─────────────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    if (_cameraReady) return;
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
    if (_cameraCtrl == null || !(_cameraCtrl!.value.isInitialized)) return;
    _cameraCtrl!.startImageStream((CameraImage image) async {
      if (_processingFrame || _finalEmbedding != null) return;
      _processingFrame = true;
      try {
        final inputImage =
            FaceService.cameraImageToInputImage(image, _frontCamera!);
        if (inputImage == null) {
          _processingFrame = false;
          return;
        }
        final faces = await FaceService.detectFaces(inputImage);
        if (!mounted) {
          _processingFrame = false;
          return;
        }

        if (faces.isNotEmpty) {
          final face = faces.first;
          final quality = _computeQuality(face);
          setState(() {
            _detectedFace = face;
            _brightnessScore = quality;
            _overlayState = quality >= 0.55
                ? FaceOverlayState.detected
                : FaceOverlayState.idle;
          });
          if (quality >= 0.55 && !_autoCapturing) {
            _startHoldTimer();
          } else if (quality < 0.55) {
            _cancelHoldTimer();
          }
        } else {
          setState(() {
            _detectedFace = null;
            _brightnessScore = 0;
            _overlayState = FaceOverlayState.idle;
          });
          _cancelHoldTimer();
        }
      } catch (_) {}
      _processingFrame = false;
    });
  }

  // Quality: weighted score of face size, head angle, roll, eye openness.
  // Returns 0.0 for hard rejects (too tilted / too small) and sets _qualityHint.
  double _computeQuality(Face face) {
    final yaw  = (face.headEulerAngleY ?? 0.0).abs(); // left–right rotation
    final roll = (face.headEulerAngleZ ?? 0.0).abs(); // clockwise tilt

    // Hard-reject faces that are too tilted — embedding would be unreliable
    if (yaw > 25) {
      _qualityHint = 'Look straight ahead (turn less)';
      return 0.0;
    }
    if (roll > 20) {
      _qualityHint = 'Hold your head level (tilt less)';
      return 0.0;
    }

    // Face must be large enough in frame (at least 80px wide)
    final sizeScore = ((face.boundingBox.width - 80) / 120).clamp(0.0, 1.0);
    if (sizeScore < 0.05) {
      _qualityHint = 'Move closer to the camera';
      return 0.0;
    }

    final angleScore = (1.0 - yaw / 25.0).clamp(0.0, 1.0);
    final rollScore  = (1.0 - roll / 20.0).clamp(0.0, 1.0);
    final eyeScore   = ((face.leftEyeOpenProbability  ?? 1.0) +
                        (face.rightEyeOpenProbability ?? 1.0)) / 2.0;

    final score = (sizeScore * 0.40 + angleScore * 0.30 + rollScore * 0.15 + eyeScore * 0.15)
        .clamp(0.0, 1.0);

    if (score < 0.55) {
      _qualityHint = sizeScore < 0.3
          ? 'Move closer to the camera'
          : 'Face the camera directly';
    } else {
      _qualityHint = '';
    }
    return score;
  }

  void _startHoldTimer() {
    if (_autoCapturing) return;
    _autoCapturing = true;
    _holdProgress = 0.0;
    const holdMs = 1500;
    const tickMs = 50;
    int elapsed = 0;

    _progressTicker =
        Timer.periodic(const Duration(milliseconds: tickMs), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      elapsed += tickMs;
      setState(() => _holdProgress = (elapsed / holdMs).clamp(0.0, 1.0));
      if (elapsed >= holdMs) {
        t.cancel();
        _progressTicker = null;
        _doAutoCapture();
      }
    });
  }

  void _cancelHoldTimer() {
    _progressTicker?.cancel();
    _progressTicker = null;
    _nextCaptureTimer?.cancel();
    _nextCaptureTimer = null;
    _autoCapturing = false;
    if (mounted) setState(() => _holdProgress = 0.0);
  }

  void _doAutoCapture() {
    if (!mounted || _detectedFace == null || _finalEmbedding != null) {
      _autoCapturing = false;
      return;
    }
    _captureFromFace(_detectedFace!);
  }

  void _captureNow() {
    if (_detectedFace == null || _finalEmbedding != null || _autoCapturing) {
      return;
    }
    _cancelHoldTimer();
    _autoCapturing = true;
    _captureFromFace(_detectedFace!);
  }

  void _captureFromFace(Face face) {
    final embedding = FaceService.generateEmbedding(face);
    _samples.add(embedding);
    _autoCaptures++;
    _holdProgress = 0.0;

    if (_autoCaptures >= _requiredSamples) {
      _finalEmbedding = FaceService.averageEmbeddings(_samples);
      _autoCapturing = false;
      if (mounted) {
        setState(() {
          _brightnessScore = _computeQuality(face);
          _overlayState = FaceOverlayState.successCheckin;
        });
      }
    } else {
      if (mounted) setState(() {});
      // Take next sample 400ms later while face is still in view
      _nextCaptureTimer = Timer(const Duration(milliseconds: 400), () {
        if (!mounted || _detectedFace == null || _finalEmbedding != null) {
          _autoCapturing = false;
          return;
        }
        _captureFromFace(_detectedFace!);
      });
    }
  }

  void _redoCapture() {
    _cancelHoldTimer();
    setState(() {
      _finalEmbedding = null;
      _samples.clear();
      _autoCaptures = 0;
      _overlayState = FaceOverlayState.idle;
      _brightnessScore = 0;
      _detectedFace = null;
    });
    // Restart stream if it was stopped or is not running
    try {
      _startStream();
    } catch (_) {}
  }

  // ── Submit ─────────────────────────────────────────────────────────────────

  Future<void> _submitRegistration() async {
    if (_finalEmbedding == null) return;
    setState(() => _submitting = true);
    final reg = StudentRegistration(
      firstName: _firstNameCtrl.text.trim(),
      middleName: _middleNameCtrl.text.trim().isEmpty
          ? null
          : _middleNameCtrl.text.trim(),
      lastName: _lastNameCtrl.text.trim(),
      dob: DateFormat('yyyy-MM-dd').format(_dob!),
      gender: _gender,
      bloodGroup: _bloodGroup,
      nationality: _nationalityCtrl.text.trim().isEmpty
          ? null
          : _nationalityCtrl.text.trim(),
      govtId:
          _govtIdCtrl.text.trim().isEmpty ? null : _govtIdCtrl.text.trim(),
      institution: _institutionCtrl.text.trim(),
      academicYear: _academicYear,
      classGrade: _classGradeCtrl.text.trim(),
      division: _division,
      rollNo: int.tryParse(_rollNoCtrl.text.trim()),
      stream:
          _streamCtrl.text.trim().isEmpty ? null : _streamCtrl.text.trim(),
      admissionDate: DateFormat('yyyy-MM-dd').format(_admissionDate!),
      parentName: _parentNameCtrl.text.trim(),
      parentRelation: _parentRelation,
      mobile: _mobileCtrl.text.trim(),
      email: _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
      address:
          _addressCtrl.text.trim().isEmpty ? null : _addressCtrl.text.trim(),
      knownAllergies: _allergiesCtrl.text.trim().isEmpty
          ? null
          : _allergiesCtrl.text.trim(),
      medicalConditions:
          _medicalCtrl.text.trim().isEmpty ? null : _medicalCtrl.text.trim(),
      emergencyContact: _emergencyCtrl.text.trim().isEmpty
          ? null
          : _emergencyCtrl.text.trim(),
      transportRoute: _transportCtrl.text.trim().isEmpty
          ? null
          : _transportCtrl.text.trim(),
      faceEmbedding: _finalEmbedding!,
      faceQuality: _brightnessScore,
    );

    final student =
        await context.read<StudentProvider>().createStudent(reg);
    setState(() => _submitting = false);

    if (!mounted) return;
    if (student != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Student ${student.fullName} registered! ID: ${student.id}'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop(true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              context.read<StudentProvider>().error ?? 'Registration failed'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  void dispose() {
    _progressTicker?.cancel();
    _nextCaptureTimer?.cancel();
    _cameraCtrl?.dispose();
    _firstNameCtrl.dispose();
    _middleNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _nationalityCtrl.dispose();
    _govtIdCtrl.dispose();
    _institutionCtrl.dispose();
    _classGradeCtrl.dispose();
    _rollNoCtrl.dispose();
    _streamCtrl.dispose();
    _parentNameCtrl.dispose();
    _mobileCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    _allergiesCtrl.dispose();
    _medicalCtrl.dispose();
    _emergencyCtrl.dispose();
    _transportCtrl.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Register Student')),
      body: Stepper(
        currentStep: _currentStep,
        onStepContinue: () {
          if (_validateCurrentStep()) {
            if (_currentStep < 3) {
              setState(() => _currentStep++);
              if (_currentStep == 3) _initCamera();
            } else {
              _submitRegistration();
            }
          }
        },
        onStepCancel: () {
          if (_currentStep > 0) setState(() => _currentStep--);
        },
        onStepTapped: (step) {
          if (step < _currentStep) setState(() => _currentStep = step);
        },
        controlsBuilder: (context, details) {
          return Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _currentStep == 3 && _submitting
                        ? null
                        : details.onStepContinue,
                    child: _currentStep == 3
                        ? (_submitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Submit'))
                        : const Text('Next'),
                  ),
                ),
                if (_currentStep > 0) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: details.onStepCancel,
                      child: const Text('Back'),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
        steps: [
          Step(
            title: const Text('Personal Info'),
            isActive: _currentStep >= 0,
            state:
                _currentStep > 0 ? StepState.complete : StepState.indexed,
            content: _buildStep1(),
          ),
          Step(
            title: const Text('Academic Info'),
            isActive: _currentStep >= 1,
            state:
                _currentStep > 1 ? StepState.complete : StepState.indexed,
            content: _buildStep2(),
          ),
          Step(
            title: const Text('Contact & Medical'),
            isActive: _currentStep >= 2,
            state:
                _currentStep > 2 ? StepState.complete : StepState.indexed,
            content: _buildStep3(),
          ),
          Step(
            title: const Text('Face Capture'),
            isActive: _currentStep >= 3,
            content: _buildStep4(),
          ),
        ],
      ),
    );
  }

  // ── Step content ───────────────────────────────────────────────────────────

  Widget _field(String label, TextEditingController ctrl,
      {bool required = false,
      TextInputType? keyboardType,
      int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: ctrl,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label),
        validator: required
            ? (v) =>
                (v == null || v.trim().isEmpty) ? '$label is required' : null
            : null,
      ),
    );
  }

  Widget _buildStep1() {
    return Form(
      key: _formKey1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field('First Name', _firstNameCtrl, required: true),
          _field('Middle Name', _middleNameCtrl),
          _field('Last Name', _lastNameCtrl, required: true),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              _dob == null
                  ? 'Date of Birth *'
                  : 'DOB: ${DateFormat('dd MMM yyyy').format(_dob!)}',
              style: TextStyle(
                  color: _dob == null ? Colors.grey.shade600 : null),
            ),
            trailing: const Icon(Icons.calendar_today),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: DateTime(2010),
                firstDate: DateTime(1990),
                lastDate: DateTime.now(),
              );
              if (d != null) setState(() => _dob = d);
            },
          ),
          DropdownButtonFormField<String>(
            value: _gender,
            decoration: const InputDecoration(labelText: 'Gender'),
            items: ['Male', 'Female', 'Other']
                .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                .toList(),
            onChanged: (v) => setState(() => _gender = v!),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            value: _bloodGroup,
            decoration: const InputDecoration(labelText: 'Blood Group'),
            items: [null, 'A+', 'A-', 'B+', 'B-', 'O+', 'O-', 'AB+', 'AB-']
                .map((g) => DropdownMenuItem(
                    value: g, child: Text(g ?? 'Not specified')))
                .toList(),
            onChanged: (v) => setState(() => _bloodGroup = v),
          ),
          const SizedBox(height: 12),
          _field('Nationality', _nationalityCtrl),
          _field('Aadhaar / Govt ID', _govtIdCtrl),
        ],
      ),
    );
  }

  Widget _buildStep2() {
    return Form(
      key: _formKey2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field('Institution Name', _institutionCtrl, required: true),
          DropdownButtonFormField<String>(
            value: _academicYear,
            decoration: const InputDecoration(labelText: 'Academic Year'),
            items: ['2024-25', '2025-26', '2026-27']
                .map((y) => DropdownMenuItem(value: y, child: Text(y)))
                .toList(),
            onChanged: (v) => setState(() => _academicYear = v!),
          ),
          const SizedBox(height: 12),
          _field('Class / Grade', _classGradeCtrl, required: true),
          DropdownButtonFormField<String>(
            value: _division,
            decoration: const InputDecoration(labelText: 'Division'),
            items: ['A', 'B', 'C', 'D']
                .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                .toList(),
            onChanged: (v) => setState(() => _division = v!),
          ),
          const SizedBox(height: 12),
          _field('Roll Number', _rollNoCtrl,
              keyboardType: TextInputType.number),
          _field('Stream / Medium', _streamCtrl),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              _admissionDate == null
                  ? 'Admission Date *'
                  : 'Admitted: ${DateFormat('dd MMM yyyy').format(_admissionDate!)}',
              style: TextStyle(
                  color: _admissionDate == null
                      ? Colors.grey.shade600
                      : null),
            ),
            trailing: const Icon(Icons.calendar_today),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime.now(),
              );
              if (d != null) setState(() => _admissionDate = d);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildStep3() {
    return Form(
      key: _formKey3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field('Parent / Guardian Name', _parentNameCtrl, required: true),
          DropdownButtonFormField<String>(
            value: _parentRelation,
            decoration: const InputDecoration(labelText: 'Relation'),
            items: ['Father', 'Mother', 'Guardian', 'Other']
                .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                .toList(),
            onChanged: (v) => setState(() => _parentRelation = v!),
          ),
          const SizedBox(height: 12),
          _field('Mobile (+91)', _mobileCtrl,
              required: true, keyboardType: TextInputType.phone),
          _field('Email', _emailCtrl,
              keyboardType: TextInputType.emailAddress),
          _field('Residential Address', _addressCtrl, maxLines: 2),
          _field('Known Allergies', _allergiesCtrl),
          _field('Medical Conditions', _medicalCtrl),
          _field('Emergency Contact', _emergencyCtrl,
              keyboardType: TextInputType.phone),
          _field('Transport Route', _transportCtrl),
        ],
      ),
    );
  }

  String get _captureStatusMessage {
    if (_finalEmbedding != null) return 'Face captured! Ready to submit.';
    if (_autoCapturing) return 'Capturing sample ${_autoCaptures + 1} of $_requiredSamples — hold still...';
    if (_detectedFace != null) {
      if (_brightnessScore >= 0.55) return 'Face detected — hold still for auto-capture';
      return _qualityHint.isNotEmpty ? _qualityHint : 'Face the camera directly';
    }
    return 'Position your face in the oval above';
  }

  Widget _buildStep4() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Camera preview with overlay
        AspectRatio(
          aspectRatio: _cameraCtrl?.value.aspectRatio ?? 0.75,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
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
        const SizedBox(height: 12),

        // Status message
        Center(
          child: Text(
            _captureStatusMessage,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: _finalEmbedding != null
                  ? Colors.green
                  : (_detectedFace != null && _brightnessScore >= 0.55)
                      ? theme.colorScheme.primary
                      : Colors.grey.shade600,
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Quality bar
        if (_brightnessScore > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                const Text('Quality: ',
                    style: TextStyle(fontSize: 12)),
                Expanded(
                  child: LinearProgressIndicator(
                    value: _brightnessScore,
                    color: _brightnessScore >= 0.5
                        ? Colors.green
                        : Colors.orange,
                    backgroundColor: Colors.grey.shade200,
                  ),
                ),
                const SizedBox(width: 8),
                Text('${(_brightnessScore * 100).toInt()}%',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        const SizedBox(height: 12),

        // Sample progress dots
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(_requiredSamples, (i) {
            final done = i < _autoCaptures;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 6),
              width: done ? 20 : 13,
              height: done ? 20 : 13,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? Colors.green : Colors.grey.shade300,
                boxShadow: done
                    ? [
                        BoxShadow(
                            color: Colors.green.withValues(alpha: 0.4),
                            blurRadius: 6)
                      ]
                    : null,
              ),
              child: done
                  ? const Icon(Icons.check, size: 12, color: Colors.white)
                  : null,
            );
          }),
        ),
        const SizedBox(height: 16),

        // Action area
        if (_finalEmbedding == null) ...[
          ElevatedButton.icon(
            onPressed: (_detectedFace != null && !_autoCapturing)
                ? _captureNow
                : null,
            icon: const Icon(Icons.camera_alt),
            label: Text(
                _autoCapturing ? 'Capturing...' : 'Capture Now'),
          ),
          if (_cameraReady && _detectedFace == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Auto-captures when your face is detected',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ),
        ] else ...[
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 20),
              SizedBox(width: 8),
              Text(
                'Face captured. Tap Submit.',
                style: TextStyle(
                    color: Colors.green, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _redoCapture,
            child: Text('Redo capture',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          ),
        ],
      ],
    );
  }
}
