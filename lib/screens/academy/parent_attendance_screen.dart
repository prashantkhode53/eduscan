import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/parent_auth_provider.dart';
import '../../services/parent_api_service.dart';
import '../../services/parent_attendance_excel_service.dart';
import '../../utils/date_utils.dart' as du;

/// Full, filterable attendance record for a parent's child, with Excel download.
///
/// Reached from the tappable "Last 30 Days" card on the parent dashboard.
/// Two filter modes:
///   • Month  — pick a calendar month (default = current month)
///   • Range  — pick a custom From–To span
class ParentAttendanceScreen extends StatefulWidget {
  const ParentAttendanceScreen({super.key});

  @override
  State<ParentAttendanceScreen> createState() => _ParentAttendanceScreenState();
}

enum _Mode { month, range }

class _ParentAttendanceScreenState extends State<ParentAttendanceScreen> {
  _Mode _mode = _Mode.month;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime? _from;
  DateTime? _to;

  bool _loading = true;
  bool _downloading = false;
  String? _error;
  List<Map<String, dynamic>> _records = [];

  static const _months = [
    'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ── Filter param + label ──────────────────────────────────────────────────

  String get _monthParam =>
      '${_month.year.toString().padLeft(4, '0')}-${_month.month.toString().padLeft(2, '0')}';

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String get _periodLabel {
    if (_mode == _Mode.month) return '${_months[_month.month - 1]} ${_month.year}';
    final f = _from != null ? du.fmtDate(_ymd(_from!)) : '?';
    final t = _to != null ? du.fmtDate(_ymd(_to!)) : 'Today';
    return '$f to $t';
  }

  // ── Data load ──────────────────────────────────────────────────────────────

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final List<Map<String, dynamic>> rows;
      if (_mode == _Mode.month) {
        rows = await ParentApiService.getAttendance(month: _monthParam);
      } else {
        rows = await ParentApiService.getAttendance(
          from: _from != null ? _ymd(_from!) : null,
          to: _to != null ? _ymd(_to!) : null,
        );
      }
      if (!mounted) return;
      setState(() { _records = rows; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  // ── Filter pickers ─────────────────────────────────────────────────────────

  Future<void> _pickMonth() async {
    final now = DateTime.now();
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (_) => _MonthPickerDialog(initial: _month, latest: now),
    );
    if (picked != null) {
      setState(() { _mode = _Mode.month; _month = picked; });
      _load();
    }
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      initialDateRange: (_from != null && _to != null)
          ? DateTimeRange(start: _from!, end: _to!)
          : DateTimeRange(start: now.subtract(const Duration(days: 30)), end: now),
    );
    if (picked != null) {
      setState(() { _mode = _Mode.range; _from = picked.start; _to = picked.end; });
      _load();
    }
  }

  // ── Download ───────────────────────────────────────────────────────────────

  Future<void> _download() async {
    if (_downloading) return;
    if (_records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No records to download for this period.')),
      );
      return;
    }
    setState(() => _downloading = true);
    try {
      final user = context.read<ParentAuthProvider>().user;
      await ParentAttendanceExcelService.generate(
        records: _records,
        childName: user?.studentFullName ?? 'Student',
        academyName: user?.academyName ?? '',
        periodLabel: _periodLabel,
      );
      // FileOpener opens the sheet; no extra snackbar needed on success.
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Download failed: ${e.toString().replaceFirst('Exception: ', '')}'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  // ── Summary ────────────────────────────────────────────────────────────────

  ({int present, int late, int absent, double pct}) get _summary {
    var present = 0, late = 0, absent = 0;
    for (final r in _records) {
      switch ((r['status'] as String? ?? '').toLowerCase()) {
        case 'present': present++; break;
        case 'late':    late++;    break;
        case 'absent':  absent++;  break;
      }
    }
    final attended = present + late;
    final marked = attended + absent;
    return (
      present: present,
      late: late,
      absent: absent,
      pct: marked > 0 ? attended / marked * 100 : 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Records'),
        actions: [
          IconButton(
            tooltip: 'Download Excel',
            onPressed: _downloading ? null : _download,
            icon: _downloading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          _filterBar(theme),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _errorView(theme)
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            _summaryCard(theme),
                            const SizedBox(height: 16),
                            _recordsCard(theme),
                          ],
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _downloading ? null : _download,
        icon: const Icon(Icons.table_view_outlined),
        label: const Text('Excel'),
      ),
    );
  }

  Widget _filterBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _pickMonth,
            icon: const Icon(Icons.calendar_month_outlined, size: 18),
            label: Text(
              _mode == _Mode.month ? _periodLabel : 'Month',
              overflow: TextOverflow.ellipsis,
            ),
            style: OutlinedButton.styleFrom(
              backgroundColor: _mode == _Mode.month
                  ? theme.colorScheme.primary.withValues(alpha: 0.1)
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _pickRange,
            icon: const Icon(Icons.date_range_outlined, size: 18),
            label: Text(
              _mode == _Mode.range ? _periodLabel : 'Date Range',
              overflow: TextOverflow.ellipsis,
            ),
            style: OutlinedButton.styleFrom(
              backgroundColor: _mode == _Mode.range
                  ? theme.colorScheme.primary.withValues(alpha: 0.1)
                  : null,
            ),
          ),
        ),
      ]),
    );
  }

  Widget _summaryCard(ThemeData theme) {
    final s = _summary;
    Widget stat(String label, int v, Color color) => Expanded(
          child: Column(children: [
            Text('$v', style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.bold, color: color)),
            Text(label, style: const TextStyle(fontSize: 12)),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(children: [
            Text(_periodLabel, style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _pctColor(s.pct).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('${s.pct.toStringAsFixed(0)}%',
                  style: TextStyle(fontWeight: FontWeight.bold, color: _pctColor(s.pct))),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            stat('Present', s.present, Colors.green),
            stat('Late', s.late, Colors.orange.shade800),
            stat('Absent', s.absent, Colors.red),
          ]),
        ]),
      ),
    );
  }

  Color _pctColor(double pct) {
    if (pct >= 85) return Colors.green;
    if (pct >= 70) return Colors.amber.shade700;
    if (pct >= 50) return Colors.orange.shade800;
    return Colors.red;
  }

  Widget _recordsCard(ThemeData theme) {
    if (_records.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Column(children: [
              Icon(Icons.event_note_outlined, size: 40,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
              const SizedBox(height: 8),
              Text('No records for this period',
                  style: TextStyle(color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.5))),
            ]),
          ),
        ),
      );
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('${_records.length} day(s)',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          const Divider(height: 1),
          ..._records.map((r) => _recordTile(r, theme)),
        ],
      ),
    );
  }

  Widget _recordTile(Map<String, dynamic> r, ThemeData theme) {
    final status = (r['status'] as String? ?? '').toLowerCase();
    final date = du.fmtDate(r['date']?.toString());
    final hasOut = r['time_out'] != null;

    Color color;
    IconData icon;
    switch (status) {
      case 'present': color = Colors.green;  icon = Icons.check_circle; break;
      case 'late':    color = Colors.orange; icon = Icons.watch_later_outlined; break;
      case 'absent':  color = Colors.red;    icon = Icons.cancel_outlined; break;
      default:        color = Colors.grey;   icon = Icons.help_outline;
    }

    return ListTile(
      dense: true,
      leading: Icon(icon, color: color, size: 22),
      title: Text('$date  ·  ${_dayLabel(r['date']?.toString())}',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      subtitle: Text(
        hasOut
            ? 'In: ${du.fmtTimeOfDay(r['time_in'] as String?)}  ·  '
                'Out: ${du.fmtTimeOfDay(r['time_out'] as String?)}  ·  ${_dur(r['duration_mins'])}'
            : (r['time_in'] != null
                ? 'In: ${du.fmtTimeOfDay(r['time_in'] as String?)}'
                : 'Absent'),
        style: TextStyle(fontSize: 11,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(status.toUpperCase(),
            style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color)),
      ),
    );
  }

  String _dur(dynamic mins) {
    final m = (mins as num?)?.toInt() ?? 0;
    if (m <= 0) return '-';
    final h = m ~/ 60;
    final r = m % 60;
    return h > 0 ? '${h}h ${r}m' : '${r}m';
  }

  String _dayLabel(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final d = DateTime.parse(dateStr);
      const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
      return days[d.weekday - 1];
    } catch (_) { return ''; }
  }

  Widget _errorView(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: _load,
                icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ]),
        ),
      );
}

// ── A minimal month/year picker (no extra package) ──────────────────────────────

class _MonthPickerDialog extends StatefulWidget {
  final DateTime initial;
  final DateTime latest;
  const _MonthPickerDialog({required this.initial, required this.latest});

  @override
  State<_MonthPickerDialog> createState() => _MonthPickerDialogState();
}

class _MonthPickerDialogState extends State<_MonthPickerDialog> {
  late int _year = widget.initial.year;
  static const _months = [
    'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
  ];

  bool _isFuture(int month) =>
      _year > widget.latest.year ||
      (_year == widget.latest.year && month > widget.latest.month);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(children: [
        IconButton(
          onPressed: _year > widget.latest.year - 3
              ? () => setState(() => _year--)
              : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(child: Text('$_year', textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.bold))),
        IconButton(
          onPressed: _year < widget.latest.year
              ? () => setState(() => _year++)
              : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ]),
      content: SizedBox(
        width: 300,
        child: GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          childAspectRatio: 2.2,
          children: List.generate(12, (i) {
            final month = i + 1;
            final disabled = _isFuture(month);
            final selected = month == widget.initial.month && _year == widget.initial.year;
            return Padding(
              padding: const EdgeInsets.all(4),
              child: OutlinedButton(
                onPressed: disabled
                    ? null
                    : () => Navigator.pop(context, DateTime(_year, month)),
                style: OutlinedButton.styleFrom(
                  backgroundColor: selected
                      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                      : null,
                ),
                child: Text(_months[i]),
              ),
            );
          }),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
      ],
    );
  }
}
