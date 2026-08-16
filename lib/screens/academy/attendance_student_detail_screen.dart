import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';
import 'attendance_hub_screen.dart' show bandColor, riskColor;

/// Single-student attendance report (admin/teacher).
///
/// Every figure on this screen is labelled with what it measures and which
/// period it covers, because the previous version showed bare numbers — a "38"
/// with no unit, counts with no denominator, and no indication of the date range
/// they were drawn from.
///
/// Layout, top to bottom:
///   1. Who      — name, student ID, course, academic year
///   2. When     — period selector + the exact dates being shown
///   3. Summary  — working days / present / absent / late, and attendance %
///   4. Metrics  — Attendance, Punctuality, Regularity, each with its own meaning
///   5. Trend    — weekly or daily series, so direction of travel is visible
///   6. Risk + patterns, and the existing "Nudge parent" action
class AttendanceStudentDetailScreen extends StatefulWidget {
  final String studentId;
  final String studentName;
  const AttendanceStudentDetailScreen({
    super.key,
    required this.studentId,
    required this.studentName,
  });

  @override
  State<AttendanceStudentDetailScreen> createState() =>
      _AttendanceStudentDetailScreenState();
}

/// How the reporting period is being chosen.
enum _PeriodMode { month, rolling, custom }

class _AttendanceStudentDetailScreenState
    extends State<AttendanceStudentDetailScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _data;
  bool _nudging = false;

  // Period selection. Defaults to the current month so the admin always starts
  // on a period they can name, rather than an unlabelled rolling window.
  _PeriodMode _mode = _PeriodMode.month;
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  int _rollingDays = 56;
  DateTimeRange? _customRange;

  // Trend granularity.
  bool _weeklyTrend = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ── Period plumbing ────────────────────────────────────────────────────────

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Resolved (from, to) for the current selection, or null for the rolling
  /// window — which the server derives itself from `window`.
  ({String from, String to})? get _range {
    switch (_mode) {
      case _PeriodMode.month:
        final first = DateTime(_month.year, _month.month, 1);
        final last = DateTime(_month.year, _month.month + 1, 0);
        return (from: _ymd(first), to: _ymd(last));
      case _PeriodMode.custom:
        final r = _customRange;
        if (r == null) return null;
        return (from: _ymd(r.start), to: _ymd(r.end));
      case _PeriodMode.rolling:
        return null;
    }
  }

  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _month.year == now.year && _month.month == now.month;
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final r = _range;
      final data = await AcademyApiService.getStudentInsight(
        widget.studentId,
        windowDays: _rollingDays,
        fromDate: r?.from,
        toDate: r?.to,
      );
      if (!mounted) return;
      setState(() { _data = data; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  void _shiftMonth(int delta) {
    setState(() {
      _mode = _PeriodMode.month;
      _month = DateTime(_month.year, _month.month + delta);
    });
    _load();
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _customRange ??
          DateTimeRange(start: now.subtract(const Duration(days: 29)), end: now),
      helpText: 'Select report period',
    );
    if (picked == null || !mounted) return;
    setState(() { _mode = _PeriodMode.custom; _customRange = picked; });
    _load();
  }

  // ── Nudge (existing action, unchanged) ─────────────────────────────────────

  Future<void> _nudge() async {
    if (_nudging) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nudge parent?'),
        content: Text(
            'Send an attendance reminder push to ${widget.studentName}\'s parent?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Send')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _nudging = true);
    try {
      final msg = await AcademyApiService.nudgeParent(widget.studentId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.green.shade700),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _nudging = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.studentName.isEmpty ? 'Attendance Report' : widget.studentName),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: (_data != null)
          ? FloatingActionButton.extended(
              onPressed: _nudging ? null : _nudge,
              icon: _nudging
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.notifications_active_outlined),
              label: const Text('Nudge parent'),
            )
          : null,
      body: _error != null
          ? _errorView()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                _identityCard(),
                const SizedBox(height: 14),
                _periodCard(),
                const SizedBox(height: 14),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 60),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else
                  ..._report(),
              ],
            ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off_outlined, size: 48,
                color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: _load,
                icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ]),
        ),
      );

  List<Widget> _report() {
    final d = _data;
    if (d == null) return const [];

    final score    = (d['score'] as Map?)?.cast<String, dynamic>() ?? {};
    final risk     = (d['risk'] as Map?)?.cast<String, dynamic>() ?? {};
    final counts   = (d['counts'] as Map?)?.cast<String, dynamic>() ?? {};
    final trend    = (d['trend'] as Map?)?.cast<String, dynamic>() ?? {};
    final patterns = ((d['patterns'] as List?) ?? []).cast<Map<String, dynamic>>();
    final factors  = ((score['factors'] as List?) ?? []).cast<Map<String, dynamic>>();
    final working  = (counts['working_days'] as num?)?.toInt() ?? 0;

    // No open days in the period means the academy was closed (or has no records
    // at all) — say that plainly instead of rendering a wall of zeroes.
    if (working == 0) {
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              Icon(Icons.event_busy_outlined, size: 40,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)),
              const SizedBox(height: 12),
              Text('No working days recorded in ${_periodLabel()}.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                'Attendance is only counted on days the academy was open. '
                'Try another month or a wider date range.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: Theme.of(context)
                    .colorScheme.onSurface.withValues(alpha: 0.6)),
              ),
            ]),
          ),
        ),
      ];
    }

    return [
      _summaryCard(score, counts),
      const SizedBox(height: 14),
      _metricsCard(factors),
      const SizedBox(height: 14),
      _trendCard(trend),
      const SizedBox(height: 14),
      _riskCard(risk),
      if (patterns.isNotEmpty) ...[
        const SizedBox(height: 14),
        _patternsCard(patterns),
      ],
    ];
  }

  String _periodLabel() {
    final p = (_data?['period'] as Map?)?.cast<String, dynamic>();
    return p?['label'] as String? ?? '—';
  }

  // ── 1. Who ─────────────────────────────────────────────────────────────────

  Widget _identityCard() {
    final theme = Theme.of(context);
    final d = _data;
    final name   = (d?['name'] as String?)?.trim();
    final course = (d?['course'] as String?)?.trim() ?? '';
    final year   = (d?['academic_year'] as String?)?.trim() ?? '';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              (name == null || name.isEmpty) ? widget.studentName : name,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            _kv('Student ID', widget.studentId),
            _kv('Course', course.isEmpty ? 'Not enrolled in any active course' : course),
            _kv('Academic Year', year.isEmpty ? 'Not assigned' : year),
          ],
        ),
      ),
    );
  }

  Widget _kv(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ── 2. When ────────────────────────────────────────────────────────────────

  Widget _periodCard() {
    final theme = Theme.of(context);
    final p = (_data?['period'] as Map?)?.cast<String, dynamic>();
    final from = p?['from'] as String? ?? '';
    final to   = p?['to'] as String? ?? '';

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.calendar_month_outlined, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Report period',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 10),

            // Month stepper — the primary way to move between periods.
            if (_mode == _PeriodMode.month)
              Row(
                children: [
                  IconButton(
                    onPressed: _loading ? null : () => _shiftMonth(-1),
                    icon: const Icon(Icons.chevron_left),
                    tooltip: 'Previous month',
                  ),
                  Expanded(
                    child: Text(
                      _loading ? '…' : _periodLabel(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    // Never step past the current month — there is no data there.
                    onPressed: (_loading || _isCurrentMonth) ? null : () => _shiftMonth(1),
                    icon: const Icon(Icons.chevron_right),
                    tooltip: 'Next month',
                  ),
                ],
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_loading ? '…' : _periodLabel(),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),

            // The exact dates, always spelled out, so no figure on this screen
            // is ever ambiguous about what it covers.
            if (from.isNotEmpty && to.isNotEmpty && !_loading)
              Text('$from  to  $to',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),

            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _periodChip('This month', _mode == _PeriodMode.month && _isCurrentMonth, () {
                  final now = DateTime.now();
                  setState(() {
                    _mode = _PeriodMode.month;
                    _month = DateTime(now.year, now.month);
                  });
                  _load();
                }),
                _periodChip('Last 30 days',
                    _mode == _PeriodMode.rolling && _rollingDays == 30, () {
                  setState(() { _mode = _PeriodMode.rolling; _rollingDays = 30; });
                  _load();
                }),
                _periodChip('Last 56 days',
                    _mode == _PeriodMode.rolling && _rollingDays == 56, () {
                  setState(() { _mode = _PeriodMode.rolling; _rollingDays = 56; });
                  _load();
                }),
                _periodChip('Custom range…', _mode == _PeriodMode.custom, _pickCustomRange),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _periodChip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: _loading ? null : (_) => onTap(),
      visualDensity: VisualDensity.compact,
    );
  }

  // ── 3. Summary ─────────────────────────────────────────────────────────────

  Widget _summaryCard(Map<String, dynamic> score, Map<String, dynamic> counts) {
    final theme   = Theme.of(context);
    final pct     = (score['attendancePct'] as num?)?.toDouble() ?? 0;
    final band    = score['band'] as String?;
    final working = (counts['working_days'] as num?)?.toInt() ?? 0;
    final present = (counts['present'] as num?)?.toInt() ?? 0;
    final late    = (counts['late'] as num?)?.toInt() ?? 0;
    final absent  = (counts['absent'] as num?)?.toInt() ?? 0;
    final onTimePct = (counts['on_time_pct'] as num?)?.toDouble() ?? 0;
    final attended  = present + late;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Attendance summary',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            Text(_periodLabel(),
                style: TextStyle(
                    fontSize: 11.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 14),

            // Headline: attendance % with its own denominator spelled out.
            Row(children: [
              SizedBox(
                width: 76, height: 76,
                child: Stack(alignment: Alignment.center, children: [
                  SizedBox(
                    width: 76, height: 76,
                    child: CircularProgressIndicator(
                      value: (pct / 100).clamp(0, 1),
                      strokeWidth: 8,
                      backgroundColor: bandColor(band).withValues(alpha: 0.15),
                      valueColor: AlwaysStoppedAnimation(bandColor(band)),
                    ),
                  ),
                  Text('${pct.toStringAsFixed(0)}%',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold,
                          color: bandColor(band))),
                ]),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Attendance percentage',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                    const SizedBox(height: 3),
                    Text('$attended of $working working days attended',
                        style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.7))),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: bandColor(band).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('Present + late count as attended',
                          style: TextStyle(fontSize: 10.5, color: bandColor(band),
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            ]),

            const Divider(height: 26),

            // Counts, each labelled with what it means.
            _summaryRow('Total working days', '$working',
                'Days the academy was open in this period', theme.colorScheme.onSurface),
            _summaryRow('Present days', '$present',
                'Arrived on time', Colors.green.shade700),
            _summaryRow('Late days', '$late',
                'Attended but marked late', Colors.orange.shade800),
            _summaryRow('Absent days', '$absent',
                'No attendance recorded on an open day', Colors.red.shade700),
            _summaryRow(
              'On-time rate',
              attended == 0 ? '—' : '${onTimePct.toStringAsFixed(0)}%',
              attended == 0
                  ? 'No attended days to measure'
                  : '$present of $attended attended days were on time',
              Colors.blue.shade700,
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(String label, String value, String help, Color color) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                Text(help,
                    style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(value,
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  // ── 4. Metrics ─────────────────────────────────────────────────────────────

  /// Plain-language meaning for each scored factor. The bare label alone ("Regularity
  /// & trend") did not tell an admin what the number was measuring.
  static const _factorHelp = <String, String>{
    'attendance':  'Share of working days the student attended',
    'punctuality': 'Share of attended days the student was on time',
    'regularity':  'Consistency — penalised by absence streaks and a falling recent trend',
  };

  Widget _metricsCard(List<Map<String, dynamic>> factors) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Performance metrics',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            Text('Each scored out of 100 for ${_periodLabel()}',
                style: TextStyle(
                    fontSize: 11.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 14),
            ...factors.map((f) {
              final key    = f['key'] as String? ?? '';
              final value  = (f['value'] as num?)?.toDouble() ?? 0;
              final weight = (f['weight'] as num?)?.toDouble() ?? 0;
              final color  = _metricColor(value);
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(f['label'] as String? ?? '',
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 13.5)),
                      ),
                      Text(value.toStringAsFixed(0),
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16, color: color)),
                      Text(' / 100',
                          style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
                    ]),
                    const SizedBox(height: 2),
                    Text(_factorHelp[key] ?? '',
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (value / 100).clamp(0, 1),
                        minHeight: 7,
                        backgroundColor: Colors.grey.withValues(alpha: 0.2),
                        valueColor: AlwaysStoppedAnimation(color),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'This period: ${f['detail'] ?? ''}  •  '
                      'counts for ${weight.toStringAsFixed(0)}% of the overall score',
                      style: TextStyle(
                          fontSize: 10.5,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.55)),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Color _metricColor(double v) {
    if (v >= 85) return Colors.green.shade700;
    if (v >= 70) return Colors.amber.shade800;
    if (v >= 50) return Colors.orange.shade800;
    return Colors.red.shade700;
  }

  // ── 5. Trend ───────────────────────────────────────────────────────────────

  Widget _trendCard(Map<String, dynamic> trend) {
    final theme  = Theme.of(context);
    final weekly = ((trend['weekly'] as List?) ?? []).cast<Map<String, dynamic>>();
    final daily  = ((trend['daily'] as List?) ?? []).cast<Map<String, dynamic>>();

    // Points to plot: weekly attendance %, or a daily 100/0 attended series.
    final points = _weeklyTrend
        ? weekly.map((w) => (w['pct'] as num?)?.toDouble() ?? 0).toList()
        : daily
            .map((d) => (d['status'] == 'present' || d['status'] == 'late') ? 100.0 : 0.0)
            .toList();

    final labels = _weeklyTrend
        ? weekly.map((w) => _shortDate(w['week_start'] as String? ?? '')).toList()
        : daily.map((d) => _shortDate(d['date'] as String? ?? '')).toList();

    // Direction of travel: compare the two halves of the plotted series.
    String direction = 'Not enough data to show a trend';
    Color dirColor = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    IconData dirIcon = Icons.remove;
    if (points.length >= 2) {
      final half = points.length ~/ 2;
      final first = points.sublist(0, half);
      final second = points.sublist(half);
      double avg(List<double> l) =>
          l.isEmpty ? 0.0 : l.reduce((a, b) => a + b) / l.length;
      final delta = avg(second) - avg(first);
      if (delta >= 5) {
        direction = 'Improving — up ${delta.abs().toStringAsFixed(0)} points across this period';
        dirColor = Colors.green.shade700;
        dirIcon = Icons.trending_up;
      } else if (delta <= -5) {
        direction = 'Declining — down ${delta.abs().toStringAsFixed(0)} points across this period';
        dirColor = Colors.red.shade700;
        dirIcon = Icons.trending_down;
      } else {
        direction = 'Stable — little change across this period';
        dirColor = Colors.blue.shade700;
        dirIcon = Icons.trending_flat;
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Attendance trend',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    Text(
                      _weeklyTrend
                          ? 'Attendance % per week — ${_periodLabel()}'
                          : 'Attended (100) vs absent (0) per day — ${_periodLabel()}',
                      style: TextStyle(
                          fontSize: 11.5,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 10),

            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Weekly')),
                ButtonSegment(value: false, label: Text('Daily')),
              ],
              selected: {_weeklyTrend},
              onSelectionChanged: (s) => setState(() => _weeklyTrend = s.first),
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
            ),
            const SizedBox(height: 14),

            if (points.length < 2)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text('Not enough days in this period to draw a trend.',
                      style: TextStyle(
                          fontSize: 12.5,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                ),
              )
            else
              SizedBox(
                height: 170,
                child: LineChart(
                  LineChartData(
                    minY: 0,
                    maxY: 100,
                    gridData: FlGridData(
                      show: true,
                      horizontalInterval: 25,
                      drawVerticalLine: false,
                      getDrawingHorizontalLine: (_) => FlLine(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
                        strokeWidth: 1,
                      ),
                    ),
                    titlesData: FlTitlesData(
                      rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          interval: 25,
                          reservedSize: 34,
                          getTitlesWidget: (v, _) => Text('${v.toInt()}%',
                              style: const TextStyle(fontSize: 9)),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 26,
                          interval: (points.length / 5).ceilToDouble().clamp(1, 999),
                          getTitlesWidget: (v, _) {
                            final i = v.toInt();
                            if (i < 0 || i >= labels.length) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(labels[i],
                                  style: const TextStyle(fontSize: 9)),
                            );
                          },
                        ),
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    lineTouchData: LineTouchData(
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipItems: (spots) => spots.map((s) {
                          final i = s.x.toInt();
                          final when = i >= 0 && i < labels.length ? labels[i] : '';
                          return LineTooltipItem(
                            _weeklyTrend
                                ? '$when\n${s.y.toStringAsFixed(0)}% attended'
                                : '$when\n${s.y >= 50 ? 'Attended' : 'Absent'}',
                            const TextStyle(
                                color: Colors.white, fontSize: 11,
                                fontWeight: FontWeight.w600),
                          );
                        }).toList(),
                      ),
                    ),
                    lineBarsData: [
                      LineChartBarData(
                        spots: [
                          for (var i = 0; i < points.length; i++)
                            FlSpot(i.toDouble(), points[i]),
                        ],
                        isCurved: _weeklyTrend,
                        barWidth: 2.5,
                        color: theme.colorScheme.primary,
                        dotData: FlDotData(show: points.length <= 20),
                        belowBarData: BarAreaData(
                          show: true,
                          color: theme.colorScheme.primary.withValues(alpha: 0.12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 10),
            Row(children: [
              Icon(dirIcon, size: 18, color: dirColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(direction,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600, color: dirColor)),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  /// 'YYYY-MM-DD' → 'DD MMM', for compact axis labels.
  static String _shortDate(String iso) {
    if (iso.length < 10) return iso;
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final mm = int.tryParse(iso.substring(5, 7)) ?? 1;
    return '${iso.substring(8, 10)} ${m[(mm - 1).clamp(0, 11)]}';
  }

  // ── 6. Risk + patterns ─────────────────────────────────────────────────────

  Widget _riskCard(Map<String, dynamic> risk) {
    final theme = Theme.of(context);
    final level = risk['level'] as String? ?? 'low';
    final factors = ((risk['factors'] as List?) ?? []).cast<String>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.warning_amber_outlined, color: riskColor(level), size: 20),
              const SizedBox(width: 8),
              Text('Risk level', style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: riskColor(level).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(level.toUpperCase(),
                    style: TextStyle(color: riskColor(level),
                        fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ]),
            Text('Why this student is flagged, for ${_periodLabel()}',
                style: TextStyle(
                    fontSize: 11.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 10),
            ...factors.map((f) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    const Icon(Icons.circle, size: 6),
                    const SizedBox(width: 8),
                    Expanded(child: Text(f, style: const TextStyle(fontSize: 13))),
                  ]),
                )),
          ],
        ),
      ),
    );
  }

  Widget _patternsCard(List<Map<String, dynamic>> patterns) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Patterns detected',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Text('Recurring behaviour found in ${_periodLabel()}',
                style: TextStyle(
                    fontSize: 11.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 10),
            ...patterns.map((p) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.label_important_outline,
                          size: 15, color: Colors.orange.shade800),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p['label'] as String? ?? '',
                                style: const TextStyle(
                                    fontSize: 12.5, fontWeight: FontWeight.w600)),
                            if ((p['detail'] as String?)?.isNotEmpty ?? false)
                              Text(p['detail'] as String,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.65))),
                          ],
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
