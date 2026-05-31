import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';
import 'academy_student_registration_screen.dart';
import 'academy_student_edit_screen.dart';

class AcademyStudentListScreen extends StatefulWidget {
  const AcademyStudentListScreen({super.key});

  @override
  State<AcademyStudentListScreen> createState() =>
      _AcademyStudentListScreenState();
}

class _AcademyStudentListScreenState extends State<AcademyStudentListScreen> {
  List<Map<String, dynamic>> _students = [];
  List<Map<String, dynamic>> _courses  = [];
  bool _loading  = true;
  String _search = '';
  String? _filterCourseId;
  int _total = 0;

  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _loadCourses();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCourses() async {
    try {
      final data = await AcademyApiService.getCourses();
      if (!mounted) return;
      setState(() => _courses = data.cast<Map<String, dynamic>>());
    } catch (_) {}
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final data = await AcademyApiService.getStudents(
        search: _search.isNotEmpty ? _search : null,
        courseId: _filterCourseId,
      );
      if (!mounted) return;
      setState(() {
        _students = (data['students'] as List).cast<Map<String, dynamic>>();
        _total    = data['total'] as int? ?? _students.length;
        _loading  = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Students${_total > 0 ? ' ($_total)' : ''}'),
        actions: [
          if (_courses.isNotEmpty)
            IconButton(
              icon: Icon(_filterCourseId != null
                  ? Icons.filter_alt
                  : Icons.filter_alt_outlined),
              onPressed: _showCourseFilter,
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search by name, ID or mobile…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _search = '');
                          _load();
                        })
                    : null,
                filled: true,
                fillColor: theme.colorScheme.surface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
                isDense: true,
              ),
              onChanged: (v) {
                setState(() => _search = v);
                Future.delayed(
                    const Duration(milliseconds: 400), () {
                  if (_search == v) _load();
                });
              },
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _students.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.people_outline,
                            size: 64,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.3)),
                        const SizedBox(height: 12),
                        Text(_search.isNotEmpty
                            ? 'No students match "$_search"'
                            : 'No students registered yet'),
                        const SizedBox(height: 16),
                        if (_search.isEmpty)
                          FilledButton.icon(
                            onPressed: _openRegistration,
                            icon: const Icon(Icons.person_add_outlined),
                            label: const Text('Register Student'),
                          ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                        16, 16, 16,
                        MediaQuery.of(context).padding.bottom + 88),
                    itemCount: _students.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _StudentCard(
                      student: _students[i],
                      theme: theme,
                      onEdit: () => _openEdit(_students[i]),
                      onDelete: () => _confirmDelete(_students[i]),
                    ),
                  ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openRegistration,
        icon: const Icon(Icons.person_add_outlined),
        label: const Text('Register Student'),
      ),
    );
  }

  Future<void> _openRegistration() async {
    final registered = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => const AcademyStudentRegistrationScreen()),
    );
    if (registered == true) _load();
  }

  Future<void> _openEdit(Map<String, dynamic> student) async {
    final updated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AcademyStudentEditScreen(
          studentId: student['id'] as String,
          studentName:
              '${student['first_name']} ${student['last_name']}',
        ),
      ),
    );
    if (updated == true) _load();
  }

  Future<void> _confirmDelete(Map<String, dynamic> student) async {
    final id   = student['id'] as String;
    final name = '${student['first_name']} ${student['last_name']}';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Student'),
        content: Text(
          'Permanently delete $name ($id)?\n\n'
          'This also removes their face data, course enrolments, attendance '
          'and fee records. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('Deleting $name…')));
    try {
      await AcademyApiService.deleteStudent(id);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
          content: Text('$name deleted'), backgroundColor: Colors.green));
      _load();
    } catch (e) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        backgroundColor: Colors.red,
      ));
    }
  }

  void _showCourseFilter() {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 8),
          ListTile(
            title: const Text('All Courses'),
            leading: Radio<String?>(
              value: null,
              groupValue: _filterCourseId,
              onChanged: (v) {
                setState(() => _filterCourseId = v);
                Navigator.pop(context);
                _load();
              },
            ),
          ),
          ..._courses.map((c) => ListTile(
                title: Text(c['name'] as String),
                subtitle: Text('${c['student_count'] ?? 0} students'),
                leading: Radio<String?>(
                  value: c['id'] as String,
                  groupValue: _filterCourseId,
                  onChanged: (v) {
                    setState(() => _filterCourseId = v);
                    Navigator.pop(context);
                    _load();
                  },
                ),
              )),
        ],
      ),
    );
  }
}

// ── Student card ──────────────────────────────────────────────────────────────

class _StudentCard extends StatelessWidget {
  final Map<String, dynamic> student;
  final ThemeData theme;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _StudentCard(
      {required this.student, required this.theme, this.onEdit, this.onDelete});

  @override
  Widget build(BuildContext context) {
    final courses = (student['courses'] as List?)
        ?.cast<Map<String, dynamic>>() ?? [];
    final name =
        '${student['first_name']} ${student['last_name']}';
    final initials = name.trim().split(' ')
        .take(2)
        .map((p) => p.isNotEmpty ? p[0].toUpperCase() : '')
        .join();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor:
                  theme.colorScheme.primary.withValues(alpha: 0.15),
              child: Text(initials,
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(student['id'] as String,
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.5))),
                  if (courses.isNotEmpty)
                    Wrap(
                      spacing: 4,
                      children: courses.take(2).map((c) {
                        return Chip(
                          label: Text(c['name'] as String,
                              style: const TextStyle(fontSize: 10)),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(student['mobile'] as String? ?? '',
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: (student['status'] == 'active'
                            ? Colors.green
                            : Colors.grey)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    (student['status'] as String? ?? 'active').toUpperCase(),
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: student['status'] == 'active'
                            ? Colors.green
                            : Colors.grey),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: onEdit,
                      tooltip: 'Edit',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          size: 18, color: Colors.red),
                      onPressed: onDelete,
                      tooltip: 'Delete',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
