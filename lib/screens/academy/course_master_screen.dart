import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/academic_year_provider.dart';
import '../../services/academy_api_service.dart';

class CourseMasterScreen extends StatefulWidget {
  const CourseMasterScreen({super.key});

  @override
  State<CourseMasterScreen> createState() => _CourseMasterScreenState();
}

class _CourseMasterScreenState extends State<CourseMasterScreen> {
  List<Map<String, dynamic>> _courses      = [];
  List<Map<String, dynamic>> _academicYears = [];
  String? _filterYearId; // null = all years
  bool    _loading   = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    // Default filter to the globally selected academic year.
    _filterYearId = context.read<AcademicYearProvider>().selectedId;
    _loadAll();
  }

  Future<void> _loadAll() async {
    if (!mounted) return;
    setState(() { _loading = true; _loadError = null; });
    try {
      final results = await Future.wait([
        AcademyApiService.getAcademicYears(),
        AcademyApiService.getCourses(academicYearId: _filterYearId),
      ]);
      if (!mounted) return;
      setState(() {
        _academicYears = results[0].cast<Map<String, dynamic>>();
        _courses       = results[1].cast<Map<String, dynamic>>();
        _loading       = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading   = false;
        _loadError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _loadCourses() async {
    if (!mounted) return;
    setState(() { _loading = true; _loadError = null; });
    try {
      final data =
          await AcademyApiService.getCourses(academicYearId: _filterYearId);
      if (!mounted) return;
      setState(() {
        _courses  = data.cast<Map<String, dynamic>>();
        _loading  = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading   = false;
        _loadError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _showForm({Map<String, dynamic>? course}) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _CourseForm(
        course: course,
        academicYears: _academicYears,
        defaultYearId: _filterYearId,
      ),
    );
    if (result == true) _loadCourses();
  }

  Future<void> _showSubjects(Map<String, dynamic> course) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SubjectMasterPage(
          courseId:   course['id'] as String,
          courseName: course['name'] as String,
        ),
      ),
    );
    if (mounted) _loadCourses(); // refresh subject count & total fees
  }

  Future<void> _delete(Map<String, dynamic> course) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Course'),
        content: Text(
            'Delete "${course['name']}"? Cannot be undone if students are enrolled.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AcademyApiService.deleteCourse(course['id'] as String);
      _loadCourses();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')),
                backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Course Master'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: () => _showForm()),
        ],
      ),
      body: Column(
        children: [
          // ── Academic year filter chips ──────────────────────────────────
          if (_academicYears.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  _YearChip(
                    label: 'All Years',
                    selected: _filterYearId == null,
                    onTap: () {
                      setState(() => _filterYearId = null);
                      _loadCourses();
                    },
                  ),
                  ..._academicYears.map((y) => _YearChip(
                        label: y['academic_year_name'] as String,
                        selected: _filterYearId == y['id'],
                        isCurrent: y['is_current_year'] == true,
                        onTap: () {
                          setState(() => _filterYearId = y['id'] as String);
                          _loadCourses();
                        },
                      )),
                ],
              ),
            ),
          // ── Course list ────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.cloud_off_outlined,
                                  size: 56,
                                  color: theme.colorScheme.error
                                      .withValues(alpha: 0.7)),
                              const SizedBox(height: 12),
                              Text(_loadError!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: theme.colorScheme.error,
                                      fontSize: 13)),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: _loadAll,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _courses.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.menu_book_outlined,
                                    size: 64,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.3)),
                                const SizedBox(height: 12),
                                const Text('No courses yet'),
                                const SizedBox(height: 8),
                                FilledButton.icon(
                                  onPressed: () => _showForm(),
                                  icon: const Icon(Icons.add),
                                  label: const Text('Add First Course'),
                                ),
                              ],
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _loadAll,
                            child: ListView.separated(
                              padding: const EdgeInsets.all(16),
                              itemCount: _courses.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (_, i) {
                                final c            = _courses[i];
                                final count        = int.tryParse(c['student_count']?.toString() ?? '') ?? 0;
                                final subjectCount = int.tryParse(c['subject_count']?.toString() ?? '') ?? 0;
                                final totalFee     = double.tryParse(c['total_subject_fee']?.toString() ?? '0') ?? 0.0;
                                final yearName     = c['academic_year_name'] as String?;
                                final feeDueDay    = c['fee_due_day'] as int?;
                                final dueDayLabel  = feeDueDay == null
                                    ? 'last day'
                                    : '$feeDueDay${_CourseFormState._ordinal(feeDueDay)}';
                                return Card(
                                  child: ListTile(
                                    onTap: () => _showSubjects(c),
                                    leading: CircleAvatar(
                                      backgroundColor: theme.colorScheme.primary
                                          .withValues(alpha: 0.1),
                                      child: Icon(Icons.menu_book,
                                          color: theme.colorScheme.primary),
                                    ),
                                    title: Text(c['name'] as String,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold)),
                                    subtitle: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        if (yearName != null)
                                          Container(
                                            margin: const EdgeInsets.only(top: 3, bottom: 2),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: theme.colorScheme.primary
                                                  .withValues(alpha: 0.1),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text(yearName,
                                                style: TextStyle(
                                                    fontSize: 10,
                                                    color: theme.colorScheme.primary,
                                                    fontWeight: FontWeight.w600)),
                                          ),
                                        Text(
                                          '$subjectCount subject${subjectCount == 1 ? '' : 's'}'
                                          ' · ₹${totalFee.toStringAsFixed(0)} total'
                                          ' · $count student${count == 1 ? '' : 's'}'
                                          ' · due $dueDayLabel',
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ],
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                            icon: const Icon(Icons.edit_outlined),
                                            tooltip: 'Edit',
                                            onPressed: () => _showForm(course: c)),
                                        IconButton(
                                            icon: const Icon(
                                                Icons.delete_outline,
                                                color: Colors.red),
                                            tooltip: 'Delete',
                                            onPressed: () => _delete(c)),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
      floatingActionButton: !_loading
          ? FloatingActionButton.extended(
              onPressed: () => _showForm(),
              icon: const Icon(Icons.add),
              label: const Text('Add Course'),
            )
          : null,
    );
  }
}

// ── Subject master full-screen page ──────────────────────────────────────────

class _SubjectMasterPage extends StatefulWidget {
  final String courseId;
  final String courseName;

  const _SubjectMasterPage({
    required this.courseId,
    required this.courseName,
  });

  @override
  State<_SubjectMasterPage> createState() => _SubjectMasterPageState();
}

class _SubjectMasterPageState extends State<_SubjectMasterPage> {
  List<Map<String, dynamic>> _subjects = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final data = await AcademyApiService.getSubjectsByCourse(widget.courseId);
      if (!mounted) return;
      setState(() { _subjects = data; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _showForm({Map<String, dynamic>? subject}) async {
    final existingNames = _subjects
        .where((s) => s['id'] != subject?['id'])
        .map((s) => (s['name'] as String).toLowerCase())
        .toList();

    final result = await showDialog<bool>(
      context: context,
      builder: (_) => _SubjectFormDialog(
        courseId:      widget.courseId,
        subject:       subject,
        existingNames: existingNames,
      ),
    );
    if (result == true) _load();
  }

  Future<void> _delete(Map<String, dynamic> subject) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Subject'),
        content: Text(
            'Delete "${subject['name']}"? Students enrolled in this subject will be affected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AcademyApiService.deleteSubject(subject['id'] as String);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.courseName,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(
              'Subjects',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Subject',
            onPressed: () => _showForm(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _subjects.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.subject_outlined,
                          size: 64,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.3)),
                      const SizedBox(height: 12),
                      const Text('No subjects yet'),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: () => _showForm(),
                        icon: const Icon(Icons.add),
                        label: const Text('Add First Subject'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _subjects.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final s   = _subjects[i];
                      final fee =
                          double.tryParse(s['default_fee']?.toString() ?? '0') ??
                              0.0;
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: theme.colorScheme.secondary
                                .withValues(alpha: 0.1),
                            child: Icon(Icons.science_outlined,
                                color: theme.colorScheme.secondary, size: 20),
                          ),
                          title: Text(s['name'] as String,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle:
                              Text('₹${fee.toStringAsFixed(0)} default fee'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _showForm(subject: s),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.red),
                                onPressed: () => _delete(s),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
      floatingActionButton: _subjects.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () => _showForm(),
              icon: const Icon(Icons.add),
              label: const Text('Add Subject'),
            )
          : null,
    );
  }
}

// ── Subject create / edit dialog ──────────────────────────────────────────────

class _SubjectFormDialog extends StatefulWidget {
  final String courseId;
  final Map<String, dynamic>? subject;
  final List<String> existingNames; // lowercased, excluding the subject being edited

  const _SubjectFormDialog({
    required this.courseId,
    required this.existingNames,
    this.subject,
  });

  @override
  State<_SubjectFormDialog> createState() => _SubjectFormDialogState();
}

class _SubjectFormDialogState extends State<_SubjectFormDialog> {
  final _formKey  = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _feeCtrl  = TextEditingController();
  bool    _saving = false;
  String? _error;

  bool get _isEdit => widget.subject != null;

  @override
  void initState() {
    super.initState();
    if (widget.subject != null) {
      _nameCtrl.text = widget.subject!['name'] as String? ?? '';
      _feeCtrl.text  = widget.subject!['default_fee']?.toString() ?? '0';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _feeCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    try {
      final body = {
        'name':        _nameCtrl.text.trim(),
        'default_fee': double.tryParse(_feeCtrl.text) ?? 0.0,
      };
      if (_isEdit) {
        await AcademyApiService.updateSubject(
            widget.subject!['id'] as String, body);
      } else {
        await AcademyApiService.createSubject(widget.courseId, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error  = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit Subject' : 'New Subject'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                  labelText: 'Subject Name *',
                  border: OutlineInputBorder()),
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Required';
                if (widget.existingNames.contains(v.trim().toLowerCase())) {
                  return 'A subject with this name already exists';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _feeCtrl,
              decoration: const InputDecoration(
                  labelText: 'Default Fee (₹) *',
                  prefixText: '₹ ',
                  border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
              validator: (v) =>
                  v == null || v.isEmpty ? 'Required' : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        color: Colors.red.shade700, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_error!,
                          style: TextStyle(
                              fontSize: 12, color: Colors.red.shade700)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(_isEdit ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}

// ── Year filter chip ──────────────────────────────────────────────────────────

class _YearChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool isCurrent;
  final VoidCallback onTap;

  const _YearChip({
    required this.label,
    required this.selected,
    this.isCurrent = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isCurrent)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.star_rounded, size: 12),
              ),
            Text(label),
          ],
        ),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

// ── Course form (create / edit) ───────────────────────────────────────────────

class _CourseForm extends StatefulWidget {
  final Map<String, dynamic>? course;
  final List<Map<String, dynamic>> academicYears;
  final String? defaultYearId;

  const _CourseForm({
    this.course,
    required this.academicYears,
    this.defaultYearId,
  });

  @override
  State<_CourseForm> createState() => _CourseFormState();
}

class _CourseFormState extends State<_CourseForm> {
  final _formKey       = GlobalKey<FormState>();
  final _nameCtrl      = TextEditingController();
  final _descCtrl      = TextEditingController();
  final _durationCtrl  = TextEditingController();
  String  _schedule        = 'monthly';
  String? _academicYearId;
  // null = last day of month; 1-28 = specific day
  int?    _feeDueDay;
  int?    _originalFeeDueDay;
  bool    _saving      = false;

  bool get _isEdit => widget.course != null;

  @override
  void initState() {
    super.initState();
    final c = widget.course;
    if (c != null) {
      _nameCtrl.text     = c['name'] ?? '';
      _descCtrl.text     = c['description'] ?? '';
      _durationCtrl.text = c['duration_months']?.toString() ?? '';
      _schedule          = c['schedule'] ?? 'monthly';
      _academicYearId    = c['academic_year_id'] as String?;
      _feeDueDay         = c['fee_due_day'] as int?;
      _originalFeeDueDay = _feeDueDay;
    } else {
      _academicYearId = widget.defaultYearId;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _descCtrl.dispose(); _durationCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    bool updatePendingFees = false;

    // If due day changed on an existing course, ask whether to also update
    // pending/overdue fee records for this course.
    if (_isEdit && _feeDueDay != _originalFeeDueDay) {
      final label = _feeDueDay == null
          ? 'last day of month'
          : '${_feeDueDay!}${_ordinal(_feeDueDay!)} of each month';
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Update Existing Fees?'),
          content: Text(
            'Due date changed to $label.\n\n'
            'Also update due dates on all existing pending / overdue fee records for this course?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('No, only save course'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Yes, update fees too'),
            ),
          ],
        ),
      );
      if (confirm == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      updatePendingFees = confirm;
    }

    try {
      final body = <String, dynamic>{
        'name':             _nameCtrl.text.trim(),
        'description':      _descCtrl.text.trim(),
        'schedule':         _schedule,
        'academic_year_id': _academicYearId,
        'fee_due_day':      _feeDueDay,
        if (_durationCtrl.text.isNotEmpty)
          'duration_months': int.tryParse(_durationCtrl.text),
        if (_isEdit && updatePendingFees)
          'update_pending_fees': true,
      };
      if (_isEdit) {
        await AcademyApiService.updateCourse(
            widget.course!['id'] as String, body);
      } else {
        await AcademyApiService.createCourse(body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')),
                backgroundColor: Colors.red));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  static String _ordinal(int n) {
    if (n >= 11 && n <= 13) return 'th';
    switch (n % 10) {
      case 1: return 'st';
      case 2: return 'nd';
      case 3: return 'rd';
      default: return 'th';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_isEdit ? 'Edit Course' : 'New Course',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            // Academic year dropdown
            DropdownButtonFormField<String?>(
              value: _academicYearId,
              decoration: const InputDecoration(
                  labelText: 'Academic Year *',
                  border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('— No Year —')),
                ...widget.academicYears.map((y) => DropdownMenuItem<String?>(
                      value: y['id'] as String,
                      child: Row(
                        children: [
                          if (y['is_current_year'] == true)
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Icon(Icons.star_rounded,
                                  size: 14, color: Colors.amber),
                            ),
                          Text(y['academic_year_name'] as String),
                        ],
                      ),
                    )),
              ],
              onChanged: (v) => setState(() => _academicYearId = v),
              validator: (v) =>
                  v == null ? 'Academic Year is required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                  labelText: 'Course Name *', border: OutlineInputBorder()),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _durationCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Duration (months)',
                        border: OutlineInputBorder()),
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      if (v != null && v.isNotEmpty && int.tryParse(v) == null) {
                        return 'Enter a valid number';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _schedule,
                    decoration: const InputDecoration(
                        labelText: 'Schedule *', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'monthly',   child: Text('Monthly')),
                      DropdownMenuItem(value: 'quarterly', child: Text('Quarterly')),
                      DropdownMenuItem(value: 'onetime',   child: Text('One-time')),
                    ],
                    onChanged: (v) => setState(() => _schedule = v!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SubjectInfoTile(course: widget.course),
            const SizedBox(height: 12),
            // Fee due date picker
            TextFormField(
              readOnly: true,
              decoration: InputDecoration(
                labelText: 'Fee Due Date',
                helperText: 'Day of month when fee is due each cycle',
                border: const OutlineInputBorder(),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_feeDueDay != null)
                      IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        tooltip: 'Reset to last day of month',
                        onPressed: () => setState(() => _feeDueDay = null),
                      ),
                    const Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: Icon(Icons.calendar_today, size: 18),
                    ),
                  ],
                ),
              ),
              controller: TextEditingController(
                text: _feeDueDay != null
                    ? '$_feeDueDay${_ordinal(_feeDueDay!)} of each month'
                    : 'Last day of month',
              ),
              onTap: () async {
                final now = DateTime.now();
                // If a day is already set, try to show it in the current/next
                // month so it's visible; fall back to today if it's in the past.
                DateTime initial = now;
                if (_feeDueDay != null) {
                  final candidate = DateTime(now.year, now.month, _feeDueDay!);
                  initial = candidate.isBefore(now)
                      ? DateTime(now.year, now.month + 1, _feeDueDay!)
                      : candidate;
                }
                final picked = await showDatePicker(
                  context: context,
                  initialDate: initial,
                  firstDate: now,
                  lastDate: DateTime(now.year + 5, 12, 31),
                  helpText: 'Select fee due day',
                  fieldLabelText: 'Due Day',
                );
                if (picked != null) {
                  // Clamp to 28 — safe for all months including February
                  setState(() => _feeDueDay = picked.day > 28 ? 28 : picked.day);
                }
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _descCtrl,
              decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  border: OutlineInputBorder()),
              maxLines: 2,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(_isEdit ? 'Save Changes' : 'Create Course'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Read-only subject count / total fee tile ──────────────────────────────────

class _SubjectInfoTile extends StatelessWidget {
  final Map<String, dynamic>? course;
  const _SubjectInfoTile({this.course});

  @override
  Widget build(BuildContext context) {
    final theme        = Theme.of(context);
    final subjectCount = int.tryParse(course?['subject_count']?.toString() ?? '') ?? 0;
    final totalFee     = double.tryParse(course?['total_subject_fee']?.toString() ?? '0') ?? 0.0;

    return SizedBox(
      height: 72,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Subjects Configured',
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                    const SizedBox(height: 4),
                    Text('$subjectCount',
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
            Container(
              width: 1,
              color: theme.colorScheme.outline.withValues(alpha: 0.3),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total Subject Fees',
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                    const SizedBox(height: 4),
                    Text('₹${totalFee.toStringAsFixed(0)}',
                        style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
