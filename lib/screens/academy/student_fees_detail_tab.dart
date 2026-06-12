import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';
import '../../services/fee_pdf_service.dart';
import '../../providers/auth_provider.dart';
import '../../utils/fee_format.dart';
import 'package:provider/provider.dart';

/// "By Student" tab of Fees Management.
///
/// Flow: pick a course (searchable) -> see the students enrolled in it ->
/// tap a student to open their full fee + installment history.
class StudentFeesDetailTab extends StatefulWidget {
  const StudentFeesDetailTab({super.key});

  @override
  State<StudentFeesDetailTab> createState() => _StudentFeesDetailTabState();
}

class _StudentFeesDetailTabState extends State<StudentFeesDetailTab>
    with AutomaticKeepAliveClientMixin {
  // Keep the picked course / loaded students when switching between tabs.
  @override
  bool get wantKeepAlive => true;

  // ── Courses ────────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _courses = [];
  bool _loadingCourses = true;
  String? _coursesError;

  // ── Selected course ──────────────────────────────────────────────────────────
  String? _courseId;
  String? _courseName;

  // ── Students in the selected course ──────────────────────────────────────────
  List<Map<String, dynamic>> _students = [];
  bool _loadingStudents = false;
  String? _studentsError;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadCourses();
    _loadStudents(); // load all students immediately; course picker is optional filter
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCourses() async {
    if (!mounted) return;
    setState(() { _loadingCourses = true; _coursesError = null; });
    try {
      final data = await AcademyApiService.getCourses();
      if (!mounted) return;
      setState(() {
        _courses = data.cast<Map<String, dynamic>>();
        _loadingCourses = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _coursesError = e.toString().replaceFirst('Exception: ', '');
        _loadingCourses = false;
      });
    }
  }

  Future<void> _selectCourse(Map<String, dynamic> course) async {
    setState(() {
      _courseId   = course['id'] as String?;
      _courseName = course['name'] as String?;
      _students   = [];
      _studentsError = null;
      _query = '';
      _searchCtrl.clear();
    });
    await _loadStudents();
  }

  Future<void> _loadStudents() async {
    if (!mounted) return;
    setState(() { _loadingStudents = true; _studentsError = null; });
    try {
      final data = await AcademyApiService.getStudents(
          courseId: _courseId, limit: 500);
      if (!mounted) return;
      setState(() {
        _students = (data['students'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        _loadingStudents = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _studentsError = e.toString().replaceFirst('Exception: ', '');
        _loadingStudents = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredStudents {
    if (_query.isEmpty) return _students;
    final q = _query.toLowerCase();
    return _students.where((s) {
      final name   = '${s['first_name'] ?? ''} ${s['last_name'] ?? ''}'.toLowerCase();
      final mobile = (s['mobile'] as String? ?? '').toLowerCase();
      final id     = (s['id'] as String? ?? '').toLowerCase();
      return name.contains(q) || mobile.contains(q) || id.contains(q);
    }).toList();
  }

  void _openCoursePicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _CoursePickerSheet(
        courses: _courses,
        selectedId: _courseId,
        onSelected: (c) {
          Navigator.pop(context);
          _selectCourse(c);
        },
      ),
    );
  }

  void _openStudent(Map<String, dynamic> student) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StudentFeeDetailScreen(
          studentId:   student['id'] as String,
          studentName: '${student['first_name'] ?? ''} ${student['last_name'] ?? ''}'.trim(),
          mobile:      student['mobile'] as String? ?? '',
          courseId:    _courseId,
          courseName:  _courseName,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // for AutomaticKeepAlive
    final theme = Theme.of(context);

    return Column(
      children: [
        // ── Course picker ────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: _CoursePickerField(
            label: _courseName,
            loading: _loadingCourses,
            error: _coursesError,
            onTap: _loadingCourses || _coursesError != null ? null : _openCoursePicker,
            onRetry: _loadCourses,
          ),
        ),

        // ── Student list ─────────────────────────────────────────────────────
        Expanded(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search students by name, ID or mobile',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _query.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                            })
                        : null,
                    isDense: true,
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerLow,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Expanded(child: _buildStudentList(theme)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStudentList(ThemeData theme) {
    if (_loadingStudents) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_studentsError != null) {
      return _ErrorState(message: _studentsError!, onRetry: _loadStudents);
    }
    if (_students.isEmpty) {
      return _Hint(
        icon: Icons.people_outline,
        title: 'No students found',
        message: _courseName != null
            ? 'No active students are enrolled in $_courseName yet.'
            : 'No active students found.',
      );
    }
    final list = _filteredStudents;
    if (list.isEmpty) {
      return _Hint(
        icon: Icons.search_off_outlined,
        title: 'No matches',
        message: 'No students match "$_query".',
      );
    }
    return RefreshIndicator(
      onRefresh: _loadStudents,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _StudentTile(
          student: list[i],
          onTap: () => _openStudent(list[i]),
        ),
      ),
    );
  }
}

// ── Course picker field (the tappable "dropdown") ───────────────────────────────

class _CoursePickerField extends StatelessWidget {
  final String? label;
  final bool loading;
  final String? error;
  final VoidCallback? onTap;
  final VoidCallback onRetry;
  const _CoursePickerField({
    required this.label,
    required this.loading,
    required this.error,
    required this.onTap,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (error != null) {
      return InkWell(
        onTap: onRetry,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.error),
          ),
          child: Row(children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
            const SizedBox(width: 10),
            Expanded(
                child: Text('Could not load courses. Tap to retry.',
                    style: TextStyle(color: theme.colorScheme.error))),
            const Icon(Icons.refresh, size: 18),
          ]),
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
          color: theme.colorScheme.surface,
        ),
        child: Row(
          children: [
            Icon(Icons.menu_book_outlined,
                size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                loading
                    ? 'Loading courses...'
                    : (label ?? 'Select a course / batch'),
                style: TextStyle(
                  fontWeight: label != null ? FontWeight.w600 : FontWeight.normal,
                  color: label != null
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (loading)
              const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              const Icon(Icons.keyboard_arrow_down_rounded),
          ],
        ),
      ),
    );
  }
}

// ── Searchable course picker bottom sheet ───────────────────────────────────────

class _CoursePickerSheet extends StatefulWidget {
  final List<Map<String, dynamic>> courses;
  final String? selectedId;
  final ValueChanged<Map<String, dynamic>> onSelected;
  const _CoursePickerSheet({
    required this.courses,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  State<_CoursePickerSheet> createState() => _CoursePickerSheetState();
}

class _CoursePickerSheetState extends State<_CoursePickerSheet> {
  final _ctrl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _q.isEmpty
        ? widget.courses
        : widget.courses.where((c) {
            final name    = (c['name'] as String? ?? '').toLowerCase();
            final subject = (c['subject'] as String? ?? '').toLowerCase();
            return name.contains(_q.toLowerCase()) ||
                subject.contains(_q.toLowerCase());
          }).toList();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        builder: (_, scrollCtrl) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  hintText: 'Search course or batch',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? _Hint(
                      icon: Icons.search_off_outlined,
                      title: 'No courses found',
                      message: _q.isEmpty
                          ? 'No courses have been created yet.'
                          : 'No courses match "$_q".',
                    )
                  : ListView.builder(
                      controller: scrollCtrl,
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final c = filtered[i];
                        final selected = c['id'] == widget.selectedId;
                        final count = c['student_count'] ?? 0;
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                theme.colorScheme.primary.withValues(alpha: 0.12),
                            child: Icon(Icons.menu_book_outlined,
                                color: theme.colorScheme.primary, size: 20),
                          ),
                          title: Text(c['name'] as String? ?? 'Course',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            [
                              if ((c['subject'] as String?)?.isNotEmpty ?? false)
                                c['subject'],
                              '$count student${count == 1 ? '' : 's'}',
                            ].join('  ·  '),
                          ),
                          trailing: selected
                              ? Icon(Icons.check_circle,
                                  color: theme.colorScheme.primary)
                              : null,
                          onTap: () => widget.onSelected(c),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Student tile ────────────────────────────────────────────────────────────────

class _StudentTile extends StatelessWidget {
  final Map<String, dynamic> student;
  final VoidCallback onTap;
  const _StudentTile({required this.student, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = '${student['first_name'] ?? ''} ${student['last_name'] ?? ''}'.trim();
    final initials = name.split(' ')
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0].toUpperCase())
        .join();
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
          child: Text(initials.isEmpty ? '?' : initials,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
        ),
        title: Text(name.isEmpty ? 'Unnamed' : name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          [student['id'], student['mobile']]
              .where((e) => e != null && '$e'.isNotEmpty)
              .join('  ·  '),
          style: const TextStyle(fontSize: 12),
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════════
//  Student fee detail screen — summary + installment history
// ════════════════════════════════════════════════════════════════════════════════

class StudentFeeDetailScreen extends StatefulWidget {
  final String studentId;
  final String studentName;
  final String mobile;
  final String? courseId;
  final String? courseName;

  const StudentFeeDetailScreen({
    super.key,
    required this.studentId,
    required this.studentName,
    this.mobile = '',
    this.courseId,
    this.courseName,
  });

  @override
  State<StudentFeeDetailScreen> createState() => _StudentFeeDetailScreenState();
}

class _StudentFeeDetailScreenState extends State<StudentFeeDetailScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _records = [];

  // Active QR for payment display
  Map<String, dynamic>? _activeQr;
  bool _loadingQr = true;

  // PDF generation
  bool _generatingPdf = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadActiveQr();
  }

  Future<void> _loadActiveQr() async {
    try {
      final qr = await AcademyApiService.getActiveQrCode();
      if (mounted) setState(() { _activeQr = qr; _loadingQr = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingQr = false);
    }
  }

  Future<void> _downloadPdf() async {
    if (_generatingPdf) return;
    setState(() => _generatingPdf = true);
    try {
      final academyName =
          context.read<AuthProvider>().academyUser?.academyName ?? 'Academy';
      await FeePdfService.generate(
        context:        context,
        academyName:    academyName,
        studentName:    widget.studentName,
        studentId:      widget.studentId,
        mobile:         widget.mobile,
        courseName:     widget.courseName ?? '',
        records:        _records,
        qrImageData:    _activeQr?['image_data'] as String?,
        qrName:         _activeQr?['name'] as String?,
        qrDescription:  _activeQr?['description'] as String?,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('PDF error: ${e.toString().replaceFirst("Exception: ", "")}'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _generatingPdf = false);
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.getStudentFees(widget.studentId);
      var records = (data['records'] as List? ?? []).cast<Map<String, dynamic>>();
      // Scope to the selected course when one was chosen.
      if (widget.courseId != null) {
        records = records.where((r) => r['course_id'] == widget.courseId).toList();
      }
      // Chronological order (earliest first) so installment numbers are stable.
      records.sort((a, b) => _dateStr(a['due_date']).compareTo(_dateStr(b['due_date'])));
      if (!mounted) return;
      setState(() { _records = records; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  // ── derived summary ──────────────────────────────────────────────────────────
  double get _totalDue =>
      _records.fold(0.0, (s, r) => s + _num(r['amount_due']));
  double get _totalPaid =>
      _records.fold(0.0, (s, r) => s + _num(r['amount_paid']));
  double get _pending => (_totalDue - _totalPaid).clamp(0.0, double.infinity);

  String get _overallStatus {
    if (_records.isEmpty) return 'none';
    if (_pending <= 0) return 'paid';
    if (_records.any((r) => r['status'] == 'overdue')) return 'overdue';
    if (_totalPaid > 0) return 'partial';
    return 'pending';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.studentName.isEmpty ? 'Fee Details' : widget.studentName),
        actions: [
          if (!_loading && _records.isNotEmpty)
            _generatingPdf
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)))
                : IconButton(
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    tooltip: 'Download PDF',
                    onPressed: _downloadPdf,
                  ),
        ],
        bottom: widget.courseName != null
            ? PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(widget.courseName!,
                        style: const TextStyle(fontSize: 13, color: Colors.white70)),
                  ),
                ),
              )
            : null,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load)
              : _records.isEmpty
                  ? _Hint(
                      icon: Icons.receipt_long_outlined,
                      title: 'No fee records',
                      message:
                          'There are no fee records for this student${widget.courseName != null ? ' in ${widget.courseName}' : ''} yet.',
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          _summaryCard(context),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              const Icon(Icons.format_list_numbered, size: 18),
                              const SizedBox(width: 8),
                              Text('Installment History',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(fontWeight: FontWeight.bold)),
                              const Spacer(),
                              Text('${_records.length} total',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.6))),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ..._buildInstallments(),
                          const SizedBox(height: 8),
                          // Active QR for payment
                          if (!_loadingQr && _activeQr != null)
                            _ActiveQrCard(qr: _activeQr!),
                        ],
                      ),
                    ),
    );
  }

  // ── summary ──────────────────────────────────────────────────────────────────
  Widget _summaryCard(BuildContext context) {
    final theme = Theme.of(context);
    final color = _statusColor(_overallStatus);
    final nextDue = _records.firstWhere(
      (r) => r['status'] != 'paid',
      orElse: () => const {},
    );

    // Enrolled subjects + per-subject fee breakdown derived from the records.
    String? subjectNames;
    final breakdown = <String, num>{};
    for (final r in _records) {
      subjectNames ??= subjectNamesOf(r);
      final subs = r['subjects'];
      if (subs is List) {
        for (final s in subs) {
          if (s is Map && s['name'] != null) {
            breakdown[s['name'].toString()] =
                num.tryParse(s['fee']?.toString() ?? '') ?? 0;
          }
        }
      }
    }
    final courseLabel = courseWithSubjects(widget.courseName, subjectNames);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Fee Summary',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                _StatusPill(status: _overallStatus),
              ],
            ),
            if (courseLabel.isNotEmpty && courseLabel != 'Course') ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.menu_book_outlined,
                      size: 15, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(courseLabel,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.primary)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                _MetricTile(
                    label: 'Total Fee',
                    value: _money(_totalDue),
                    color: theme.colorScheme.onSurface),
                _divider(),
                _MetricTile(
                    label: 'Paid', value: _money(_totalPaid), color: Colors.green),
                _divider(),
                _MetricTile(
                    label: 'Pending',
                    value: _money(_pending),
                    color: _pending > 0 ? Colors.orange : Colors.green),
              ],
            ),
            if (breakdown.length > 1) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    for (final e in breakdown.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(e.key,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.7))),
                            Text('₹${e.value.toStringAsFixed(0)}',
                                style: const TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _totalDue > 0
                    ? (_totalPaid / _totalDue).clamp(0.0, 1.0)
                    : 0,
                minHeight: 8,
                color: color,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            if (nextDue.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.event_outlined,
                      size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                  const SizedBox(width: 6),
                  Text('Next due: ${_fmtDate(nextDue['due_date'])}',
                      style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.7))),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _divider() => Container(
      width: 1, height: 34, color: Colors.grey.withValues(alpha: 0.25));

  // ── installments ─────────────────────────────────────────────────────────────
  List<Widget> _buildInstallments() {
    double runningOutstanding = 0;
    final widgets = <Widget>[];
    for (var i = 0; i < _records.length; i++) {
      final r = _records[i];
      final due  = _num(r['amount_due']);
      final paid = _num(r['amount_paid']);
      final bal  = (due - paid).clamp(0.0, double.infinity);
      runningOutstanding += bal;
      widgets.add(_InstallmentCard(
        number: i + 1,
        status: r['status'] as String? ?? 'pending',
        dueDate: _fmtDate(r['due_date']),
        paymentDate: _fmtDate(r['paid_date']),
        amountDue: due,
        amountPaid: paid,
        balance: bal,
        runningOutstanding: runningOutstanding,
        mode: _mode(r['remarks'] as String?),
        receiptNumber: r['receipt_number'] as String?,
        receiptId: r['receipt_id'] as String?,
      ));
      if (i != _records.length - 1) widgets.add(const SizedBox(height: 8));
    }
    return widgets;
  }
}

// ── Installment card ────────────────────────────────────────────────────────────

class _InstallmentCard extends StatefulWidget {
  final int number;
  final String status, dueDate, paymentDate, mode;
  final double amountDue, amountPaid, balance, runningOutstanding;
  final String? receiptNumber;
  final String? receiptId;
  const _InstallmentCard({
    required this.number,
    required this.status,
    required this.dueDate,
    required this.paymentDate,
    required this.mode,
    required this.amountDue,
    required this.amountPaid,
    required this.balance,
    required this.runningOutstanding,
    this.receiptNumber,
    this.receiptId,
  });

  @override
  State<_InstallmentCard> createState() => _InstallmentCardState();
}

class _InstallmentCardState extends State<_InstallmentCard> {
  bool _generatingPdf = false;

  Future<void> _downloadReceipt() async {
    if (_generatingPdf || widget.receiptId == null) return;
    setState(() => _generatingPdf = true);
    try {
      final detail = await AcademyApiService.getReceipt(widget.receiptId!);
      if (!mounted) return;
      final academyName =
          context.read<AuthProvider>().academyUser?.academyName ?? 'Academy';
      await FeePdfService.generateReceiptPdf(
          context: context, academyName: academyName, receipt: detail);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _generatingPdf = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _statusColor(widget.status);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: color.withValues(alpha: 0.15),
                  child: Text('${widget.number}',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: color)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Installment ${widget.number}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      if (widget.receiptNumber != null)
                        Text(widget.receiptNumber!,
                            style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.primary)),
                    ],
                  ),
                ),
                _StatusPill(status: widget.status),
              ],
            ),
            const Divider(height: 18),
            _kv(theme, Icons.event_outlined, 'Due date', widget.dueDate),
            _kv(theme, Icons.payments_outlined, 'Amount due', _money(widget.amountDue)),
            _kv(theme, Icons.check_circle_outline, 'Amount paid',
                _money(widget.amountPaid),
                valueColor: widget.amountPaid > 0 ? Colors.green : null),
            if (widget.amountPaid > 0) ...[
              _kv(theme, Icons.calendar_today_outlined, 'Payment date', widget.paymentDate),
              _kv(theme, Icons.account_balance_wallet_outlined, 'Payment mode', widget.mode),
            ],
            _kv(theme, Icons.pending_actions_outlined, 'Balance', _money(widget.balance),
                valueColor: widget.balance > 0 ? Colors.orange : Colors.green),
            _kv(theme, Icons.trending_down, 'Outstanding after this',
                _money(widget.runningOutstanding),
                valueColor: widget.runningOutstanding > 0 ? Colors.red : Colors.green),
            if (widget.receiptId != null) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _generatingPdf ? null : _downloadReceipt,
                icon: _generatingPdf
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.picture_as_pdf_outlined, size: 16),
                label: Text(
                  widget.receiptNumber != null
                      ? 'Download Receipt ${widget.receiptNumber}'
                      : 'Download Receipt',
                  style: const TextStyle(fontSize: 12),
                ),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 6)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(ThemeData theme, IconData icon, String k, String v,
      {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 15,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55)),
          const SizedBox(width: 8),
          Text(k,
              style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7))),
          const Spacer(),
          Text(v,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: valueColor ?? theme.colorScheme.onSurface)),
        ],
      ),
    );
  }
}

// ── Small shared widgets ────────────────────────────────────────────────────────

class _MetricTile extends StatelessWidget {
  final String label, value;
  final Color color;
  const _MetricTile(
      {required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          children: [
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16, color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6))),
          ],
        ),
      );
}

class _StatusPill extends StatelessWidget {
  final String status;
  const _StatusPill({required this.status});
  @override
  Widget build(BuildContext context) {
    final color = _statusColor(status);
    final label = status == 'none' ? 'NO DUES' : status.toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.bold, color: color)),
    );
  }
}

class _Hint extends StatelessWidget {
  final IconData icon;
  final String title, message;
  const _Hint({required this.icon, required this.title, required this.message});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      // ListView so it stays pull-to-refresh friendly and centered-ish.
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
      children: [
        Icon(icon, size: 56,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.25)),
        const SizedBox(height: 14),
        Text(title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(message,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 56, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            const Text('Something went wrong',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Active QR card ────────────────────────────────────────────────────────────

class _ActiveQrCard extends StatelessWidget {
  final Map<String, dynamic> qr;
  const _ActiveQrCard({required this.qr});

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final imgData = qr['image_data'] as String? ?? '';
    Uint8List? bytes;
    try {
      final b64 = imgData.contains(',') ? imgData.split(',').last : imgData;
      bytes = base64Decode(b64);
    } catch (_) {}

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.qr_code_2, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text('Pay via QR',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            if (bytes != null)
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(bytes, width: 200, height: 200, fit: BoxFit.contain),
                ),
              ),
            if (bytes == null)
              Center(
                child: Icon(Icons.qr_code_2_outlined, size: 80,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
              ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                qr['name'] as String? ?? 'Academy QR',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ),
            if ((qr['description'] as String?)?.isNotEmpty ?? false) ...[
              const SizedBox(height: 4),
              Center(
                child: Text(
                  qr['description'] as String,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Shared helpers ──────────────────────────────────────────────────────────────

double _num(dynamic v) => double.tryParse(v?.toString() ?? '') ?? 0.0;

String _money(double v) => '₹${v.toStringAsFixed(0)}';

String _dateStr(dynamic raw) {
  final s = raw?.toString() ?? '';
  return s.contains('T') ? s.split('T')[0] : s;
}

String _fmtDate(dynamic raw) {
  final s = _dateStr(raw);
  if (s.isEmpty) return '—';
  try {
    final d = DateTime.parse(s);
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month]} ${d.year}';
  } catch (_) {
    return s;
  }
}

/// Payment mode is stored inside the fee record's remarks as "Mode: <mode> | ...".
String _mode(String? remarks) {
  if (remarks == null || remarks.isEmpty) return '—';
  final m = RegExp(r'Mode:\s*([a-zA-Z_ ]+)').firstMatch(remarks);
  if (m == null) return '—';
  final mode = (m.group(1) ?? '').trim();
  if (mode.isEmpty) return '—';
  switch (mode.toLowerCase()) {
    case 'cash':          return 'Cash';
    case 'upi':           return 'UPI';
    case 'bank_transfer': return 'Bank Transfer';
    case 'cheque':        return 'Cheque';
    default:              return mode;
  }
}

Color _statusColor(String s) {
  switch (s) {
    case 'paid':    return Colors.green;
    case 'overdue': return Colors.red;
    case 'partial': return Colors.blue;
    case 'none':    return Colors.green;
    default:        return Colors.orange; // pending
  }
}
