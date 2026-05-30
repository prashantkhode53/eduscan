import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';

class CourseMasterScreen extends StatefulWidget {
  const CourseMasterScreen({super.key});

  @override
  State<CourseMasterScreen> createState() => _CourseMasterScreenState();
}

class _CourseMasterScreenState extends State<CourseMasterScreen> {
  List<Map<String, dynamic>> _courses = [];
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
      final data = await AcademyApiService.getCourses();
      if (!mounted) return;
      setState(() {
        _courses = data.cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  Future<void> _showForm({Map<String, dynamic>? course}) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _CourseForm(course: course),
    );
    if (result == true) _load();
  }

  Future<void> _delete(Map<String, dynamic> course) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Course'),
        content: Text(
            'Delete "${course['name']}"? This cannot be undone if students are enrolled.'),
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
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
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
          IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => _showForm()),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
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
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _courses.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final c = _courses[i];
                      final count = c['student_count'] ?? 0;
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                theme.colorScheme.primary.withValues(alpha: 0.1),
                            child: Icon(Icons.menu_book,
                                color: theme.colorScheme.primary),
                          ),
                          title: Text(c['name'] as String,
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(
                            [
                              if (c['subject'] != null) c['subject'],
                              '₹${c['default_fee']}/${c['schedule']}',
                              '$count student${count == 1 ? '' : 's'}',
                            ].join(' · '),
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _showForm(course: c)),
                              IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.red),
                                  onPressed: () => _delete(c)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
      floatingActionButton: _courses.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () => _showForm(),
              icon: const Icon(Icons.add),
              label: const Text('Add Course'),
            )
          : null,
    );
  }
}

// ── Course form (create / edit) ───────────────────────────────────────────────

class _CourseForm extends StatefulWidget {
  final Map<String, dynamic>? course;
  const _CourseForm({this.course});

  @override
  State<_CourseForm> createState() => _CourseFormState();
}

class _CourseFormState extends State<_CourseForm> {
  final _formKey     = GlobalKey<FormState>();
  final _nameCtrl    = TextEditingController();
  final _subjectCtrl = TextEditingController();
  final _descCtrl    = TextEditingController();
  final _feeCtrl     = TextEditingController();
  final _durationCtrl = TextEditingController();
  String _schedule   = 'monthly';
  bool _saving       = false;

  bool get _isEdit => widget.course != null;

  @override
  void initState() {
    super.initState();
    final c = widget.course;
    if (c != null) {
      _nameCtrl.text     = c['name'] ?? '';
      _subjectCtrl.text  = c['subject'] ?? '';
      _descCtrl.text     = c['description'] ?? '';
      _feeCtrl.text      = c['default_fee']?.toString() ?? '0';
      _durationCtrl.text = c['duration_months']?.toString() ?? '';
      _schedule          = c['schedule'] ?? 'monthly';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _subjectCtrl.dispose(); _descCtrl.dispose();
    _feeCtrl.dispose(); _durationCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final body = {
        'name':            _nameCtrl.text.trim(),
        'subject':         _subjectCtrl.text.trim(),
        'description':     _descCtrl.text.trim(),
        'default_fee':     double.tryParse(_feeCtrl.text) ?? 0,
        'schedule':        _schedule,
        if (_durationCtrl.text.isNotEmpty)
          'duration_months': int.tryParse(_durationCtrl.text),
      };
      if (_isEdit) {
        await AcademyApiService.updateCourse(widget.course!['id'] as String, body);
      } else {
        await AcademyApiService.createCourse(body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    }
    setState(() => _saving = false);
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
                    controller: _subjectCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Subject', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _durationCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Duration (months)',
                        border: OutlineInputBorder()),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _feeCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Default Fee (₹) *',
                        prefixText: '₹ ',
                        border: OutlineInputBorder()),
                    keyboardType: TextInputType.number,
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Required' : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _schedule,
                    decoration: const InputDecoration(
                        labelText: 'Schedule', border: OutlineInputBorder()),
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
                      width: 20, height: 20,
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
