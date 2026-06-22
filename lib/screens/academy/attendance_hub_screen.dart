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

class _AttendanceHubScreenState extends State<AttendanceHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance'),
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
      body: TabBarView(
        controller: _tabs,
        children: const [
          _TodayTab(),
          _StudentsTab(),
          _DefaultersTab(),
          _OverallTab(),
        ],
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
  const _TodayTab();
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

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.getInsightsToday();
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
  const _StudentsTab();
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

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.getInsightsStudents();
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
  const _DefaultersTab();
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

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.getInsightsDefaulters();
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
  const _OverallTab();
  @override
  State<_OverallTab> createState() => _OverallTabState();
}

class _OverallTabState extends State<_OverallTab>
    with AutomaticKeepAliveClientMixin {
  // Filter option sources
  List<Map<String, dynamic>> _years = [];
  List<Map<String, dynamic>> _courses = [];
  bool _filtersLoading = true;

  // Selected filters
  String? _yearId;
  String? _courseId;
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
  void initState() {
    super.initState();
    _loadFilters();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFilters() async {
    setState(() { _filtersLoading = true; });
    try {
      final years = await AcademyApiService.getAcademicYears();
      if (!mounted) return;
      setState(() {
        _years = years;
        _filtersLoading = false;
      });
      await _loadCourses(); // pre-load the course list for the (empty) year filter
      // Intentionally NO initial fetch: the user must pick at least one filter
      // and tap Apply. Loading every record up front is slow and can OOM the
      // app on large academies.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _filtersLoading = false;
      });
    }
  }

  /// True when the user has narrowed the query at all. We refuse to fetch the
  /// whole table unfiltered, so Apply is disabled until this is true.
  bool get _hasAnyFilter =>
      _yearId != null ||
      _courseId != null ||
      _fromDate != null ||
      _toDate != null ||
      (_status != null && _status!.isNotEmpty) ||
      _searchCtrl.text.trim().isNotEmpty;

  /// Courses for the currently selected academic year (all years when none).
  Future<void> _loadCourses() async {
    try {
      final list = await AcademyApiService.getCourses(academicYearId: _yearId);
      if (!mounted) return;
      setState(() {
        _courses = list.cast<Map<String, dynamic>>();
        // Drop a course selection that no longer belongs to the chosen year.
        if (_courseId != null &&
            !_courses.any((c) => c['id'] == _courseId)) {
          _courseId = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _courses = []);
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (!_hasAnyFilter) {
      _snack('Select at least one filter (year, course, date range, status, or search) before applying.');
      return;
    }
    if (_fromDate != null && _toDate != null && _fromDate!.isAfter(_toDate!)) {
      _snack('"From Date" must be on or before "To Date".');
      return;
    }
    setState(() { _loading = true; _error = null; _hasQueried = true; });
    try {
      final records = await AcademyApiService.getOverallAttendance(
        academicYearId: _yearId,
        courseId: _courseId,
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

  Future<void> _onYearChanged(String? id) async {
    setState(() => _yearId = id);
    await _loadCourses();
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

  void _clearFilters() {
    setState(() {
      _yearId = null;
      _courseId = null;
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
    _loadCourses();
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
    if (_filtersLoading) {
      return const Center(child: CircularProgressIndicator());
    }
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
                  _yearDropdown(itemW),
                  _courseDropdown(itemW),
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

  Widget _yearDropdown(double width) {
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String?>(
        isExpanded: true,
        initialValue: _yearId,
        decoration: const InputDecoration(
          labelText: 'Academic Year',
          isDense: true,
          border: OutlineInputBorder(),
        ),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('All years')),
          ..._years.map((y) => DropdownMenuItem<String?>(
                value: y['id'] as String?,
                child: Text('${y['academic_year_name'] ?? ''}',
                    overflow: TextOverflow.ellipsis),
              )),
        ],
        onChanged: _onYearChanged,
      ),
    );
  }

  Widget _courseDropdown(double width) {
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String?>(
        isExpanded: true,
        initialValue: _courseId,
        decoration: const InputDecoration(
          labelText: 'Course',
          isDense: true,
          border: OutlineInputBorder(),
        ),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('All courses')),
          ..._courses.map((c) => DropdownMenuItem<String?>(
                value: c['id'] as String?,
                child: Text('${c['name'] ?? ''}', overflow: TextOverflow.ellipsis),
              )),
        ],
        onChanged: (v) => setState(() => _courseId = v),
      ),
    );
  }

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
