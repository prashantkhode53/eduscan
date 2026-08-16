import 'package:flutter/material.dart';
import '../services/super_admin_api_service.dart';

/// Super Admin → View Academies → <academy> → Actions → Unlock Courses.
///
/// A student's subject fees freeze the moment they are first assigned, so the
/// academy admin cannot rewrite figures that receipts and collection already
/// depend on. This screen is the deliberate escape hatch: the super admin picks
/// an academic year and a course, selects students, and unlocks fee editing for
/// exactly those (student, course) pairs.
///
/// The grant persists until it is re-locked from this same screen. Unlocking is
/// per student AND per course — students left unselected are untouched, as are
/// the selected students' other courses.
class UnlockCoursesScreen extends StatefulWidget {
  final String slug;
  final String academyName;

  const UnlockCoursesScreen({
    super.key,
    required this.slug,
    required this.academyName,
  });

  @override
  State<UnlockCoursesScreen> createState() => _UnlockCoursesScreenState();
}

class _UnlockCoursesScreenState extends State<UnlockCoursesScreen> {
  // Filters
  List<Map<String, dynamic>> _years = [];
  List<Map<String, dynamic>> _courses = [];
  String? _yearId;
  String? _courseId;

  // Roster
  List<Map<String, dynamic>> _students = [];
  final Set<String> _selected = {};

  bool _loadingYears = true;
  bool _loadingCourses = false;
  bool _loadingRoster = false;
  bool _submitting = false;
  String? _error;
  bool _hasLoadedRoster = false;

  @override
  void initState() {
    super.initState();
    _loadYears();
  }

  // ── Loading ────────────────────────────────────────────────────────────────

  Future<void> _loadYears() async {
    setState(() { _loadingYears = true; _error = null; });
    try {
      final years = await SuperAdminApiService.listAcademicYears(widget.slug);
      if (!mounted) return;
      setState(() {
        _years = years;
        // Preselect the current academic year when the academy has marked one.
        final current = years.where((y) => y['is_current_year'] == true);
        _yearId = current.isNotEmpty ? current.first['id'] as String? : null;
        _loadingYears = false;
      });
      if (_yearId != null) await _loadCourses();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loadingYears = false;
      });
    }
  }

  Future<void> _loadCourses() async {
    setState(() {
      _loadingCourses = true;
      _error = null;
      _courses = [];
      _courseId = null;
      _students = [];
      _selected.clear();
      _hasLoadedRoster = false;
    });
    try {
      final courses = await SuperAdminApiService.listCourses(
        widget.slug,
        academicYearId: _yearId,
      );
      if (!mounted) return;
      setState(() { _courses = courses; _loadingCourses = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loadingCourses = false;
      });
    }
  }

  Future<void> _loadRoster() async {
    if (_courseId == null) return;
    setState(() {
      _loadingRoster = true;
      _error = null;
      _selected.clear();
    });
    try {
      final data = await SuperAdminApiService.listCourseUnlockRoster(
        widget.slug,
        _courseId!,
      );
      if (!mounted) return;
      setState(() {
        _students = ((data['students'] as List?) ?? [])
            .cast<Map<String, dynamic>>();
        _loadingRoster = false;
        _hasLoadedRoster = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loadingRoster = false;
        _hasLoadedRoster = true;
      });
    }
  }

  // ── Selection ──────────────────────────────────────────────────────────────

  /// Only students who actually have subject fees assigned can be selected —
  /// there is nothing to unlock for the others.
  List<Map<String, dynamic>> get _selectable =>
      _students.where((s) => s['has_fees'] == true).toList();

  bool get _allSelected =>
      _selectable.isNotEmpty && _selected.length == _selectable.length;

  void _toggleSelectAll(bool? value) {
    setState(() {
      _selected.clear();
      if (value == true) {
        _selected.addAll(_selectable.map((s) => s['id'] as String));
      }
    });
  }

  void _toggleStudent(String id, bool? value) {
    setState(() {
      if (value == true) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
  }

  String get _courseName {
    final match = _courses.where((c) => c['id'] == _courseId);
    return match.isEmpty ? '' : (match.first['name'] as String? ?? '');
  }

  String get _yearName {
    final match = _years.where((y) => y['id'] == _yearId);
    return match.isEmpty
        ? ''
        : (match.first['academic_year_name'] as String? ?? '');
  }

  // ── Unlock / re-lock ───────────────────────────────────────────────────────

  Future<void> _confirmAndUnlock() async {
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.lock_open_outlined,
            color: Colors.orange.shade700, size: 32),
        title: const Text('Unlock course fees?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You are about to unlock this course for $count '
                '${count == 1 ? 'student' : 'students'}. If fees have already '
                'been added, unlocking will allow the Academy Admin to modify '
                'the subject fees.',
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 14),
              _ConfirmRow(label: 'Academy', value: widget.academyName),
              _ConfirmRow(label: 'Academic year', value: _yearName),
              _ConfirmRow(label: 'Course', value: _courseName),
              _ConfirmRow(
                  label: 'Students', value: '$count selected'),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade300),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 18, color: Colors.orange.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Any changes made after unlocking may affect these '
                        "students' existing fee records. Please verify the "
                        'academic year, course and students before continuing.',
                        style: TextStyle(
                            fontSize: 12.5, color: Colors.orange.shade900),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text('Do you want to proceed?',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: Colors.orange.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.lock_open_outlined, size: 18),
            label: const Text('Unlock Course'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await _submit(unlock: true);
  }

  Future<void> _confirmAndRelock() async {
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.lock_outline, color: Colors.blueGrey.shade700, size: 32),
        title: const Text('Re-lock course fees?'),
        content: Text(
          'This will re-lock the course for $count '
          '${count == 1 ? 'student' : 'students'}. The Academy Admin will no '
          'longer be able to modify their subject fees for $_courseName.\n\n'
          'Fees that were already changed while unlocked are kept as they are — '
          're-locking closes the door, it does not undo any edits.',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.lock_outline, size: 18),
            label: const Text('Re-lock'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await _submit(unlock: false);
  }

  Future<void> _submit({required bool unlock}) async {
    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    final ids = _selected.toList();
    try {
      final result = unlock
          ? await SuperAdminApiService.unlockCourseFees(
              widget.slug, courseId: _courseId!, studentIds: ids)
          : await SuperAdminApiService.relockCourseFees(
              widget.slug, courseId: _courseId!, studentIds: ids);
      if (!mounted) return;

      final changed = ((result[unlock ? 'unlocked' : 'relocked'] as List?) ?? [])
          .length;
      final skipped = ((result['skipped'] as List?) ?? []).length;

      messenger.showSnackBar(SnackBar(
        content: Text(
          '${unlock ? 'Unlocked' : 'Re-locked'} $changed '
          '${changed == 1 ? 'student' : 'students'} for $_courseName'
          '${skipped > 0 ? ' · $skipped skipped (no longer on the roster)' : ''}',
        ),
      ));

      // Reload so the badges reflect what the server actually stored.
      await _loadRoster();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        backgroundColor: Colors.red.shade700,
      ));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Re-lock is offered only when every selected student is already unlocked,
    // so the two actions can never be ambiguous about what they'd do.
    final selectedRows =
        _students.where((s) => _selected.contains(s['id'] as String));
    final allSelectedUnlocked = _selected.isNotEmpty &&
        selectedRows.every((s) => s['is_unlocked'] == true);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Unlock Courses'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(widget.academyName,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          _filters(theme),
          const Divider(height: 1),
          Expanded(child: _rosterArea(theme)),
        ],
      ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_selected.length} selected',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (allSelectedUnlocked) ...[
                      OutlinedButton.icon(
                        onPressed: _submitting ? null : _confirmAndRelock,
                        icon: const Icon(Icons.lock_outline, size: 18),
                        label: const Text('Re-lock'),
                      ),
                      const SizedBox(width: 8),
                    ],
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.orange.shade700,
                          minimumSize: const Size(140, 46)),
                      onPressed: _submitting ? null : _confirmAndUnlock,
                      icon: _submitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.lock_open_outlined, size: 18),
                      label: Text(_submitting ? 'Working…' : 'Unlock'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _filters(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            initialValue: _yearId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Academic Year',
              border: OutlineInputBorder(),
              isDense: true,
              prefixIcon: Icon(Icons.calendar_today_outlined, size: 18),
            ),
            items: _years
                .map((y) => DropdownMenuItem(
                      value: y['id'] as String,
                      child: Text(y['academic_year_name'] as String? ?? '—'),
                    ))
                .toList(),
            onChanged: _loadingYears || _submitting
                ? null
                : (v) {
                    setState(() => _yearId = v);
                    _loadCourses();
                  },
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _courseId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Course',
              border: const OutlineInputBorder(),
              isDense: true,
              prefixIcon: const Icon(Icons.menu_book_outlined, size: 18),
              helperText: _loadingCourses
                  ? 'Loading courses…'
                  : (_yearId != null && _courses.isEmpty
                      ? 'No active courses in this year'
                      : null),
            ),
            items: _courses
                .map((c) => DropdownMenuItem(
                      value: c['id'] as String,
                      child: Text(c['name'] as String? ?? '—'),
                    ))
                .toList(),
            onChanged: _loadingCourses || _submitting
                ? null
                : (v) {
                    setState(() => _courseId = v);
                    _loadRoster();
                  },
          ),
        ],
      ),
    );
  }

  Widget _rosterArea(ThemeData theme) {
    if (_loadingYears || _loadingRoster) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off_outlined,
                size: 44, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _courseId != null ? _loadRoster : _loadYears,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ]),
        ),
      );
    }
    if (_courseId == null) {
      return _hint(theme, Icons.filter_list,
          'Select an academic year and a course to see enrolled students.');
    }
    if (!_hasLoadedRoster) {
      return _hint(theme, Icons.filter_list, 'Loading students…');
    }
    if (_students.isEmpty) {
      return _hint(theme, Icons.person_off_outlined,
          'No active students are enrolled in this course.');
    }

    return Column(
      children: [
        // Select-all header
        CheckboxListTile(
          value: _allSelected,
          tristate: false,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          onChanged: _selectable.isEmpty || _submitting ? null : _toggleSelectAll,
          title: Text(
            'Select All',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: _selectable.isEmpty
                  ? theme.colorScheme.onSurface.withValues(alpha: 0.4)
                  : null,
            ),
          ),
          subtitle: Text(
            '${_students.length} enrolled · ${_selectable.length} with fees added',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadRoster,
            child: ListView.separated(
              itemCount: _students.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _studentTile(theme, _students[i]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _studentTile(ThemeData theme, Map<String, dynamic> s) {
    final id         = s['id'] as String;
    final hasFees    = s['has_fees'] == true;
    final unlocked   = s['is_unlocked'] == true;
    final subjects   = (s['subject_count'] as num?)?.toInt() ?? 0;
    final totalFee   = (s['total_fee'] as num?)?.toDouble() ?? 0;

    return CheckboxListTile(
      value: _selected.contains(id),
      controlAffinity: ListTileControlAffinity.leading,
      // Nothing to unlock when no subject fees were ever assigned.
      onChanged: !hasFees || _submitting ? null : (v) => _toggleStudent(id, v),
      title: Row(
        children: [
          Expanded(
            child: Text(
              s['name'] as String? ?? '',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: hasFees
                    ? null
                    : theme.colorScheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ),
          if (unlocked)
            _Badge(
              label: 'UNLOCKED',
              color: Colors.orange.shade700,
              icon: Icons.lock_open_outlined,
            )
          else if (hasFees)
            _Badge(
              label: 'LOCKED',
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              icon: Icons.lock_outline,
            ),
        ],
      ),
      subtitle: Text(
        hasFees
            ? '$id · $subjects ${subjects == 1 ? 'subject' : 'subjects'} · '
                '₹${totalFee.toStringAsFixed(0)}'
            : '$id · no subject fees added yet',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  Widget _hint(ThemeData theme, IconData icon, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 44,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.28)),
          const SizedBox(height: 12),
          Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
        ]),
      ),
    );
  }
}

// ── Small presentational helpers ────────────────────────────────────────────

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;

  const _Badge({required this.label, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 9.5, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}

class _ConfirmRow extends StatelessWidget {
  final String label;
  final String value;

  const _ConfirmRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6))),
          ),
          Expanded(
            child: Text(value.isEmpty ? '—' : value,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
