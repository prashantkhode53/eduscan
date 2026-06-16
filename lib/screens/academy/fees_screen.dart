import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/academy_api_service.dart';
import '../../services/fee_pdf_service.dart';
import '../../services/fee_excel_service.dart';
import '../../providers/auth_provider.dart';
import '../../utils/fee_format.dart';
import '../../utils/date_utils.dart' as du;
import 'student_fees_detail_tab.dart';

class FeesScreen extends StatefulWidget {
  const FeesScreen({super.key});

  @override
  State<FeesScreen> createState() => _FeesScreenState();
}

class _FeesScreenState extends State<FeesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  final List<_Tab> _tabs = const [
    _Tab('All',     null),
    _Tab('Pending', 'pending'),
    _Tab('Overdue', 'overdue'),
    _Tab('Partial', 'partial'),
    _Tab('Paid',    'paid'),
  ];

  List<Map<String, dynamic>> _all     = [];
  Map<String, dynamic>       _summary = {};
  bool    _loading      = true;
  String? _dueFilter;   // 'today' | 'this_week' | 'this_month' | 'overdue' | 'upcoming' | null
  int     _reloadTrigger = 0;

  // ── Entry-level Academic Year + Course scope ────────────────────────────────
  // The whole module is gated behind a single Academic Year + one-or-more
  // Courses. Tabs/data load only once both are chosen; selection lives here so
  // it persists across tab switches.
  List<Map<String, dynamic>> _years   = [];
  List<Map<String, dynamic>> _courses = [];   // courses for the selected year
  String?       _yearId;
  final Set<String> _courseIds = {};
  bool _metaLoading   = true;   // loading years/courses for the gate
  bool _coursesBusy   = false;  // reloading courses after a year change
  bool _scopeApplied  = false;  // true once the user taps Continue

  bool get _ready => _scopeApplied && _yearId != null && _courseIds.isNotEmpty;

  static const _dueFilters = [
    ('today',      'Due Today',     Icons.today_outlined),
    ('this_week',  'This Week',     Icons.date_range_outlined),
    ('this_month', 'This Month',    Icons.calendar_month_outlined),
    ('overdue',    'Overdue',       Icons.warning_amber_outlined),
    ('upcoming',   'Upcoming',      Icons.schedule_outlined),
  ];

  @override
  void initState() {
    super.initState();
    // Tabs: Students + 5 status tabs + Receipts + Export Excel = 8
    _tabCtrl = TabController(length: _tabs.length + 3, vsync: this);
    _tabCtrl.addListener(() { if (mounted) setState(() {}); });
    _loadMeta();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  // Load academic years + the current year's courses for the gate dropdowns.
  // Defaults the year to the academy's current year (if flagged) but never
  // auto-selects a course — the gate stays closed until the user picks one.
  Future<void> _loadMeta() async {
    if (!mounted) return;
    setState(() => _metaLoading = true);
    try {
      final years = await AcademyApiService.getAcademicYears();
      String? defaultYear;
      for (final y in years) {
        if (y['is_current_year'] == true) { defaultYear = y['id'] as String?; break; }
      }
      defaultYear ??= years.isNotEmpty ? years.first['id'] as String? : null;
      if (!mounted) return;
      setState(() {
        _years  = years;
        _yearId = defaultYear;
      });
      if (defaultYear != null) await _loadCoursesForYear(defaultYear);
    } catch (_) {
      // Non-fatal: the gate shows empty dropdowns with a retry option.
    } finally {
      if (mounted) setState(() => _metaLoading = false);
    }
  }

  Future<void> _loadCoursesForYear(String yearId) async {
    if (!mounted) return;
    setState(() => _coursesBusy = true);
    try {
      final courses = await AcademyApiService.getCourses(academicYearId: yearId);
      if (!mounted) return;
      setState(() => _courses = courses.cast<Map<String, dynamic>>());
    } catch (_) {
      if (mounted) setState(() => _courses = []);
    } finally {
      if (mounted) setState(() => _coursesBusy = false);
    }
  }

  void _onYearChanged(String? yearId) {
    if (yearId == null || yearId == _yearId) return;
    setState(() {
      _yearId = yearId;
      _courseIds.clear();   // courses belong to a year — reset on change
      _courses = [];
    });
    _loadCoursesForYear(yearId);
  }

  void _applyScope() {
    if (_yearId == null || _courseIds.isEmpty) return;
    setState(() {
      _scopeApplied = true;
      _reloadTrigger++;   // force keep-alive tabs to reload with new scope
    });
    _load();
  }

  void _editScope() {
    // Return to the gate; current selections are preserved.
    setState(() => _scopeApplied = false);
  }

  Future<void> _load() async {
    if (!mounted || !_ready) return;
    setState(() => _loading = true);
    try {
      final data = await AcademyApiService.getFees(
        dueFilter:      _dueFilter,
        academicYearId: _yearId,
        courseIds:      _courseIds.toList(),
        limit:          200,
      );
      if (!mounted) return;
      setState(() {
        _all     = (data['records'] as List).cast<Map<String, dynamic>>();
        _summary = data['summary'] as Map<String, dynamic>? ?? {};
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _onPaymentMade() {
    setState(() => _reloadTrigger++);
    _load();
  }

  List<Map<String, dynamic>> _filtered(String? status) => status == null
      ? _all
      : _all.where((r) => r['status'] == status).toList();

  void _setDueFilter(String? filter) {
    setState(() => _dueFilter = filter);
    _load();
  }

  Future<void> _generateFees() async {
    try {
      final result = await AcademyApiService.generateMonthlyFees();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result['message']?.toString() ?? 'Fee records generated'),
          backgroundColor: Colors.green,
        ));
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _markOverdue() async {
    try {
      await AcademyApiService.markOverdueFees();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Overdue fees updated'),
          backgroundColor: Colors.orange,
        ));
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    }
  }

  // True for Students tab (0) and status tabs (1–5) — not Receipts (6)
  bool get _showFilterStrip => _tabCtrl.index <= _tabs.length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fees Management'),
        actions: _ready
            ? [
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'generate') _generateFees();
                    if (v == 'overdue')  _markOverdue();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'generate',
                        child: ListTile(
                            leading: Icon(Icons.add_circle_outline),
                            title: Text('Generate Course Fees'),
                            dense: true)),
                    const PopupMenuItem(
                        value: 'overdue',
                        child: ListTile(
                            leading: Icon(Icons.warning_amber_outlined,
                                color: Colors.orange),
                            title: Text('Mark Overdue'),
                            dense: true)),
                  ],
                ),
              ]
            : null,
        bottom: _ready
            ? TabBar(
                controller: _tabCtrl,
                isScrollable: true,
                tabs: [
                  const Tab(text: 'Students'),
                  ..._tabs.map((t) => Tab(
                        child: Text(
                          t.status == null
                              ? 'All (${_all.length})'
                              : '${t.label} (${_filtered(t.status).length})',
                        ),
                      )),
                  const Tab(text: 'Receipts'),
                  const Tab(text: 'Export Excel'),
                ],
              )
            : null,
      ),
      body: _ready ? _buildTabsBody(theme) : _buildGate(theme),
    );
  }

  // ── Tabs body (shown after a scope is applied) ──────────────────────────────

  Widget _buildTabsBody(ThemeData theme) {
    return Column(
        children: [
          _buildScopeBar(theme),
          if (_showFilterStrip)
            Container(
              color: theme.colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row: active filter label + clear + loading
                  Row(
                    children: [
                      Icon(
                        _dueFilter != null
                            ? _dueFilters.firstWhere((f) => f.$1 == _dueFilter).$3
                            : Icons.receipt_long_outlined,
                        size: 16, color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _dueFilter != null
                            ? _dueFilters.firstWhere((f) => f.$1 == _dueFilter).$2
                            : 'All Fees',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary),
                      ),
                      if (_dueFilter != null) ...[
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: () => _setDueFilter(null),
                          borderRadius: BorderRadius.circular(12),
                          child: Icon(Icons.close, size: 16,
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                        ),
                      ],
                      const Spacer(),
                      if (_loading)
                        const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Due-date filter chips
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _dueFilters.map((f) {
                        final isActive = _dueFilter == f.$1;
                        final chipColor = f.$1 == 'overdue'
                            ? Colors.red
                            : f.$1 == 'today' || f.$1 == 'this_week'
                                ? Colors.orange
                                : theme.colorScheme.primary;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: FilterChip(
                            label: Text(f.$2,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: isActive ? Colors.white : chipColor)),
                            avatar: Icon(f.$3, size: 14,
                                color: isActive ? Colors.white : chipColor),
                            selected: isActive,
                            onSelected: (_) =>
                                _setDueFilter(isActive ? null : f.$1),
                            backgroundColor:
                                chipColor.withValues(alpha: 0.08),
                            selectedColor: chipColor,
                            checkmarkColor: Colors.white,
                            side: BorderSide(
                                color: isActive
                                    ? chipColor
                                    : chipColor.withValues(alpha: 0.3)),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                          ),
                        );
                      }).toList(),
                    ),
                  ),

                  // Summary stats (only on fee-list tabs, not Students tab)
                  if (!_loading && _summary.isNotEmpty && _tabCtrl.index > 0) ...[
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _SummaryChip(
                              label: 'Collected',
                              value: '₹${_fmt(_summary['total_paid'])}',
                              color: Colors.green),
                          const SizedBox(width: 8),
                          _SummaryChip(
                              label: 'Pending',
                              value: '${_summary['count_pending'] ?? 0}',
                              color: Colors.orange),
                          const SizedBox(width: 8),
                          _SummaryChip(
                              label: 'Partial',
                              value: '${_summary['count_partial'] ?? 0}',
                              color: Colors.blue),
                          const SizedBox(width: 8),
                          _SummaryChip(
                              label: 'Overdue',
                              value: '${_summary['count_overdue'] ?? 0}',
                              color: Colors.red),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),

          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                // Tab 0: Students — collect fees
                _StudentsTab(
                  dueFilter:     _dueFilter,
                  yearId:        _yearId,
                  courseIds:     _courseIds.toList(),
                  reloadTrigger: _reloadTrigger,
                  onPaymentMade: _onPaymentMade,
                ),
                // Tabs 1–5: flat status lists
                ..._tabs.map((t) => _FeeList(
                      records: _filtered(t.status),
                      loading: _loading,
                      onCollect: (record) async {
                        // Pass the individual fee_records inside this course aggregate
                        final pendingRecords =
                            (record['fee_records'] as List? ?? [record])
                                .cast<Map<String, dynamic>>();
                        final ok = await showModalBottomSheet<bool>(
                          context: context,
                          isScrollControlled: true,
                          useSafeArea: true,
                          shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(20))),
                          builder: (_) => FeeCollectionSheet(
                            studentId: record['student_id'] as String? ?? '',
                            studentName:
                                '${record['first_name'] ?? ''} ${record['last_name'] ?? ''}'
                                    .trim(),
                            mobile: record['mobile'] as String? ?? '',
                            pendingRecords: pendingRecords,
                          ),
                        );
                        if (ok == true) _onPaymentMade();
                      },
                    )),
                // Tab 6: Receipts
                _ReceiptsTab(
                  yearId:    _yearId,
                  courseIds: _courseIds.toList(),
                  reloadTrigger: _reloadTrigger,
                ),
                // Tab 7: Export Excel
                _ExportExcelTab(
                  yearId:    _yearId,
                  courseIds: _courseIds.toList(),
                  yearName:  _years.firstWhere(
                        (y) => y['id'] == _yearId,
                        orElse: () => const {},
                      )['academic_year_name'] as String? ??
                      '',
                  courseCount: _courseIds.length,
                ),
              ],
            ),
          ),
        ],
      );
  }

  String _fmt(dynamic v) {
    if (v == null) return '0';
    final d = double.tryParse(v.toString()) ?? 0;
    return d.toStringAsFixed(0);
  }

  // ── Entry gate: pick Academic Year + Course(s) before loading any fee data ───

  Widget _buildGate(ThemeData theme) {
    if (_metaLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final selectedCourses = _courses
        .where((c) => _courseIds.contains(c['id'] as String?))
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Icon(Icons.tune, size: 44, color: theme.colorScheme.primary),
          const SizedBox(height: 8),
          Text('Select Academic Year & Course',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Choose a year and at least one course to view fee records.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 24),

          // Academic Year (single)
          DropdownButtonFormField<String>(
            value: _yearId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Academic Year',
              prefixIcon: Icon(Icons.calendar_today_outlined),
              border: OutlineInputBorder(),
            ),
            items: _years
                .map((y) => DropdownMenuItem<String>(
                      value: y['id'] as String?,
                      child: Text(
                        '${y['academic_year_name'] ?? ''}'
                        '${y['is_current_year'] == true ? '  (Current)' : ''}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ))
                .toList(),
            onChanged: _onYearChanged,
          ),
          const SizedBox(height: 16),

          // Courses (multi-select)
          InkWell(
            onTap: (_yearId == null || _coursesBusy) ? null : _openCoursePicker,
            borderRadius: BorderRadius.circular(4),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Courses',
                prefixIcon: const Icon(Icons.menu_book_outlined),
                border: const OutlineInputBorder(),
                suffixIcon: _coursesBusy
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)))
                    : const Icon(Icons.arrow_drop_down),
              ),
              child: _courseIds.isEmpty
                  ? Text(
                      _yearId == null
                          ? 'Select a year first'
                          : 'Tap to select courses',
                      style: TextStyle(
                          color:
                              theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                    )
                  : Wrap(
                      spacing: 6, runSpacing: 4,
                      children: selectedCourses
                          .map((c) => Chip(
                                label: Text(c['name'] as String? ?? '',
                                    style: const TextStyle(fontSize: 12)),
                                onDeleted: () => setState(
                                    () => _courseIds.remove(c['id'] as String?)),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              ))
                          .toList(),
                    ),
            ),
          ),
          if (_yearId != null && !_coursesBusy && _courses.isEmpty) ...[
            const SizedBox(height: 8),
            Text('No courses found for this academic year.',
                style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 24),

          FilledButton.icon(
            onPressed:
                (_yearId != null && _courseIds.isNotEmpty) ? _applyScope : null,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Continue'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          ),
        ],
      ),
    );
  }

  Future<void> _openCoursePicker() async {
    // Multi-select checkable menu over the selected year's courses.
    final temp = Set<String>.from(_courseIds);
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final allSelected =
              _courses.isNotEmpty && temp.length == _courses.length;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      const Text('Select Courses',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setSheet(() {
                          if (allSelected) {
                            temp.clear();
                          } else {
                            temp
                              ..clear()
                              ..addAll(_courses.map((c) => c['id'] as String));
                          }
                        }),
                        child: Text(allSelected ? 'Clear all' : 'Select all'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: _courses.map((c) {
                      final id = c['id'] as String;
                      return CheckboxListTile(
                        dense: true,
                        value: temp.contains(id),
                        title: Text(c['name'] as String? ?? ''),
                        onChanged: (v) => setSheet(() {
                          if (v == true) {
                            temp.add(id);
                          } else {
                            temp.remove(id);
                          }
                        }),
                      );
                    }).toList(),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, temp),
                    style:
                        FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                    child: Text('Done (${temp.length} selected)'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _courseIds
          ..clear()
          ..addAll(result);
      });
    }
  }

  // ── Persistent scope bar (shown above the tabs) ─────────────────────────────

  Widget _buildScopeBar(ThemeData theme) {
    final yearName = _years.firstWhere(
      (y) => y['id'] == _yearId,
      orElse: () => const {},
    )['academic_year_name'] as String? ?? '';
    final courseLabel = _courseIds.length == 1
        ? (_courses.firstWhere(
              (c) => c['id'] == _courseIds.first,
              orElse: () => const {},
            )['name'] as String? ?? '1 course')
        : '${_courseIds.length} courses';

    return Material(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
      child: InkWell(
        onTap: _editScope,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.calendar_today_outlined,
                  size: 15, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '$yearName  ·  $courseLabel',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _editScope,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Change', style: TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    minimumSize: const Size(0, 32)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Students tab ─────────────────────────────────────────────────────────────

class _StudentsTab extends StatefulWidget {
  final String? dueFilter;
  final String? yearId;
  final List<String> courseIds;
  final int reloadTrigger;
  final VoidCallback onPaymentMade;

  const _StudentsTab({
    this.dueFilter,
    this.yearId,
    this.courseIds = const [],
    required this.reloadTrigger,
    required this.onPaymentMade,
  });

  @override
  State<_StudentsTab> createState() => _StudentsTabState();
}

class _StudentsTabState extends State<_StudentsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<Map<String, dynamic>> _students = [];
  bool    _loading = false;
  String? _error;
  final _searchCtrl = TextEditingController();
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_StudentsTab old) {
    super.didUpdateWidget(old);
    if (old.dueFilter != widget.dueFilter ||
        old.reloadTrigger != widget.reloadTrigger ||
        old.yearId != widget.yearId ||
        !listEquals(old.courseIds, widget.courseIds)) {
      _load();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.getFeesStudentSummary(
        dueFilter:      widget.dueFilter,
        academicYearId: widget.yearId,
        courseIds:      widget.courseIds,
      );
      if (!mounted) return;
      setState(() {
        _students = (data['students'] as List? ?? []).cast<Map<String, dynamic>>();
        _loading  = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error   = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_q.isEmpty) return _students;
    final q = _q.toLowerCase();
    return _students.where((s) {
      final name   = '${s['first_name'] ?? ''} ${s['last_name'] ?? ''}'.toLowerCase();
      final mobile = (s['mobile'] as String? ?? '').toLowerCase();
      return name.contains(q) || mobile.contains(q);
    }).toList();
  }

  void _openCollect(Map<String, dynamic> student) {
    final records = (student['pending_records'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    if (records.isEmpty) return;
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => FeeCollectionSheet(
        studentId:      student['student_id'] as String,
        studentName:    '${student['first_name'] ?? ''} ${student['last_name'] ?? ''}'.trim(),
        mobile:         student['mobile'] as String? ?? '',
        pendingRecords: records,
      ),
    ).then((ok) { if (ok == true) widget.onPaymentMade(); });
  }

  void _openHistory(Map<String, dynamic> student) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StudentFeeDetailScreen(
          studentId:   student['student_id'] as String,
          studentName: '${student['first_name'] ?? ''} ${student['last_name'] ?? ''}'.trim(),
          mobile:      student['mobile'] as String? ?? '',
        ),
      ),
    ).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);

    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 56, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              hintText: 'Search by student name or mobile',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _q.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () { _searchCtrl.clear(); setState(() => _q = ''); })
                  : null,
              isDense: true,
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerLow,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
          ),
        ),
        Expanded(
          child: _filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 56,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.25)),
                      const SizedBox(height: 12),
                      Text(
                        _q.isEmpty
                            ? (widget.dueFilter == null
                                ? 'No pending fees'
                                : 'No fees match this filter')
                            : 'No students match "$_q"',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: _filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final s = _filtered[i];
                      return _StudentFeeCard(
                        student:     s,
                        onCollect:   () => _openCollect(s),
                        onHistory:   () => _openHistory(s),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

// ── Student fee card (for Students tab) ──────────────────────────────────────

class _StudentFeeCard extends StatelessWidget {
  final Map<String, dynamic> student;
  final VoidCallback onCollect;
  final VoidCallback onHistory;

  const _StudentFeeCard({
    required this.student,
    required this.onCollect,
    required this.onHistory,
  });

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final name    = '${student['first_name'] ?? ''} ${student['last_name'] ?? ''}'.trim();
    final mobile  = student['mobile'] as String? ?? '';
    final balance = double.tryParse(student['balance']?.toString() ?? '') ?? 0.0;
    final count   = int.tryParse(student['pending_count']?.toString() ?? '') ?? 0;

    final initials = name
        .split(' ')
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0].toUpperCase())
        .join();

    // Build compact "Course (Subjects)" summary, one entry per course.
    final records = (student['pending_records'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final coursesMap = <String, String?>{};
    for (final r in records) {
      final cName = (r['course_name'] as String?) ?? 'Course';
      coursesMap[cName] = subjectNamesOf(r) ?? coursesMap[cName];
    }
    final subjectSummary = coursesMap.entries
        .map((e) => courseWithSubjects(e.key, e.value))
        .join(' · ');

    // Next due date + overdue detection
    final today = DateTime.now();
    final today0 = DateTime(today.year, today.month, today.day);
    DateTime? nextDue;
    bool hasOverdue = false;
    for (final r in records) {
      final raw = r['due_date']?.toString() ?? '';
      if (raw.isEmpty) continue;
      try {
        final d = DateTime.parse(raw.length > 10 ? raw : '${raw}T00:00:00');
        final d0 = DateTime(d.year, d.month, d.day);
        if (d0.isBefore(today0)) hasOverdue = true;
        if (nextDue == null || d0.isBefore(nextDue)) nextDue = d0;
      } catch (_) {}
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
                  child: Text(
                    initials.isEmpty ? '?' : initials,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name.isEmpty ? 'Unnamed' : name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (mobile.isNotEmpty)
                        Text(mobile,
                            style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.6))),
                      if (subjectSummary.isNotEmpty)
                        Text(
                          subjectSummary,
                          style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.8)),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '₹${balance.toStringAsFixed(0)}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Colors.orange),
                    ),
                    Text(
                      '$count pending',
                      style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Due date row
            if (nextDue != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: hasOverdue
                      ? Colors.red.withValues(alpha: 0.08)
                      : Colors.orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(
                      hasOverdue ? Icons.warning_amber_rounded : Icons.schedule_outlined,
                      size: 13,
                      color: hasOverdue ? Colors.red.shade700 : Colors.orange.shade700,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      hasOverdue
                          ? 'Overdue since ${_fmtDate(nextDue)}'
                          : 'Next due: ${_fmtDate(nextDue)}',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: hasOverdue
                              ? Colors.red.shade700
                              : Colors.orange.shade700),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: FilledButton.icon(
                    onPressed: onCollect,
                    icon: const Icon(Icons.payments_outlined, size: 16),
                    label: Text('Collect  ₹${balance.toStringAsFixed(0)}'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: OutlinedButton.icon(
                    onPressed: onHistory,
                    icon: const Icon(Icons.history, size: 16),
                    label: const Text('History'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 40)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtDate(DateTime d) {
    const m = ['', 'Jan','Feb','Mar','Apr','May','Jun',
                    'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${m[d.month]} ${d.year}';
  }
}

// ── Receipts admin tab ────────────────────────────────────────────────────────

class _ReceiptsTab extends StatefulWidget {
  final String? yearId;
  final List<String> courseIds;
  final int reloadTrigger;

  const _ReceiptsTab({
    this.yearId,
    this.courseIds = const [],
    this.reloadTrigger = 0,
  });

  @override
  State<_ReceiptsTab> createState() => _ReceiptsTabState();
}

class _ReceiptsTabState extends State<_ReceiptsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<Map<String, dynamic>> _receipts = [];
  bool    _loading = true;
  String? _error;
  final _searchCtrl = TextEditingController();
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ReceiptsTab old) {
    super.didUpdateWidget(old);
    if (old.reloadTrigger != widget.reloadTrigger ||
        old.yearId != widget.yearId ||
        !listEquals(old.courseIds, widget.courseIds)) {
      _load();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.listReceipts(
        limit:          200,
        academicYearId: widget.yearId,
        courseIds:      widget.courseIds,
      );
      if (!mounted) return;
      setState(() {
        _receipts = (data['receipts'] as List? ?? []).cast<Map<String, dynamic>>();
        _loading  = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error   = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_q.isEmpty) return _receipts;
    final q = _q.toLowerCase();
    return _receipts.where((r) {
      final num     = (r['receipt_number'] as String? ?? '').toLowerCase();
      final name    = '${r['first_name'] ?? ''} ${r['last_name'] ?? ''}'.toLowerCase();
      final mobile  = (r['mobile']        as String? ?? '').toLowerCase();
      final course  = (r['course_name']   as String? ?? '').toLowerCase();
      final subs    = (r['subject_names'] as String? ?? '').toLowerCase();
      return num.contains(q) || name.contains(q) ||
             mobile.contains(q) || course.contains(q) || subs.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);

    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry')),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              hintText: 'Search by receipt number or student name',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _q.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () { _searchCtrl.clear(); setState(() => _q = ''); })
                  : null,
              isDense: true,
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerLow,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
          ),
        ),
        Expanded(
          child: _filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.receipt_long_outlined, size: 56,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.25)),
                      const SizedBox(height: 12),
                      Text(_q.isEmpty ? 'No receipts yet' : 'No receipts match "$_q"',
                          style: theme.textTheme.bodyMedium),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                    itemCount: _filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _ReceiptAdminCard(receipt: _filtered[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ReceiptAdminCard extends StatefulWidget {
  final Map<String, dynamic> receipt;
  const _ReceiptAdminCard({required this.receipt});

  @override
  State<_ReceiptAdminCard> createState() => _ReceiptAdminCardState();
}

class _ReceiptAdminCardState extends State<_ReceiptAdminCard> {
  bool _resending     = false;
  bool _generatingPdf = false;

  Future<void> _downloadPdf() async {
    if (_generatingPdf) return;
    final id = widget.receipt['id'] as String?;
    if (id == null || id.isEmpty) return;
    setState(() => _generatingPdf = true);
    try {
      final detail     = await AcademyApiService.getReceipt(id);
      if (!mounted) return;
      final academyName =
          context.read<AuthProvider>().academyUser?.academyName ?? 'Academy';
      await FeePdfService.generateReceiptPdf(
          context: context, academyName: academyName, receipt: detail);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _generatingPdf = false);
    }
  }

  Future<void> _resend() async {
    if (_resending) return;
    final id = widget.receipt['id'] as String?;
    if (id == null || id.isEmpty) return;
    setState(() => _resending = true);
    try {
      final res  = await AcademyApiService.resendReceipt(id);
      if (mounted) {
        final sent = res['sent'] as bool? ?? false;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(sent
              ? 'Notification sent to parent'
              : 'Could not send — no device registered'),
          backgroundColor: sent ? Colors.green : Colors.orange,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme        = Theme.of(context);
    final r            = widget.receipt;
    final name         = '${r['first_name'] ?? ''} ${r['last_name'] ?? ''}'.trim();
    final amount       = double.tryParse(r['amount_paid']?.toString() ?? '') ?? 0.0;
    final date         = _fmtDate(r['generated_at']);
    final rcptNo       = r['receipt_number'] as String? ?? '—';
    final course       = r['course_name']   as String? ?? '';
    final subjectNames = r['subject_names'] as String?;
    final fcmSent      = r['fcm_sent'] as bool? ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rcptNo,
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                              fontSize: 13)),
                      const SizedBox(height: 2),
                      Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (course.isNotEmpty)
                        Text(courseWithSubjects(course, subjectNames),
                            style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.6)),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('₹${amount.toStringAsFixed(0)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Colors.green)),
                    Text(date,
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                    if (fcmSent)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.notifications_active_outlined,
                              size: 12, color: Colors.green),
                          const SizedBox(width: 3),
                          Text('Notified',
                              style: TextStyle(fontSize: 10, color: Colors.green.shade700)),
                        ],
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _generatingPdf ? null : _downloadPdf,
                    icon: _generatingPdf
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.picture_as_pdf_outlined, size: 16),
                    label: Text(_generatingPdf ? 'Generating...' : 'PDF',
                        style: const TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _resending ? null : _resend,
                    icon: _resending
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_outlined, size: 16),
                    label: Text(_resending ? 'Sending...' : 'Resend',
                        style: const TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Fee list (status tabs) ────────────────────────────────────────────────────

class _FeeList extends StatelessWidget {
  final List<Map<String, dynamic>> records;
  final bool loading;
  final Future<void> Function(Map<String, dynamic>) onCollect;

  const _FeeList(
      {required this.records,
      required this.loading,
      required this.onCollect});

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (records.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_balance_wallet_outlined,
                size: 56,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            const Text('No fee records'),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: records.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _FeeCard(
          record: records[i], onCollect: () => onCollect(records[i])),
    );
  }
}

// ── Fee card (status tabs — course-level) ─────────────────────────────────────

class _FeeCard extends StatelessWidget {
  final Map<String, dynamic> record;
  final VoidCallback onCollect;
  const _FeeCard({required this.record, required this.onCollect});

  @override
  Widget build(BuildContext context) {
    final theme        = Theme.of(context);
    final status       = (record['status'] as String?) ?? 'pending';
    final due          = double.tryParse(record['amount_due']?.toString()  ?? '') ?? 0.0;
    final paid         = double.tryParse(record['amount_paid']?.toString() ?? '') ?? 0.0;
    final balance      = double.tryParse(record['balance']?.toString()     ?? '')
        ?? (due - paid).clamp(0.0, double.infinity);
    final isPaid       = status == 'paid';
    final color        = _statusColor(status);
    final courseName   = record['course_name']  as String? ?? 'Course';
    final subjectNames = record['subject_names'] as String?;
    final mobile       = record['mobile'] as String? ?? '';
    final dueDate      = _fmtDate(record['due_date']);

    final studentName =
        '${record['first_name'] ?? ''} ${record['last_name'] ?? ''}'.trim();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header row ───────────────────────────────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(studentName.isEmpty ? 'Unnamed' : studentName,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      if (mobile.isNotEmpty)
                        Text(mobile,
                            style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.6))),
                    ],
                  ),
                ),
                _StatusBadge(status: status, color: color),
              ],
            ),
            const SizedBox(height: 8),

            // ── Course + subjects ────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.menu_book_outlined,
                          size: 13, color: theme.colorScheme.primary),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(courseWithSubjects(courseName, subjectNames),
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.primary),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // ── Progress bar ─────────────────────────────────────────────────
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: due > 0 ? (paid / due).clamp(0.0, 1.0) : 0,
                color: isPaid ? Colors.green : color,
                backgroundColor: Colors.grey.shade200,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 10),

            // ── Fee breakdown ────────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: _feeCell('Course Fee', '₹${due.toStringAsFixed(0)}',
                      theme.colorScheme.onSurface),
                ),
                Expanded(
                  child: _feeCell('Paid', '₹${paid.toStringAsFixed(0)}',
                      Colors.green),
                ),
                Expanded(
                  child: _feeCell(
                    'Balance',
                    '₹${balance.toStringAsFixed(0)}',
                    balance > 0 ? color : Colors.green,
                    bold: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('Due by $dueDate',
                style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
            const SizedBox(height: 10),

            // ── Action ───────────────────────────────────────────────────────
            if (isPaid)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.check_circle, color: Colors.green, size: 22),
                  SizedBox(width: 6),
                  Text('Fully Paid',
                      style: TextStyle(
                          color: Colors.green, fontWeight: FontWeight.w600)),
                ],
              )
            else
              FilledButton.tonal(
                onPressed: onCollect,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(40)),
                child: Text('Collect  ₹${balance.toStringAsFixed(0)}'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _feeCell(String label, String value, Color valueColor,
      {bool bold = false}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
          Text(value,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: bold ? FontWeight.bold : FontWeight.w600,
                  color: valueColor)),
        ],
      );

  Color _statusColor(String s) {
    switch (s) {
      case 'paid':    return Colors.green;
      case 'overdue': return Colors.red;
      case 'partial': return Colors.blue;
      default:        return Colors.orange;
    }
  }
}

// ── Status badge ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  final Color color;
  const _StatusBadge({required this.status, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          status.toUpperCase(),
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
        ),
      );
}

// ── Summary chip ──────────────────────────────────────────────────────────────

class _SummaryChip extends StatelessWidget {
  final String label, value;
  final Color color;
  const _SummaryChip({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: color)),
            const SizedBox(width: 4),
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 12, color: color)),
          ],
        ),
      );
}

// ── Fee collection sheet (multi-subject) ─────────────────────────────────────

class FeeCollectionSheet extends StatefulWidget {
  final String studentId;
  final String studentName;
  final String mobile;
  final List<Map<String, dynamic>> pendingRecords;

  const FeeCollectionSheet({
    super.key,
    required this.studentId,
    required this.studentName,
    required this.mobile,
    required this.pendingRecords,
  });

  @override
  State<FeeCollectionSheet> createState() => _FeeCollectionSheetState();
}

class _FeeCollectionSheetState extends State<FeeCollectionSheet> {
  final _installmentCtrl = TextEditingController();
  String _paymentMode    = 'cash';
  final _remarksCtrl     = TextEditingController();
  bool    _saving        = false;
  String? _receiptNumber;
  String? _receiptId;

  @override
  void dispose() {
    _installmentCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  double get _totalOutstanding => widget.pendingRecords.fold(
      0.0, (s, r) => s + (double.tryParse(r['balance']?.toString() ?? '') ?? 0.0));

  double get _installmentAmount =>
      double.tryParse(_installmentCtrl.text.trim()) ?? 0.0;

  bool get _isValid =>
      _installmentAmount > 0 && _installmentAmount <= _totalOutstanding + 0.01;

  Map<String, List<Map<String, dynamic>>> get _byCourse {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final r in widget.pendingRecords) {
      final key = (r['course_name'] as String?) ?? 'Course';
      map.putIfAbsent(key, () => []).add(r);
    }
    return map;
  }

  Future<void> _collect() async {
    final installment = _installmentAmount;
    if (installment <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid installment amount')));
      return;
    }
    if (installment > _totalOutstanding + 0.01) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Amount exceeds outstanding balance')));
      return;
    }

    // Distribute installment sequentially by due_date (oldest first)
    final sorted = [...widget.pendingRecords]
      ..sort((a, b) => (a['due_date']?.toString() ?? '')
          .compareTo(b['due_date']?.toString() ?? ''));

    final items = <Map<String, dynamic>>[];
    double remaining = installment;
    for (final r in sorted) {
      final balance = double.tryParse(r['balance']?.toString() ?? '') ?? 0.0;
      if (balance <= 0 || remaining <= 0) continue;
      final payment = remaining < balance ? remaining : balance;
      items.add({'fee_record_id': r['id'] as String, 'amount_paid': payment});
      remaining -= payment;
      if (remaining < 0.01) break;
    }

    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No records to collect')));
      return;
    }

    setState(() => _saving = true);
    try {
      final result = await AcademyApiService.collectFeeBulk(
        studentId:   widget.studentId,
        items:       items,
        paymentMode: _paymentMode,
        remarks:     _remarksCtrl.text.trim().isNotEmpty
            ? _remarksCtrl.text.trim()
            : null,
      );
      if (mounted) {
        final data = result['data'] as Map<String, dynamic>? ?? result;
        setState(() {
          _receiptNumber = data['receipt_number'] as String?;
          _receiptId     = data['receipt_id']     as String?;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _downloadReceipt() async {
    final id = _receiptId;
    if (id == null || id.isEmpty) return;
    try {
      final detail      = await AcademyApiService.getReceipt(id);
      if (!mounted) return;
      final academyName = context.read<AuthProvider>().academyUser?.academyName ?? 'Academy';
      await FeePdfService.generateReceiptPdf(
          context: context, academyName: academyName, receipt: detail);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mq    = MediaQuery.of(context);

    // ── Success state ─────────────────────────────────────────────────────────
    if (_receiptNumber != null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 24),
              const Icon(Icons.check_circle, color: Colors.green, size: 64),
              const SizedBox(height: 16),
              Text('Payment Recorded',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.receipt_long_outlined,
                        color: theme.colorScheme.primary, size: 18),
                    const SizedBox(width: 8),
                    Text(_receiptNumber!,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: theme.colorScheme.primary)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(widget.studentName,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 4),
              Text('A notification has been sent to the parent.',
                  style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _downloadReceipt,
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('Download Receipt'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // ── Input form ────────────────────────────────────────────────────────────
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          24, 16, 24,
          mq.viewInsets.bottom + mq.padding.bottom + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Collect Fees',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              Text(widget.studentName,
                  style: TextStyle(
                      fontSize: 14,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7))),
              if (widget.mobile.isNotEmpty)
                Text(widget.mobile,
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.55))),
            ],
          ),
          const SizedBox(height: 16),

          // Course info cards (read-only)
          ..._byCourse.entries.map((entry) => _CourseInfoCard(
                courseName: entry.key,
                records:    entry.value,
              )),

          // Outstanding balance summary
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Outstanding Course Balance',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.8))),
                Text('₹${_totalOutstanding.toStringAsFixed(0)}',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.error)),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Installment amount input
          TextFormField(
            controller: _installmentCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Installment Amount *',
              border: const OutlineInputBorder(),
              prefixText: '₹ ',
              helperText: 'Max ₹${_totalOutstanding.toStringAsFixed(0)}',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),

          // Payment mode
          DropdownButtonFormField<String>(
            value: _paymentMode,
            decoration: const InputDecoration(
                labelText: 'Payment Mode', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'cash',          child: Text('Cash')),
              DropdownMenuItem(value: 'upi',           child: Text('UPI')),
              DropdownMenuItem(value: 'bank_transfer', child: Text('Bank Transfer')),
              DropdownMenuItem(value: 'cheque',        child: Text('Cheque')),
            ],
            onChanged: (v) { if (v != null) setState(() => _paymentMode = v); },
          ),
          const SizedBox(height: 12),

          TextFormField(
            controller: _remarksCtrl,
            decoration: const InputDecoration(
                labelText: 'Remarks (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),

          FilledButton.icon(
            onPressed: (_saving || !_isValid) ? null : _collect,
            icon: _saving
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.payments_outlined),
            label: Text(_saving
                ? 'Processing...'
                : 'Confirm Payment  ₹${_installmentAmount > 0 ? _installmentAmount.toStringAsFixed(0) : '0'}'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          ),
        ],
      ),
    );
  }
}

// ── Course info card in collection sheet (read-only) ─────────────────────────

class _CourseInfoCard extends StatelessWidget {
  final String courseName;
  final List<Map<String, dynamic>> records;

  const _CourseInfoCard({required this.courseName, required this.records});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    double totalDue  = 0;
    double totalPaid = 0;
    final breakdown = <String, num>{}; // subject name → locked fee
    String? subjectNames;

    for (final r in records) {
      totalDue  += double.tryParse(r['amount_due']?.toString()  ?? '') ?? 0.0;
      totalPaid += double.tryParse(r['amount_paid']?.toString() ?? '') ?? 0.0;
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

    final outstanding = totalDue - totalPaid;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(Icons.menu_book_outlined,
                  size: 15, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(courseWithSubjects(courseName, subjectNames),
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: theme.colorScheme.primary)),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              _statRow(theme, 'Total Course Fee',
                  '₹${totalDue.toStringAsFixed(0)}'),
              if (breakdown.isNotEmpty) ...[
                const SizedBox(height: 6),
                // Per-subject fee breakdown (e.g. Math ₹3,000 · Physics ₹5,000)
                ...breakdown.entries.map((e) => Padding(
                      padding: const EdgeInsets.only(left: 12, bottom: 4),
                      child: _statRow(theme, e.key,
                          '₹${e.value.toStringAsFixed(0)}', muted: true),
                    )),
              ],
              const SizedBox(height: 6),
              _statRow(theme, 'Paid Till Date',
                  '₹${totalPaid.toStringAsFixed(0)}', muted: true),
              const SizedBox(height: 6),
              _statRow(theme, 'Outstanding Balance',
                  '₹${outstanding.toStringAsFixed(0)}',
                  bold: true, color: theme.colorScheme.error),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _statRow(ThemeData theme, String label, String value,
      {bool bold = false, bool muted = false, Color? color}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 12,
                color: muted
                    ? theme.colorScheme.onSurface.withValues(alpha: 0.55)
                    : theme.colorScheme.onSurface.withValues(alpha: 0.75))),
        Text(value,
            style: TextStyle(
                fontSize: 13,
                fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                color: color ??
                    (muted
                        ? theme.colorScheme.onSurface.withValues(alpha: 0.55)
                        : theme.colorScheme.onSurface))),
      ],
    );
  }
}

class _Tab {
  final String label;
  final String? status;
  const _Tab(this.label, this.status);
}

// ── Export Excel tab ──────────────────────────────────────────────────────────

class _ExportExcelTab extends StatefulWidget {
  final String? yearId;
  final List<String> courseIds;
  final String yearName;
  final int courseCount;

  const _ExportExcelTab({
    required this.yearId,
    required this.courseIds,
    required this.yearName,
    required this.courseCount,
  });

  @override
  State<_ExportExcelTab> createState() => _ExportExcelTabState();
}

class _ExportExcelTabState extends State<_ExportExcelTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _generating = false;

  Future<void> _download() async {
    if (_generating) return;
    final yearId = widget.yearId;
    if (yearId == null || widget.courseIds.isEmpty) return;
    setState(() => _generating = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final data = await AcademyApiService.getFeesExportData(
        academicYearId: yearId,
        courseIds:      widget.courseIds,
      );
      final students = (data['students'] as List? ?? []);
      if (students.isEmpty) {
        if (mounted) {
          messenger.showSnackBar(const SnackBar(
            content: Text('No students found for the selected year and course(s).'),
            backgroundColor: Colors.orange,
          ));
        }
        return;
      }
      final path = await FeeExcelService.generate(data);
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text('Exported ${students.length} students • ${path.split(RegExp(r'[\\/]')).last}'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final courseLabel = widget.courseCount == 1
        ? '1 course'
        : '${widget.courseCount} courses';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.table_view_outlined,
                size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Export Fee Collection',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'Download an installment-wise (month-by-month) fee collection '
              'ledger for the selected scope.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
            ),
            const SizedBox(height: 20),

            // Active scope summary
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                children: [
                  _scopeRow(theme, Icons.calendar_today_outlined,
                      'Academic Year', widget.yearName.isEmpty ? '—' : widget.yearName),
                  const SizedBox(height: 8),
                  _scopeRow(theme, Icons.menu_book_outlined, 'Courses', courseLabel),
                ],
              ),
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _generating ? null : _download,
                icon: _generating
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.download_outlined),
                label: Text(_generating ? 'Generating…' : 'Download Excel'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52)),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Includes monthly installments, per-student totals, and a grand '
              'total row. Exported as .xlsx.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scopeRow(ThemeData theme, IconData icon, String label, String value) =>
      Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7))),
          const Spacer(),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      );
}

// ── Shared helpers ────────────────────────────────────────────────────────────

String _fmtDate(dynamic raw) => du.fmtDate(raw?.toString());
