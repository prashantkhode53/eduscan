import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../providers/academic_year_provider.dart';
import '../../services/academy_api_service.dart';

/// One-Click Attendance
///
/// Admin flow:
///   1. Choose Check In or Check Out
///   2. Pick academic year -> course
///   3. Capture or upload one or more group photos of the classroom
///   4. Each photo is scanned server-side; every detected face is matched
///      against the course roster. Unique students accumulate across photos.
///   5. Review: matched list (with confidence), not-detected list (tap to
///      mark manually).
///   6. Approve -> attendance recorded for everyone in one shot.
///
/// Check In writes time_in; Check Out writes time_out + duration for the
/// students who are already checked in today (the server skips anyone who
/// isn't, and never overwrites an existing check-out).
class OneClickAttendanceScreen extends StatefulWidget {
  const OneClickAttendanceScreen({super.key});

  @override
  State<OneClickAttendanceScreen> createState() =>
      _OneClickAttendanceScreenState();
}

class _MatchedStudent {
  final String id;
  final String firstName;
  final String lastName;
  double confidence;
  bool manual;
  bool included; // admin can untick a false positive before approval

  _MatchedStudent({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.confidence,
    this.manual = false,
    this.included = true,
  });

  String get fullName => '$firstName $lastName'.trim();
}

class _OneClickAttendanceScreenState extends State<OneClickAttendanceScreen> {
  final _picker = ImagePicker();

  // Step 1 — what this pass records: 'checkin' or 'checkout'
  String _mode = 'checkin';
  bool get _isCheckout => _mode == 'checkout';

  // Step 2 — selection
  String? _yearId;
  List<dynamic> _courses = [];
  bool _loadingCourses = false;
  String? _courseId;
  String _courseName = '';

  // Roster (loaded once a course is chosen)
  List<Map<String, dynamic>> _roster = [];
  int _rosterWithFace = 0;
  int _rosterCheckedIn = 0;  // students with a time_in today
  int _rosterCheckedOut = 0; // students already checked out today

  // Step 2/3 — photos & scanning
  final List<XFile> _photos = [];
  bool _scanning = false;
  int _scanIndex = 0; // 1-based photo currently being scanned
  int _facesSeen = 0;
  int _unmatchedFaces = 0;
  bool _scanned = false; // at least one scan pass completed

  // Accumulated unique matches across all photos
  final Map<String, _MatchedStudent> _matches = {};

  // Step 5 — approval
  bool _approving = false;

  // Review filter: what the results section shows.
  // 'all' = both cards, 'present' = matched only, 'absent' = absentees only.
  String _viewFilter = 'all';

  /// Students who will NOT be recorded if approved right now: everyone on the
  /// roster who was not detected in any photo, plus any matched student the
  /// admin has unticked.
  List<Map<String, dynamic>> get _absentees {
    final presentIds = _matches.values
        .where((m) => m.included)
        .map((m) => m.id)
        .toSet();
    return _roster
        .where((s) => !presentIds.contains(s['id']))
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initYear());
  }

  Future<void> _initYear() async {
    final yp = context.read<AcademicYearProvider>();
    await yp.init();
    if (!mounted) return;
    setState(() => _yearId = yp.selectedId ?? _firstYearId(yp));
    if (_yearId != null) _loadCourses();
  }

  String? _firstYearId(AcademicYearProvider yp) =>
      yp.years.isNotEmpty ? yp.years.first['id'] as String? : null;

  Future<void> _loadCourses() async {
    setState(() {
      _loadingCourses = true;
      _courses = [];
      _courseId = null;
      _resetScanState();
    });
    try {
      final courses =
          await AcademyApiService.getCourses(academicYearId: _yearId);
      if (!mounted) return;
      setState(() => _courses = courses);
    } catch (e) {
      if (mounted) _snack('Failed to load courses: $e', error: true);
    } finally {
      if (mounted) setState(() => _loadingCourses = false);
    }
  }

  Future<void> _loadRoster() async {
    if (_courseId == null) return;
    try {
      final data = await AcademyApiService.getGroupScanRoster(_courseId!);
      if (!mounted) return;
      setState(() {
        _roster = (data['students'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        _rosterById = {for (final s in _roster) s['id'] as String: s};
        _rosterWithFace = data['with_face'] as int? ?? 0;
        _rosterCheckedIn = data['checked_in'] as int? ?? 0;
        _rosterCheckedOut = data['checked_out'] as int? ?? 0;
      });
    } catch (e) {
      if (mounted) _snack('Failed to load class roster: $e', error: true);
    }
  }

  void _resetScanState() {
    _photos.clear();
    _matches.clear();
    _roster = [];
    _rosterById = {};
    _rosterWithFace = 0;
    _rosterCheckedIn = 0;
    _rosterCheckedOut = 0;
    _facesSeen = 0;
    _unmatchedFaces = 0;
    _scanned = false;
    _viewFilter = 'all';
  }

  /// Today's attendance state by student id (rebuilt with every roster load).
  Map<String, Map<String, dynamic>> _rosterById = {};

  Map<String, dynamic>? _rosterEntry(String studentId) =>
      _rosterById[studentId];

  /// Check-out only: why (if at all) this student cannot be checked out now.
  /// Mirrors the server rule — a check-out needs a check-in and must not
  /// overwrite an existing one.
  String? _checkoutBlocker(String studentId) {
    if (!_isCheckout) return null;
    final s = _rosterEntry(studentId);
    if (s == null) return null;
    if (s['checked_in'] != true) return 'Not checked in today';
    if (s['checked_out'] == true) return 'Already checked out';
    return null;
  }

  /// Included matches that the server will skip in check-out mode.
  List<_MatchedStudent> get _blockedForCheckout => _matches.values
      .where((m) => m.included && _checkoutBlocker(m.id) != null)
      .toList(growable: false);

  // ── Photo capture / upload ──────────────────────────────────────────────

  Future<void> _addFromCamera() async {
    final shot = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 2048, // keep back-row faces; server detects at 1280
      imageQuality: 88,
    );
    if (shot != null) setState(() => _photos.add(shot));
  }

  Future<void> _addFromGallery() async {
    final picked = await _picker.pickMultiImage(
      maxWidth: 2048,
      imageQuality: 88,
    );
    if (picked.isNotEmpty) setState(() => _photos.addAll(picked));
  }

  // ── Scanning ────────────────────────────────────────────────────────────

  Future<void> _scanAll() async {
    if (_courseId == null || _photos.isEmpty) return;
    setState(() {
      _scanning = true;
      _scanIndex = 0;
      _facesSeen = 0;
      _unmatchedFaces = 0;
    });

    if (_roster.isEmpty) await _loadRoster();

    try {
      for (var i = 0; i < _photos.length; i++) {
        if (!mounted) return;
        setState(() => _scanIndex = i + 1);

        final bytes = await File(_photos[i].path).readAsBytes();
        final data = await AcademyApiService.groupScanPhoto(
          courseId: _courseId!,
          imageBase64: base64Encode(bytes),
        );

        _facesSeen += (data['faces_usable'] as int? ?? 0);
        _unmatchedFaces += (data['unmatched_faces'] as int? ?? 0);

        for (final m in (data['matches'] as List<dynamic>? ?? [])) {
          final id = m['student_id'] as String;
          final conf = (m['confidence'] as num?)?.toDouble() ?? 0;
          final existing = _matches[id];
          if (existing == null || conf > existing.confidence) {
            _matches[id] = _MatchedStudent(
              id: id,
              firstName: m['first_name'] as String? ?? '',
              lastName: m['last_name'] as String? ?? '',
              confidence: conf,
              included: existing?.included ?? true,
            );
          }
        }
        if (mounted) setState(() {}); // progressive results
      }
      setState(() => _scanned = true);
    } catch (e) {
      _snack('Scan failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  // ── Approval ────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _notDetected {
    final matchedIds = _matches.keys.toSet();
    return _roster
        .where((s) => !matchedIds.contains(s['id']))
        .toList(growable: false);
  }

  Future<void> _approve() async {
    final included =
        _matches.values.where((m) => m.included).toList(growable: false);
    if (included.isEmpty) {
      _snack(
        _isCheckout
            ? 'No students selected to check out.'
            : 'No students selected to mark present.',
        error: true,
      );
      return;
    }

    // In check-out mode the server skips anyone without a check-in (or already
    // checked out) — warn before the request so the numbers are never a surprise.
    final blocked = _blockedForCheckout;
    final willRecord = included.length - blocked.length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_isCheckout ? 'Approve check-out?' : 'Approve attendance?'),
        content: SingleChildScrollView(
          child: Text(
            _isCheckout
                ? 'Record CHECK-OUT for $willRecord '
                    'student${willRecord == 1 ? '' : 's'} of $_courseName now?\n\n'
                    '${blocked.isEmpty ? '' : '${blocked.length} selected student(s) will be skipped '
                        '(no check-in today, or already checked out):\n'
                        '${blocked.take(8).map((m) => '• ${m.fullName}').join('\n')}'
                        '${blocked.length > 8 ? '\n…and ${blocked.length - 8} more' : ''}\n\n'}'
                    '${_absentees.length} student(s) will not be checked out.'
                : 'Mark ${included.length} student${included.length == 1 ? '' : 's'} '
                    'PRESENT for $_courseName today?\n\n'
                    '${_absentees.length} student(s) will remain absent:\n'
                    '${_absentees.take(8).map((s) => '• ${s['first_name'] ?? ''} ${s['last_name'] ?? ''}'.trim()).join('\n')}'
                    '${_absentees.length > 8 ? '\n…and ${_absentees.length - 8} more' : ''}',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Approve')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _approving = true);
    try {
      final data = await AcademyApiService.groupScanApprove(
        courseId: _courseId!,
        mode: _mode,
        entries: included
            .map((m) => {
                  'student_id': m.id,
                  if (!m.manual) 'confidence': m.confidence,
                  if (m.manual) 'manual': true,
                })
            .toList(),
      );
      if (!mounted) return;
      final marked = data['marked'] ?? included.length;
      final noCheckin = (data['not_checked_in'] as List<dynamic>? ?? []).length;
      final alreadyOut =
          (data['already_checked_out'] as List<dynamic>? ?? []).length;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(_isCheckout ? Icons.logout : Icons.check_circle,
              color: Colors.green, size: 48),
          title: Text(_isCheckout ? 'Check-out recorded' : 'Attendance recorded'),
          content: Text(
            _isCheckout
                ? '$marked student(s) checked out of $_courseName.'
                    '${noCheckin > 0 ? '\n\n$noCheckin skipped — no check-in today.' : ''}'
                    '${alreadyOut > 0 ? '\n$alreadyOut were already checked out.' : ''}'
                : '$marked student(s) marked present for $_courseName.',
          ),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done')),
          ],
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _snack('Approval failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _approving = false);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final yp = context.watch<AcademicYearProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('One-Click Attendance')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Step 1: Check in or check out ─────────────────────────────
          Text('1. What are you recording?',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'checkin',
                  icon: Icon(Icons.login),
                  label: Text('Check In'),
                ),
                ButtonSegment(
                  value: 'checkout',
                  icon: Icon(Icons.logout),
                  label: Text('Check Out'),
                ),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              onSelectionChanged: (_scanning || _approving)
                  ? null
                  : (s) {
                      setState(() {
                        _mode = s.first;
                        _viewFilter = 'all';
                      });
                      // Refresh today's check-in/out flags for the new mode.
                      if (_courseId != null) _loadRoster();
                    },
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _isCheckout
                ? 'Records exit time and duration for students who are already '
                    'checked in today.'
                : 'Records arrival time and marks the detected students present.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),

          // ── Step 2: Academic year & course ────────────────────────────
          const SizedBox(height: 24),
          Text('2. Select class',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _yearId,
            decoration: const InputDecoration(
              labelText: 'Academic Year',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: yp.years
                .map((y) => DropdownMenuItem(
                      value: y['id'] as String,
                      child: Text(y['academic_year_name'] as String? ?? ''),
                    ))
                .toList(),
            onChanged: _scanning
                ? null
                : (v) {
                    setState(() => _yearId = v);
                    _loadCourses();
                  },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _courseId,
            decoration: InputDecoration(
              labelText: _loadingCourses ? 'Loading courses…' : 'Course',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            items: _courses
                .map((c) => DropdownMenuItem(
                      value: c['id'] as String,
                      child: Text(c['name'] as String? ?? ''),
                    ))
                .toList(),
            onChanged: (_loadingCourses || _scanning)
                ? null
                : (v) {
                    setState(() {
                      _courseId = v;
                      _courseName = (_courses.firstWhere(
                              (c) => c['id'] == v,
                              orElse: () => {'name': ''})['name'] as String?) ??
                          '';
                      _resetScanState();
                    });
                    _loadRoster();
                  },
          ),
          if (_courseId != null && _roster.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${_roster.length} students in this course • '
              '$_rosterWithFace with registered faces'
              '${_isCheckout ? '\n$_rosterCheckedIn checked in today • $_rosterCheckedOut already checked out' : ''}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor),
            ),
          ],

          // Nobody can be checked out until someone has checked in.
          if (_isCheckout && _courseId != null && _roster.isNotEmpty &&
              _rosterCheckedIn == 0) ...[
            const SizedBox(height: 12),
            _noticeBox(
              icon: Icons.info_outline,
              color: Colors.orange,
              text: 'No student in this course has checked in today, so there '
                  'is nobody to check out yet. Run Check In first.',
            ),
          ],

          // ── Step 3: Photos ────────────────────────────────────────────
          if (_courseId != null) ...[
            const SizedBox(height: 24),
            Text('3. Class photos',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Take or upload photos of the classroom. Use 2–3 photos from '
              'different angles so every face is visible in at least one.',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _scanning ? null : _addFromCamera,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Camera'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _scanning ? null : _addFromGallery,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Upload'),
                ),
              ),
            ]),
            if (_photos.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 92,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _photos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(File(_photos[i].path),
                          width: 92, height: 92, fit: BoxFit.cover),
                    ),
                    if (!_scanning)
                      Positioned(
                        top: 2,
                        right: 2,
                        child: GestureDetector(
                          onTap: () => setState(() => _photos.removeAt(i)),
                          child: const CircleAvatar(
                            radius: 11,
                            backgroundColor: Colors.black54,
                            child: Icon(Icons.close,
                                size: 14, color: Colors.white),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed:
                  (_photos.isEmpty || _scanning) ? null : _scanAll,
              icon: _scanning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.face_retouching_natural),
              label: Text(_scanning
                  ? 'Scanning photo $_scanIndex of ${_photos.length}…'
                  : _scanned
                      ? 'Re-scan ${_photos.length} photo(s)'
                      : 'Scan ${_photos.length} photo(s)'),
            ),
          ],

          // ── Step 4/5: Review ──────────────────────────────────────────
          if (_scanned) ...[
            const SizedBox(height: 24),
            Text('4. Review results',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              '$_facesSeen faces analysed • ${_matches.length} unique students '
              'matched • $_unmatchedFaces faces unrecognised',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 12),

            // View filter — lets the admin jump straight to absentees.
            SegmentedButton<String>(
              segments: [
                const ButtonSegment(value: 'all', label: Text('All')),
                ButtonSegment(
                  value: 'present',
                  label: Text(
                      '${_isCheckout ? 'Leaving' : 'Present'} '
                      '(${_matches.values.where((m) => m.included).length})'),
                ),
                ButtonSegment(
                  value: 'absent',
                  label: Text(
                      '${_isCheckout ? 'Staying' : 'Absent'} (${_absentees.length})'),
                ),
              ],
              selected: {_viewFilter},
              onSelectionChanged: (s) =>
                  setState(() => _viewFilter = s.first),
              showSelectedIcon: false,
            ),
            const SizedBox(height: 12),

            // Absentee banner — always visible so the count is never missed.
            if (_absentees.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(children: [
                  Icon(Icons.person_off_outlined,
                      color: Colors.red.shade700, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_absentees.length} of ${_roster.length} students '
                      '${_isCheckout ? 'will not be checked out' : 'will be absent'}',
                      style: TextStyle(
                          color: Colors.red.shade800,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => _viewFilter = 'absent'),
                    child: const Text('View'),
                  ),
                ]),
              ),

            // Check-out only: selected students the server will skip because
            // they have no check-in today (or are already checked out).
            if (_isCheckout && _blockedForCheckout.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _noticeBox(
                  icon: Icons.report_problem_outlined,
                  color: Colors.orange,
                  text: '${_blockedForCheckout.length} selected student(s) '
                      'cannot be checked out (no check-in today, or already '
                      'checked out) and will be skipped.',
                ),
              ),

            // Matched (present) list
            if (_viewFilter != 'absent')
            Card(
              child: Column(children: [
                ListTile(
                  dense: true,
                  leading: Icon(
                      _isCheckout
                          ? Icons.logout
                          : Icons.check_circle_outline,
                      color: Colors.green),
                  title: Text(
                      '${_isCheckout ? 'Checking out' : 'Present'} '
                      '(${_matches.values.where((m) => m.included).length})',
                      style:
                          const TextStyle(fontWeight: FontWeight.bold)),
                ),
                const Divider(height: 1),
                if (_matches.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No students matched. Try clearer or closer '
                        'photos, or check face registrations.'),
                  ),
                ..._sortedMatches.map((m) {
                  final blocker = _checkoutBlocker(m.id);
                  return CheckboxListTile(
                    dense: true,
                    value: m.included,
                    onChanged: _approving
                        ? null
                        : (v) => setState(() => m.included = v ?? true),
                    title: Text(m.fullName),
                    subtitle: Text(
                      blocker ??
                          (m.manual
                              ? 'Marked manually'
                              : 'Match ${(m.confidence * 100).toStringAsFixed(1)}%'),
                      style: blocker == null
                          ? null
                          : TextStyle(color: Colors.orange.shade800),
                    ),
                    secondary: blocker != null
                        ? Icon(Icons.block, color: Colors.orange.shade800)
                        : m.manual
                            ? const Icon(Icons.touch_app_outlined,
                                color: Colors.orange)
                            : Icon(Icons.verified_outlined,
                                color: m.confidence >= 0.75
                                    ? Colors.green
                                    : Colors.orange),
                  );
                }),
              ]),
            ),

            // Not detected list (hidden in present-only view)
            if (_viewFilter != 'present' && _notDetected.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                child: Column(children: [
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.help_outline,
                        color: Colors.orange),
                    title: Text('Not detected (${_notDetected.length})',
                        style:
                            const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(_isCheckout
                        ? 'Tap a name to check the student out manually'
                        : 'Tap a name to mark present manually'),
                  ),
                  const Divider(height: 1),
                  ..._notDetected.map((s) {
                    final blocker = _checkoutBlocker(s['id'] as String);
                    return ListTile(
                      dense: true,
                      title: Text(
                          '${s['first_name'] ?? ''} ${s['last_name'] ?? ''}'
                              .trim()),
                      subtitle: blocker != null
                          ? Text(blocker,
                              style: TextStyle(color: Colors.orange.shade800))
                          : (s['has_face'] == true)
                              ? null
                              : const Text('No face registered',
                                  style: TextStyle(color: Colors.red)),
                      trailing: TextButton(
                        onPressed: (_approving || blocker != null)
                            ? null
                            : () => setState(() {
                                  _matches[s['id'] as String] =
                                      _MatchedStudent(
                                    id: s['id'] as String,
                                    firstName:
                                        s['first_name'] as String? ?? '',
                                    lastName:
                                        s['last_name'] as String? ?? '',
                                    confidence: 0,
                                    manual: true,
                                  );
                                }),
                        child: Text(
                            _isCheckout ? 'Check out' : 'Mark present'),
                      ),
                    );
                  }),
                ]),
              ),
            ],

            // Excluded matches — matched by face but unticked by the admin,
            // so they count as absent. Only shown in the absent view so the
            // absentee list there is complete.
            if (_viewFilter == 'absent' &&
                _matches.values.any((m) => !m.included)) ...[
              const SizedBox(height: 12),
              Card(
                child: Column(children: [
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.remove_circle_outline,
                        color: Colors.red),
                    title: Text(
                        'Excluded by you '
                        '(${_matches.values.where((m) => !m.included).length})',
                        style:
                            const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(_isCheckout
                        ? 'Matched in photos but unticked — stays checked in'
                        : 'Matched in photos but unticked — will be absent'),
                  ),
                  const Divider(height: 1),
                  ..._sortedMatches
                      .where((m) => !m.included)
                      .map((m) => ListTile(
                            dense: true,
                            title: Text(m.fullName),
                            subtitle: Text(
                                'Match ${(m.confidence * 100).toStringAsFixed(1)}%'),
                            trailing: TextButton(
                              onPressed: _approving
                                  ? null
                                  : () => setState(
                                      () => m.included = true),
                              child: const Text('Re-include'),
                            ),
                          )),
                ]),
              ),
            ],

            // ── Step 5: Approve ──────────────────────────────────────────
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _isCheckout
                    ? Colors.indigo.shade600
                    : Colors.green.shade700,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: (_approving ||
                      _matches.values.where((m) => m.included).isEmpty)
                  ? null
                  : _approve,
              icon: _approving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Icon(_isCheckout ? Icons.logout : Icons.task_alt),
              label: Text(_approving
                  ? (_isCheckout
                      ? 'Recording check-out…'
                      : 'Recording attendance…')
                  : (_isCheckout
                      ? 'Approve & Record Check-Out'
                      : 'Approve & Record Attendance')),
            ),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }

  /// Small tinted info/warning strip used by the check-out guidance banners.
  Widget _noticeBox({
    required IconData icon,
    required MaterialColor color,
    required String text,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.shade200),
        ),
        child: Row(children: [
          Icon(icon, color: color.shade700, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: color.shade800, fontWeight: FontWeight.w500)),
          ),
        ]),
      );

  List<_MatchedStudent> get _sortedMatches {
    final list = _matches.values.toList(growable: false);
    return [...list]..sort((a, b) => a.fullName.compareTo(b.fullName));
  }
}
