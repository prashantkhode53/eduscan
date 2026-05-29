import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/attendance.dart';
import '../models/student.dart';
import '../providers/student_provider.dart';
import '../services/api_service.dart';
import '../services/pdf_service.dart';
import '../widgets/attendance_row.dart';
import 'face_recapture_screen.dart';

class StudentDetailScreen extends StatefulWidget {
  final String studentId;
  const StudentDetailScreen({super.key, required this.studentId});

  @override
  State<StudentDetailScreen> createState() => _StudentDetailScreenState();
}

class _StudentDetailScreenState extends State<StudentDetailScreen> {
  Student? _student;
  AttendanceSummary? _summary;
  List<Attendance> _history = [];
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  bool _reRegisteringFace = false;

  final Map<String, TextEditingController> _editors = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ApiService.getStudentById(widget.studentId);
      _student = Student.fromJson(data['student'] as Map<String, dynamic>);
      _summary = AttendanceSummary.fromJson(
          data['attendance_summary'] as Map<String, dynamic>);
      final attData = await ApiService.getStudentAttendance(widget.studentId);
      _history = (attData['records'] as List)
          .map((e) => Attendance.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}
    setState(() => _loading = false);
  }

  void _startEditing() {
    if (_student == null) return;
    _editors['first_name'] = TextEditingController(text: _student!.firstName);
    _editors['last_name'] = TextEditingController(text: _student!.lastName);
    _editors['mobile'] = TextEditingController(text: _student!.mobile);
    _editors['email'] = TextEditingController(text: _student!.email ?? '');
    _editors['parent_name'] = TextEditingController(text: _student!.parentName);
    _editors['address'] = TextEditingController(text: _student!.address ?? '');
    setState(() => _editing = true);
  }

  Future<void> _saveEdits() async {
    setState(() => _saving = true);
    final fields = _editors.map((k, v) => MapEntry(k, v.text.trim()));
    final updated = await context.read<StudentProvider>().updateStudent(
          widget.studentId,
          fields,
        );
    if (updated != null) {
      setState(() {
        _student = updated;
        _editing = false;
        _saving = false;
      });
      _editors.forEach((_, c) => c.dispose());
      _editors.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Student updated'), backgroundColor: Colors.green),
        );
      }
    } else {
      setState(() => _saving = false);
    }
  }

  Future<void> _reRegisterFace() async {
    final images = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(builder: (_) => const FaceRecaptureScreen()),
    );
    if (images == null || images.isEmpty || !mounted) return;
    setState(() => _reRegisteringFace = true);
    try {
      await ApiService.updateStudentFace(widget.studentId, images);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Face re-registered successfully'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _reRegisteringFace = false);
    }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Deactivate Student'),
        content: Text(
            'Are you sure you want to deactivate ${_student?.fullName}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Deactivate')),
        ],
      ),
    );
    if (confirm == true && mounted) {
      final ok = await context
          .read<StudentProvider>()
          .deleteStudent(widget.studentId);
      if (ok && mounted) Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _editors.forEach((_, c) => c.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_student?.fullName ?? 'Student Detail'),
        actions: [
          if (!_editing && _student != null) ...[
            IconButton(icon: const Icon(Icons.edit_outlined), onPressed: _startEditing),
            IconButton(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed: () async {
                await PdfService.exportStudentReport(_student!, _history);
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              color: Colors.red,
              onPressed: _delete,
            ),
          ],
          if (_editing) ...[
            if (_saving)
              const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
            else
              TextButton(onPressed: _saveEdits, child: const Text('Save')),
            TextButton(
              onPressed: () {
                _editors.forEach((_, c) => c.dispose());
                _editors.clear();
                setState(() => _editing = false);
              },
              child: const Text('Cancel'),
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _student == null
              ? const Center(child: Text('Student not found'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildInfoCard(theme),
                      const SizedBox(height: 16),
                      _buildFaceCard(theme),
                      const SizedBox(height: 16),
                      _buildAttendanceSummaryCard(theme),
                      const SizedBox(height: 16),
                      Text('Attendance History',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      ..._history.map((r) => AttendanceRow(record: r)),
                    ],
                  ),
                ),
    );
  }

  Widget _buildInfoCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: theme.colorScheme.primary.withValues(alpha:0.15),
                  child: Text(
                    _student!.initials,
                    style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 22),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _editing
                          ? Row(children: [
                              Expanded(
                                  child: TextField(
                                      controller: _editors['first_name'],
                                      decoration: const InputDecoration(labelText: 'First Name'))),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: TextField(
                                      controller: _editors['last_name'],
                                      decoration: const InputDecoration(labelText: 'Last Name'))),
                            ])
                          : Text(_student!.fullName,
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                      Text('ID: ${_student!.id}',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(alpha:0.6))),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _infoRow('Class', _student!.classLabel),
            _infoRow('Roll No', _student!.rollNo?.toString() ?? '-'),
            _infoRow('Gender', _student!.gender),
            _infoRow('DOB', _student!.dob),
            _editing
                ? TextField(
                    controller: _editors['mobile'],
                    decoration: const InputDecoration(labelText: 'Mobile'),
                    keyboardType: TextInputType.phone,
                  )
                : _infoRow('Mobile', _student!.mobile),
            _editing
                ? TextField(
                    controller: _editors['email'],
                    decoration: const InputDecoration(labelText: 'Email'),
                  )
                : _infoRow('Email', _student!.email ?? '-'),
            _editing
                ? TextField(
                    controller: _editors['parent_name'],
                    decoration: const InputDecoration(labelText: 'Parent Name'),
                  )
                : _infoRow('Parent', _student!.parentName),
            _infoRow('Institution', _student!.institution),
            _infoRow('Academic Year', _student!.academicYear),
          ],
        ),
      ),
    );
  }

  Widget _buildFaceCard(ThemeData theme) {
    final hasEmbedding = _student!.faceEmbedding.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  hasEmbedding ? Icons.face : Icons.face_retouching_off,
                  color: hasEmbedding ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Text(
                  'Face Recognition',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: hasEmbedding
                        ? Colors.green.withValues(alpha: 0.1)
                        : Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    hasEmbedding ? 'Registered' : 'Not Registered',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: hasEmbedding ? Colors.green : Colors.orange,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (hasEmbedding)
              Text(
                'Face embedding stored (${_student!.faceEmbedding.length}-D). '
                'Student can be identified by face scan.',
                style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
              ),
            if (!hasEmbedding)
              Text(
                'No face registered. Face must be registered during student creation.',
                style: TextStyle(
                    fontSize: 12,
                    color: Colors.orange.shade700),
              ),
            if (hasEmbedding) ...[
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _reRegisteringFace ? null : _reRegisterFace,
                  icon: _reRegisteringFace
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.camera_alt_outlined),
                  label: Text(
                      _reRegisteringFace ? 'Processing face…' : 'Re-register Face'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha:0.5),
                    fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  Widget _buildAttendanceSummaryCard(ThemeData theme) {
    if (_summary == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Attendance Overview',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _summaryChip('Present', _summary!.presentDays.toString(), Colors.green),
                _summaryChip('Absent', _summary!.absentDays.toString(), Colors.red),
                _summaryChip('Late', _summary!.lateDays.toString(), Colors.orange),
                _summaryChip('Total', _summary!.totalDays.toString(), Colors.blue),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _summary!.percentage >= 75
                    ? Colors.green.withValues(alpha:0.1)
                    : Colors.red.withValues(alpha:0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _summary!.percentage >= 75 ? Icons.thumb_up : Icons.warning,
                    color: _summary!.percentage >= 75 ? Colors.green : Colors.red,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_summary!.percentage.toStringAsFixed(1)}% Attendance',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _summary!.percentage >= 75 ? Colors.green : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryChip(String label, String value, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}
