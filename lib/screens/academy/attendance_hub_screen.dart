import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';
import '../../services/overall_attendance_excel_service.dart';
import '../../utils/file_opener.dart';
import 'attendance_student_detail_screen.dart';

/// Attendance Intelligence hub (admin/teacher).
///
/// Reached from the "Attendance" Quick Action on the academy admin dashboard.
/// Four tabs over read-only insight endpoints:
///   • Today      — action list (who needs attention now)
///   • Students   — every student with a score band
///   • Defaulters — grouped/sorted by stage
///   • Overall Attendance Data — filterable per-day report + Excel export
class AttendanceHubScreen extends StatefulWidget {
  const AttendanceHubScreen({super.key});

  @override
  State<AttendanceHubScreen> createState() => _AttendanceHubScreenState();
}

/// Screen-level cohort filter: which students every tab reports on.
///
/// Chosen once at the top of Attendance Reports rather than per-tab, so the
/// admin sets "which students am I looking at" before reading any figure.
/// Value type with `==` so the tabs can cheaply detect a real change in
/// `didUpdateWidget` and refetch only then.
@immutable
class AttendanceCohort {
  final String? yearId;
  final List<String> courseIds;

  const AttendanceCohort({this.yearId, this.courseIds = const []});

  bool get isEmpty => yearId == null && courseIds.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is AttendanceCohort &&
      other.yearId == yearId &&
      other.courseIds.length == courseIds.length &&
      other.courseIds.every(courseIds.contains);

  @override
  int get hashCode => Object.hash(yearId, Object.hashAllUnordered(courseIds));
}

class _AttendanceHubScreenState extends State<AttendanceHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  // Filter option sources, loaded once for the whole screen.
  List<Map<String, dynamic>> _years = [];
  List<Map<String, dynamic>> _courses = [];
  bool _loadingFilters = true;
  bool _loadingCourses = false;
  String? _filterError;

  // Current selection. Empty = all years, all courses.
  String? _yearId;
  final Set<String> _courseIds = {};

  AttendanceCohort get _cohort =>
      AttendanceCohort(yearId: _yearId, courseIds: _courseIds.toList());

  @override
  void initState() {
    super.initState();
    _loadYears();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadYears() async {
    setState(() { _loadingFilters = true; _filterError = null; });
    try {
      final years = await AcademyApiService.getAcademicYears();
      if (!mounted) return;
      setState(() {
        _years = years.cast<Map<String, dynamic>>();
        _loadingFilters = false;
      });
      await _loadCourses();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _filterError = e.toString().replaceFirst('Exception: ', '');
        _loadingFilters = false;
      });
    }
  }

  /// Courses for the selected year (all years when none is chosen).
  Future<void> _loadCourses() async {
    setState(() => _loadingCourses = true);
    try {
      final list = await AcademyApiService.getCourses(academicYearId: _yearId);
      if (!mounted) return;
      setState(() {
        _courses = list.cast<Map<String, dynamic>>();
        // Drop selections that no longer belong to the chosen year, so the
        // filter can never send a course id the year doesn't contain.
        final valid = _courses.map((c) => c['id'] as String).toSet();
        _courseIds.removeWhere((id) => !valid.contains(id));
        _loadingCourses = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() { _courses = []; _courseIds.clear(); _loadingCourses = false; });
    }
  }

  void _onYearChanged(String? id) {
    setState(() => _yearId = id);
    _loadCourses();
  }

  Future<void> _pickCourses() async {
    if (_courses.isEmpty) return;
    final draft = {..._courseIds};
    final saved = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                child: Row(children: [
                  const Expanded(
                    child: Text('Select courses',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  TextButton(
                    onPressed: () => setSheet(() {
                      if (draft.length == _courses.length) {
                        draft.clear();
                      } else {
                        draft
                          ..clear()
                          ..addAll(_courses.map((c) => c['id'] as String));
                      }
                    }),
                    child: Text(draft.length == _courses.length
                        ? 'Clear all'
                        : 'Select all'),
                  ),
                ]),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: _courses.map((c) {
                    final id = c['id'] as String;
                    return CheckboxListTile(
                      dense: true,
                      value: draft.contains(id),
                      title: Text(c['name'] as String? ?? ''),
                      onChanged: (v) => setSheet(() {
                        if (v == true) {
                          draft.add(id);
                        } else {
                          draft.remove(id);
                        }
                      }),
                    );
                  }).toList(),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, draft),
                      child: Text(draft.isEmpty
                          ? 'Apply (all courses)'
                          : 'Apply (${draft.length})'),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );

    if (saved == null || !mounted) return;
    setState(() {
      _courseIds
        ..clear()
        ..addAll(saved);
    });
  }

  String get _coursesLabel {
    if (_courseIds.isEmpty) return 'All courses';
    if (_courseIds.length == 1) {
      final match = _courses.where((c) => c['id'] == _courseIds.first);
      return match.isEmpty ? '1 course' : (match.first['name'] as String? ?? '1 course');
    }
    return '${_courseIds.length} courses selected';
  }

  @override
  Widget build(BuildContext context) {
    final cohort = _cohort;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Reports'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Today'),
            Tab(text: 'Students'),
            Tab(text: 'Defaulters'),
            Tab(text: 'Overall Attendance Data'),
          ],
        ),
      ),
      body: Column(
        children: [
          _cohortBar(),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _TodayTab(cohort: cohort),
                _StudentsTab(cohort: cohort),
                _DefaultersTab(cohort: cohort),
                _OverallTab(cohort: cohort, courses: _courses),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Academic year + multi-select courses, applied to every tab below.
  Widget _cohortBar() {
    final theme = Theme.of(context);

    if (_loadingFilters) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (_filterError != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(child: Text(_filterError!, style: const TextStyle(fontSize: 12.5))),
          TextButton(onPressed: _loadYears, child: const Text('Retry')),
        ]),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 8.0;
          // Side by side when there's room, stacked on narrow phones.
          final twoUp = constraints.maxWidth >= 420;
          final w = twoUp ? (constraints.maxWidth - gap) / 2 : constraints.maxWidth;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              SizedBox(
                width: w,
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  initialValue: _yearId,
                  decoration: const InputDecoration(
                    labelText: 'Academic Year',
                    isDense: true,
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.calendar_today_outlined, size: 17),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('All years')),
                    ..._years.map((y) => DropdownMenuItem<String?>(
                          value: y['id'] as String?,
                          child: Text('${y['academic_year_name'] ?? ''}',
                              overflow: TextOverflow.ellipsis),
                        )),
                  ],
                  onChanged: _onYearChanged,
                ),
              ),
              SizedBox(
                width: w,
                child: InkWell(
                  onTap: _loadingCourses || _courses.isEmpty ? null : _pickCourses,
                  borderRadius: BorderRadius.circular(4),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Courses',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.menu_book_outlined, size: 17),
                      suffixIcon: const Icon(Icons.arrow_drop_down),
                      helperText: _loadingCourses
                          ? 'Loading…'
                          : (_courses.isEmpty ? 'No courses in this year' : null),
                    ),
                    child: Text(
                      _coursesLabel,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: _courseIds.isEmpty
                            ? theme.colorScheme.onSurface.withValues(alpha: 0.6)
                            : theme.colorScheme.onSurface,
                        fontWeight:
                            _courseIds.isEmpty ? FontWeight.normal : FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Shared band styling ─────────────────────────────────────────────────────────

Color bandColor(String? band) {
  switch (band) {
    case 'green':  return Colors.green;
    case 'yellow': return Colors.amber.shade700;
    case 'orange': return Colors.orange.shade800;
    case 'red':    return Colors.red;
    default:       return Colors.grey;
  }
}

Color riskColor(String? risk) {
  switch (risk) {
    case 'high':   return Colors.red;
    case 'medium': return Colors.orange.shade800;
    case 'low':    return Colors.green;
    default:       return Colors.grey;
  }
}

Widget pctChip(num? pct, String? band) {
  final p = (pct ?? 0).toDouble();
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: bandColor(band).withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text('${p.toStringAsFixed(0)}%',
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.bold, color: bandColor(band))),
  );
}

// ── A reusable list-state wrapper (loading / error / empty / content) ────────────

class _AsyncList extends StatelessWidget {
  final bool loading;
  final String? error;
  final bool isEmpty;
  final String emptyText;
  final Future<void> Function() onRetry;
  final Widget child;

  const _AsyncList({
    required this.loading,
    required this.error,
    required this.isEmpty,
    required this.emptyText,
    required this.onRetry,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off_outlined, size: 48,
                color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry')),
          ]),
        ),
      );
    }
    if (isEmpty) {
      return RefreshIndicator(
        onRefresh: onRetry,
        child: ListView(children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.3),
          Center(
            child: Column(children: [
              Icon(Icons.check_circle_outline, size: 48,
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
              const SizedBox(height: 8),
              Text(emptyText,
                  style: TextStyle(color: Theme.of(context)
                      .colorScheme.onSurface.withValues(alpha: 0.6))),
            ]),
          ),
        ]),
      );
    }
    return RefreshIndicator(onRefresh: onRetry, child: child);
  }
}

// ── Today tab ────────────────────────────────────────────────────────────────

class _TodayTab extends StatefulWidget {
  final AttendanceCohort cohort;
  const _TodayTab({required this.cohort});
  @override
  State<_TodayTab> createState() => _TodayTabState();
}

class _TodayTabState extends State<_TodayTab>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _groups = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _TodayTab old) {
    super.didUpdateWidget(old);
    if (old.cohort != widget.cohort) _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.getInsightsToday(
        academicYearId: widget.cohort.yearId,
        courseIds: widget.cohort.courseIds,
      );
      if (!mounted) return;
      setState(() {
        _groups = (data['groups'] as Map?)?.cast<String, dynamic>() ?? {};
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> _g(String key) =>
      ((_groups[key] as List?) ?? []).cast<Map<String, dynamic>>();

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final below   = _g('below_threshold');
    final streaks = _g('consecutive_absences');
    final drops   = _g('sharp_drop');
    final notSeen = _g('not_seen');
    final total   = below.length + streaks.length + drops.length + notSeen.length;

    return _AsyncList(
      loading: _loading,
      error: _error,
      isEmpty: total == 0,
      emptyText: 'Nothing needs attention today 🎉',
      onRetry: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _section('Below threshold', Icons.trending_down, Colors.red, below,
              subtitle: (m) => '${(m['attendance_pct'] ?? 0)}% • ${m['stage_label'] ?? ''}'),
          _section('Consecutive absences', Icons.event_busy, Colors.deepOrange, streaks,
              subtitle: (m) => '${m['consecutive_absences'] ?? 0} days in a row'),
          _section('Sharp drop', Icons.south_east, Colors.orange, drops,
              subtitle: (m) => 'Recent attendance falling'),
          _section('Not seen recently', Icons.visibility_off_outlined, Colors.blueGrey, notSeen,
              subtitle: (m) => 'Last seen ${m['days_since_last_seen'] ?? '?'} days ago'),
        ],
      ),
    );
  }

  Widget _section(String title, IconData icon, Color color,
      List<Map<String, dynamic>> items,
      {required String Function(Map<String, dynamic>) subtitle}) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Row(children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(title, style: TextStyle(
                  fontWeight: FontWeight.bold, color: color)),
              const Spacer(),
              Text('${items.length}',
                  style: TextStyle(color: color, fontWeight: FontWeight.bold)),
            ]),
          ),
          const Divider(height: 1),
          ...items.map((m) => ListTile(
                dense: true,
                title: Text(m['name'] as String? ?? '',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                subtitle: Text(subtitle(m), style: const TextStyle(fontSize: 12)),
                trailing: pctChip(m['attendance_pct'] as num?, m['band'] as String?),
                onTap: () => _openDetail(m['student_id'] as String?, m['name'] as String?),
              )),
        ],
      ),
    );
  }

  void _openDetail(String? id, String? name) {
    if (id == null) return;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => AttendanceStudentDetailScreen(studentId: id, studentName: name ?? ''),
    ));
  }
}

// ── Students tab ───────────────────────────────────────────────────────────────

class _StudentsTab extends StatefulWidget {
  final AttendanceCohort cohort;
  const _StudentsTab({required this.cohort});
  @override
  State<_StudentsTab> createState() => _StudentsTabState();
}

class _StudentsTabState extends State<_StudentsTab>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _all = [];
  String _query = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _StudentsTab old) {
    super.didUpdateWidget(old);
    if (old.cohort != widget.cohort) _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.getInsightsStudents(
        academicYearId: widget.cohort.yearId,
        courseIds: widget.cohort.courseIds,
      );
      if (!mounted) return;
      setState(() {
        _all = ((data['students'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_query.isEmpty) return _all;
    final q = _query.toLowerCase();
    return _all.where((m) =>
        (m['name'] as String? ?? '').toLowerCase().contains(q) ||
        (m['student_id'] as String? ?? '').toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search name or ID',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: _AsyncList(
            loading: _loading,
            error: _error,
            isEmpty: _filtered.isEmpty,
            emptyText: 'No students',
            onRetry: _load,
            child: ListView.separated(
              itemCount: _filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final m = _filtered[i];
                return ListTile(
                  title: Text(m['name'] as String? ?? ''),
                  subtitle: Row(children: [
                    Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                          color: riskColor(m['risk'] as String?),
                          shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text('Risk: ${(m['risk'] as String? ?? 'n/a').toUpperCase()}',
                        style: const TextStyle(fontSize: 12)),
                  ]),
                  trailing: pctChip(m['attendance_pct'] as num?, m['band'] as String?),
                  onTap: () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => AttendanceStudentDetailScreen(
                      studentId: m['student_id'] as String,
                      studentName: m['name'] as String? ?? '',
                    ),
                  )),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ── Defaulters tab ───────────────────────────────────────────────────────────

class _DefaultersTab extends StatefulWidget {
  final AttendanceCohort cohort;
  const _DefaultersTab({required this.cohort});
  @override
  State<_DefaultersTab> createState() => _DefaultersTabState();
}

class _DefaultersTabState extends State<_DefaultersTab>
    with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _list = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _DefaultersTab old) {
    super.didUpdateWidget(old);
    if (old.cohort != widget.cohort) _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.getInsightsDefaulters(
        academicYearId: widget.cohort.yearId,
        courseIds: widget.cohort.courseIds,
      );
      if (!mounted) return;
      setState(() {
        _list = ((data['defaulters'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _AsyncList(
      loading: _loading,
      error: _error,
      isEmpty: _list.isEmpty,
      emptyText: 'No defaulters 🎉',
      onRetry: _load,
      child: ListView.separated(
        itemCount: _list.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final m = _list[i];
          return ListTile(
            title: Text(m['name'] as String? ?? ''),
            subtitle: Text(m['stage_label'] as String? ?? '',
                style: const TextStyle(fontSize: 12)),
            trailing: pctChip(m['attendance_pct'] as num?, m['band'] as String?),
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => AttendanceStudentDetailScreen(
                studentId: m['student_id'] as String,
                studentName: m['name'] as String? ?? '',
              ),
            )),
          );
        },
      ),
    );
  }
}

// ── Overall Attendance Data tab ──────────────────────────────────────────────
//
// Consolidated per-day report with server-side filters (academic year, course,
// student search, date, status, late), an on-screen data grid, and an Excel
// export that mirrors the currently-applied filters.

class _OverallTab extends StatefulWidget {
  /// Academic year + courses come from the screen-level filter above the tabs.
  final AttendanceCohort cohort;
  /// Course list for the selected year, so the tab can name what it filtered by.
  final List<Map<String, dynamic>> courses;

  const _OverallTab({required this.cohort, required this.courses});

  @override
  State<_OverallTab> createState() => _OverallTabState();
}

class _OverallTabState extends State<_OverallTab>
    with AutomaticKeepAliveClientMixin {
  // Row-level filters that remain local to this tab. Academic year and course
  // moved up to the screen-level cohort bar.
  DateTime? _fromDate;
  DateTime? _toDate;
  String? _status; // present | absent
  final _searchCtrl = TextEditingController();

  // Results
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _records = [];
  bool _hasQueried = false;

  // Export
  bool _exporting = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Changing the screen-level cohort invalidates any results already on screen,
  /// so they are cleared and the admin re-applies against the new cohort.
  @override
  void didUpdateWidget(covariant _OverallTab old) {
    super.didUpdateWidget(old);
    if (old.cohort != widget.cohort && _hasQueried) {
      setState(() { _records = []; _hasQueried = false; _error = null; });
    }
  }

  /// True when the query is narrowed at all — by the screen-level cohort or by
  /// this tab's own row filters. We refuse to fetch the whole table unfiltered,
  /// so Apply stays disabled until this is true.
  bool get _hasAnyFilter =>
      !widget.cohort.isEmpty ||
      _fromDate != null ||
      _toDate != null ||
      (_status != null && _status!.isNotEmpty) ||
      _searchCtrl.text.trim().isNotEmpty;

  Future<void> _load() async {
    if (!mounted) return;
    if (!_hasAnyFilter) {
      _snack('Select an academic year or courses above, or a date range, status, '
          'or search below, before applying.');
      return;
    }
    if (_fromDate != null && _toDate != null && _fromDate!.isAfter(_toDate!)) {
      _snack('"From Date" must be on or before "To Date".');
      return;
    }
    setState(() { _loading = true; _error = null; _hasQueried = true; });
    try {
      final records = await AcademyApiService.getOverallAttendance(
        academicYearId: widget.cohort.yearId,
        courseIds: widget.cohort.courseIds,
        search: _searchCtrl.text.trim().isEmpty ? null : _searchCtrl.text.trim(),
        fromDate: _fromDate == null ? null : _ymd(_fromDate!),
        toDate: _toDate == null ? null : _ymd(_toDate!),
        status: _status,
      );
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

  Future<void> _pickFromDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _fromDate ?? _toDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      // Can't start after the chosen end date (when set).
      lastDate: _toDate ?? DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) setState(() => _fromDate = picked);
  }

  Future<void> _pickToDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _toDate ?? _fromDate ?? DateTime.now(),
      // Can't end before the chosen start date (when set).
      firstDate: _fromDate ?? DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) setState(() => _toDate = picked);
  }

  /// Clears this tab's own filters. The screen-level academic year and courses
  /// are deliberately left alone — they scope every tab, so clearing them from
  /// inside one tab would silently change the other three.
  void _clearFilters() {
    setState(() {
      _fromDate = null;
      _toDate = null;
      _status = null;
      _searchCtrl.clear();
      // Reset results too — clearing filters returns to the "pick filters" state
      // rather than re-fetching everything.
      _records = [];
      _hasQueried = false;
      _error = null;
    });
  }

  Future<void> _export() async {
    if (_records.isEmpty) {
      _snack('Nothing to export — no records match the filters.');
      return;
    }
    setState(() => _exporting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await OverallAttendanceExcelService.generate(_records);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Saved ${path.split(RegExp(r"[\\/]")).last}'),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => FileOpener.open(path),
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text('Export failed: ${e.toString().replaceFirst('Exception: ', '')}')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // The year/course dropdowns this tab used to load for itself now live in the
    // screen-level bar, so there is nothing to wait for before painting.
    return Column(
      children: [
        _filterBar(),
        const Divider(height: 1),
        Expanded(child: _resultArea()),
      ],
    );
  }

  // ── Filter bar ──────────────────────────────────────────────────────────────

  Widget _filterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search by Student ID or Name
          TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search Student ID or Name',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _searchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() {});
                      },
                    ),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _load(),
          ),
          const SizedBox(height: 8),
          // Responsive filter grid: two columns on phones, more on wider
          // screens. Each control fills its computed slot so nothing is cut off.
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 8.0;
              final maxW = constraints.maxWidth;
              // Aim for ~180px columns, but never fewer than 2 (phones) and use
              // floor so items always fit within the available width.
              final cols = (maxW / 188).floor().clamp(2, 4);
              final itemW = (maxW - spacing * (cols - 1)) / cols;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  // Academic year and courses live in the screen-level bar above
                  // the tabs — they scope every tab, not just this one.
                  _dateChip(itemW, isFrom: true),
                  _dateChip(itemW, isFrom: false),
                  _statusDropdown(itemW),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          // Apply + Clear share the row width (Expanded) so they never overflow
          // on narrow phones; Download Excel is a full-width button below.
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: (_loading || !_hasAnyFilter) ? null : _load,
                  icon: const Icon(Icons.filter_alt, size: 18),
                  label: const Text('Apply'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (_loading || !_hasAnyFilter) ? null : _clearFilters,
                  icon: const Icon(Icons.clear_all, size: 18),
                  label: const Text('Clear'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: (_exporting || _records.isEmpty) ? null : _export,
              icon: _exporting
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_outlined, size: 18),
              label: Text(_exporting ? 'Exporting…' : 'Download Excel'),
            ),
          ),
        ],
      ),
    );
  }

  // _yearDropdown / _courseDropdown were removed: academic year and course
  // selection moved to the screen-level cohort bar above the tabs, where the
  // course picker is multi-select and scopes all four tabs.

  Widget _dateChip(double width, {required bool isFrom}) {
    final value = isFrom ? _fromDate : _toDate;
    final hint = isFrom ? 'From Date' : 'To Date';
    return SizedBox(
      width: width,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          alignment: Alignment.centerLeft,
        ),
        onPressed: isFrom ? _pickFromDate : _pickToDate,
        icon: const Icon(Icons.calendar_today, size: 16),
        label: Row(
          children: [
            Expanded(
              child: Text(
                value == null ? hint : _ymd(value),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (value != null)
              GestureDetector(
                onTap: () => setState(() {
                  if (isFrom) {
                    _fromDate = null;
                  } else {
                    _toDate = null;
                  }
                }),
                child: const Icon(Icons.close, size: 16),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusDropdown(double width) {
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String?>(
        isExpanded: true,
        initialValue: _status,
        decoration: const InputDecoration(
          labelText: 'Status',
          isDense: true,
          border: OutlineInputBorder(),
        ),
        items: const [
          DropdownMenuItem<String?>(value: null, child: Text('All statuses')),
          DropdownMenuItem<String?>(value: 'present', child: Text('Present')),
          DropdownMenuItem<String?>(value: 'absent', child: Text('Absent')),
        ],
        onChanged: (v) => setState(() => _status = v),
      ),
    );
  }

  // ── Results ───────────────────────────────────────────────────────────────

  Widget _resultArea() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off_outlined, size: 48,
                color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry')),
          ]),
        ),
      );
    }
    if (_records.isEmpty) {
      final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(_hasQueried ? Icons.search_off : Icons.filter_alt_outlined,
                size: 48, color: muted),
            const SizedBox(height: 12),
            Text(
              _hasQueried
                  ? 'No records match the selected filters'
                  : 'Select a filter — academic year, course, date range, status, '
                    'or search — then tap Apply to load attendance.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted),
            ),
          ]),
        ),
      );
    }
    return _dataGrid();
  }

  Widget _dataGrid() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('${_records.length} record(s)',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 40,
                dataRowMinHeight: 36,
                dataRowMaxHeight: 44,
                columns: const [
                  DataColumn(label: Text('Student ID')),
                  DataColumn(label: Text('Student Name')),
                  DataColumn(label: Text('Academic Year')),
                  DataColumn(label: Text('Course Name')),
                  DataColumn(label: Text('Present Date')),
                  DataColumn(label: Text('Day')),
                  DataColumn(label: Text('First Check-In')),
                  DataColumn(label: Text('Last Check-Out')),
                  DataColumn(label: Text('Total Time Spent')),
                  DataColumn(label: Text('Attendance Status')),
                  DataColumn(label: Text('Attendance %')),
                  DataColumn(label: Text('Remarks')),
                ],
                rows: _records.map(_dataRow).toList(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  DataRow _dataRow(Map<String, dynamic> m) {
    final pct = (m['attendance_pct'] as num?)?.toDouble() ?? 0;
    return DataRow(cells: [
      DataCell(Text(m['student_id'] as String? ?? '')),
      DataCell(Text(m['name'] as String? ?? '')),
      DataCell(Text(m['academic_year'] as String? ?? '')),
      DataCell(Text(m['course_name'] as String? ?? '')),
      DataCell(Text(m['date'] as String? ?? '')),
      DataCell(Text(m['day'] as String? ?? '')),
      DataCell(Text(m['first_check_in'] as String? ?? '')),
      DataCell(Text(m['last_check_out'] as String? ?? '')),
      DataCell(Text(OverallAttendanceExcelService.formatDuration(m['total_mins']))),
      DataCell(Text(OverallAttendanceExcelService.statusLabel(m['status'] as String?))),
      DataCell(Text('${pct.toStringAsFixed(2)}%')),
      DataCell(Text(m['remarks'] as String? ?? '')),
    ]);
  }
}
