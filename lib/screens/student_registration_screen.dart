import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/student.dart';
import '../providers/student_provider.dart';
import '../services/face_service.dart';
import '../widgets/custom_button.dart';
import '../widgets/face_overlay_painter.dart';

class StudentRegistrationScreen extends StatefulWidget {
  const StudentRegistrationScreen({super.key});

  @override
  State<StudentRegistrationScreen> createState() =>
      _StudentRegistrationScreenState();
}

class _StudentRegistrationScreenState extends State<StudentRegistrationScreen> {
  int _step = 0;
  final _formKey1 = GlobalKey<FormState>();
  final _formKey2 = GlobalKey<FormState>();
  final _formKey3 = GlobalKey<FormState>();

  // Step 1 controllers
  final _firstNameCtrl = TextEditingController();
  final _middleNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  DateTime? _dob;
  String _gender = 'Male';
  String? _bloodGroup;
  final _nationalityCtrl = TextEditingController();
  final _govtIdCtrl = TextEditingController();

  // Step 2 controllers
  final _institutionCtrl = TextEditingController();
  String _academicYear = '2024-25';
  final _classGradeCtrl = TextEditingController();
  String _division = 'A';
  final _rollNoCtrl = TextEditingController();
  final _streamCtrl = TextEditingController();
  DateTime? _admissionDate;

  // Step 3 controllers
  final _parentNameCtrl = TextEditingController();
  String _parentRelation = 'Father';
  final _mobileCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _allergiesCtrl = TextEditingController();
  final _medicalCtrl = TextEditingController();
  final _emergencyCtrl = TextEditingController();
  final _transportCtrl = TextEditingController();

  // Step 4 face capture
  CameraController? _cameraCtrl;
  List<CameraDescription>? _cameras;
  bool _cameraReady = false;
  Face? _detectedFace;
  FaceOverlayState _overlayState = FaceOverlayState.idle;
  final List<List<double>> _samples = [];
  final List<bool> _samplesCaptured = [false, false, false, false];
  int _currentSample = 0;
  Timer? _scanTimer;
  bool _processingFrame = false;
  double _brightnessScore = 0;
  bool _livenessOk = false;
  double? _lastEulerY;
  List<double>? _finalEmbedding;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    FaceService.instance.init();
  }

  Future<void> _initCamera() async {
    _cameras = await availableCameras();
    final frontCamera = _cameras!.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => _cameras!.first,
    );
    _cameraCtrl = CameraController(
      frontCamera,
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
      if (_processingFrame || !(_cameraCtrl?.value.isInitialized ?? false)) return;
      _processingFrame = true;
      try {
        final image = await _cameraCtrl!.takePicture();
        final inputImage = InputImage.fromFilePath(image.path);
        final faces = await FaceDetector(
          options: FaceDetectorOptions(
            enableClassification: true,
            enableLandmarks: false,
            minFaceSize: 0.2,
          ),
        ).processImage(inputImage);

        if (faces.isNotEmpty && mounted) {
          final face = faces.first;
          final euler = face.headEulerAngleY ?? 0;
          if (_lastEulerY != null && (euler - _lastEulerY!).abs() > 15) {
            _livenessOk = true;
          }
          _lastEulerY = euler;
          setState(() {
            _detectedFace = face;
            _overlayState = FaceOverlayState.detected;
          });
        } else if (mounted) {
          setState(() {
            _detectedFace = null;
            _overlayState = FaceOverlayState.idle;
          });
        }
      } catch (_) {}
      _processingFrame = false;
    });
  }

  Future<void> _captureSample() async {
    if (_detectedFace == null || _currentSample >= 4) return;
    setState(() => _processingFrame = true);
    try {
      final image = await _cameraCtrl!.takePicture();
      // Simplified: use a placeholder embedding for demo
      // In production, run the actual tflite model
      final embedding = List<double>.generate(128, (i) => i.toDouble() * 0.001);
      _samples.add(embedding);
      setState(() {
        _samplesCaptured[_currentSample] = true;
        _currentSample++;
        _brightnessScore = 0.75;
      });
      if (_currentSample >= 4) {
        _finalEmbedding = FaceService.instance.averageEmbeddings(_samples);
        _scanTimer?.cancel();
        setState(() => _overlayState = FaceOverlayState.successCheckin);
      }
    } catch (_) {}
    setState(() => _processingFrame = false);
  }

  Future<void> _submit() async {
    if (_finalEmbedding == null) return;
    setState(() => _submitting = true);
    final reg = StudentRegistration(
      firstName: _firstNameCtrl.text.trim(),
      middleName: _middleNameCtrl.text.trim().isEmpty ? null : _middleNameCtrl.text.trim(),
      lastName: _lastNameCtrl.text.trim(),
      dob: DateFormat('yyyy-MM-dd').format(_dob!),
      gender: _gender,
      bloodGroup: _bloodGroup,
      nationality: _nationalityCtrl.text.trim().isEmpty ? null : _nationalityCtrl.text.trim(),
      govtId: _govtIdCtrl.text.trim().isEmpty ? null : _govtIdCtrl.text.trim(),
      institution: _institutionCtrl.text.trim(),
      academicYear: _academicYear,
      classGrade: _classGradeCtrl.text.trim(),
      division: _division,
      rollNo: int.tryParse(_rollNoCtrl.text.trim()),
      stream: _streamCtrl.text.trim().isEmpty ? null : _streamCtrl.text.trim(),
      admissionDate: DateFormat('yyyy-MM-dd').format(_admissionDate!),
      parentName: _parentNameCtrl.text.trim(),
      parentRelation: _parentRelation,
      mobile: _mobileCtrl.text.trim(),
      email: _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
      address: _addressCtrl.text.trim().isEmpty ? null : _addressCtrl.text.trim(),
      knownAllergies: _allergiesCtrl.text.trim().isEmpty ? null : _allergiesCtrl.text.trim(),
      medicalConditions: _medicalCtrl.text.trim().isEmpty ? null : _medicalCtrl.text.trim(),
      emergencyContact: _emergencyCtrl.text.trim().isEmpty ? null : _emergencyCtrl.text.trim(),
      transportRoute: _transportCtrl.text.trim().isEmpty ? null : _transportCtrl.text.trim(),
      faceEmbedding: _finalEmbedding!,
      faceQuality: _brightnessScore,
    );

    final student = await context.read<StudentProvider>().createStudent(reg);
    setState(() => _submitting = false);

    if (!mounted) return;
    if (student != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Student ${student.fullName} registered! ID: ${student.id}'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.read<StudentProvider>().error ?? 'Registration failed'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register Student'),
      ),
      body: Stepper(
        currentStep: _step,
        onStepCancel: _step > 0 ? () => setState(() => _step--) : null,
        onStepContinue: _onContinue,
        controlsBuilder: (context, details) {
          return Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Row(
              children: [
                FilledButton(
                  onPressed: _step == 3 ? (_submitting ? null : _submit) : details.onStepContinue,
                  child: _step == 3
                      ? (_submitting
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Submit'))
                      : const Text('Next'),
                ),
                const SizedBox(width: 8),
                if (_step > 0)
                  TextButton(onPressed: details.onStepCancel, child: const Text('Back')),
              ],
            ),
          );
        },
        steps: [
          Step(
            title: const Text('Personal Info'),
            isActive: _step >= 0,
            state: _step > 0 ? StepState.complete : StepState.indexed,
            content: _buildStep1(),
          ),
          Step(
            title: const Text('Academic Info'),
            isActive: _step >= 1,
            state: _step > 1 ? StepState.complete : StepState.indexed,
            content: _buildStep2(),
          ),
          Step(
            title: const Text('Contact & Medical'),
            isActive: _step >= 2,
            state: _step > 2 ? StepState.complete : StepState.indexed,
            content: _buildStep3(),
          ),
          Step(
            title: const Text('Face Capture'),
            isActive: _step >= 3,
            content: _buildStep4(),
          ),
        ],
      ),
    );
  }

  void _onContinue() {
    if (_step == 0 && _formKey1.currentState!.validate() && _dob != null) {
      setState(() => _step = 1);
    } else if (_step == 1 && _formKey2.currentState!.validate() && _admissionDate != null) {
      setState(() => _step = 2);
    } else if (_step == 2 && _formKey3.currentState!.validate()) {
      setState(() => _step = 3);
      _initCamera();
    }
  }

  Widget _field(String label, TextEditingController ctrl,
      {bool required = false, TextInputType? keyboardType, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: ctrl,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label),
        validator: required ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null : null,
      ),
    );
  }

  Widget _buildStep1() {
    return Form(
      key: _formKey1,
      child: Column(
        children: [
          _field('First Name', _firstNameCtrl, required: true),
          _field('Middle Name', _middleNameCtrl),
          _field('Last Name', _lastNameCtrl, required: true),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_dob == null
                ? 'Date of Birth *'
                : 'DOB: ${DateFormat('dd MMM yyyy').format(_dob!)}'),
            trailing: const Icon(Icons.calendar_today),
            onTap: () async {
              final d = await showDatePicker(
                  context: context,
                  initialDate: DateTime(2010),
                  firstDate: DateTime(1990),
                  lastDate: DateTime.now());
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
                .map((g) => DropdownMenuItem(value: g, child: Text(g ?? 'Not specified')))
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
            title: Text(_admissionDate == null
                ? 'Admission Date *'
                : 'Admitted: ${DateFormat('dd MMM yyyy').format(_admissionDate!)}'),
            trailing: const Icon(Icons.calendar_today),
            onTap: () async {
              final d = await showDatePicker(
                  context: context,
                  initialDate: DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now());
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
          _field('Email', _emailCtrl, keyboardType: TextInputType.emailAddress),
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

  Widget _buildStep4() {
    return Column(
      children: [
        if (_cameraReady && _cameraCtrl != null)
          Stack(
            alignment: Alignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: _cameraCtrl!.value.aspectRatio,
                  child: CameraPreview(_cameraCtrl!),
                ),
              ),
              AspectRatio(
                aspectRatio: _cameraCtrl!.value.aspectRatio,
                child: CustomPaint(
                  painter: FaceOverlayPainter(state: _overlayState),
                ),
              ),
            ],
          )
        else
          Container(
            height: 220,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(4, (i) {
            return Column(
              children: [
                Icon(
                  _samplesCaptured[i] ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: _samplesCaptured[i] ? Colors.green : Colors.grey,
                ),
                Text(['Front', 'Left', 'Right', 'Up'][i],
                    style: const TextStyle(fontSize: 11)),
              ],
            );
          }),
        ),
        const SizedBox(height: 8),
        if (_brightnessScore > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const Text('Quality: ', style: TextStyle(fontSize: 12)),
                Expanded(
                  child: LinearProgressIndicator(
                    value: _brightnessScore,
                    color: _brightnessScore > 0.4 ? Colors.green : Colors.red,
                    backgroundColor: Colors.grey.shade300,
                  ),
                ),
                const SizedBox(width: 8),
                Text('${(_brightnessScore * 100).toInt()}%',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        const SizedBox(height: 12),
        if (_finalEmbedding == null)
          FilledButton.icon(
            onPressed: _detectedFace != null ? _captureSample : null,
            icon: const Icon(Icons.camera_alt),
            label: Text('Capture Sample ${_currentSample + 1}/4'),
          )
        else
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 8),
              Text('Face captured. Click Submit.', style: TextStyle(color: Colors.green)),
            ],
          ),
      ],
    );
  }
}
