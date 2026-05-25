import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/attendance.dart';
import '../providers/attendance_provider.dart';
import '../widgets/offline_banner.dart';
import '../widgets/shimmer_loader.dart';

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  DateTimeRange? _dateRange;
  String? _classFilter;
  String? _divisionFilter;

  @override
  void initState() {
    super.initState();
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => context.read<AttendanceProvider>().fetchAttendance(date: today));
  }

  Future<void> _load() async {
    final att = context.read<AttendanceProvider>();
    if (_dateRange != null) {
      att.fetchAttendance(
        dateFrom: DateFormat('yyyy-MM-dd').format(_dateRange!.start),
        dateTo: DateFormat('yyyy-MM-dd').format(_dateRange!.end),
        classGrade: _classFilter,
        division: _divisionFilter,
      );
    } else {
      att.fetchAttendance(
        date: DateFormat('yyyy-MM-dd').format(DateTime.now()),
        classGrade: _classFilter,
        division: _divisionFilter,
      );
    }
  }

  Future<void> _bulkMarkAbsent() async {
    final date = _dateRange != null
        ? DateFormat('yyyy-MM-dd').format(_dateRange!.start)
        : DateFormat('yyyy-MM-dd').format(DateTime.now());

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Bulk Mark Absent'),
        content: Text(
            'Mark all unscanned students absent for $date${_classFilter != null ? ' (Class $_classFilter-${_divisionFilter ?? ''})' : ''}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Mark Absent')),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await context
          .read<AttendanceProvider>()
          .bulkMarkAbsent(date, classGrade: _classFilter, division: _divisionFilter);
      _load();
    }
  }

  void _editRecord(Attendance record) {
    String status = record.status;
    final remarksCtrl = TextEditingController(text: record.remarks ?? '');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocalState) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Edit Attendance',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: ['present', 'absent', 'late']
                    .map((s) => DropdownMenuItem(
                        value: s, child: Text(s[0].toUpperCase() + s.substring(1))))
                    .toList(),
                onChanged: (v) => setLocalState(() => status = v!),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: remarksCtrl,
                decoration: const InputDecoration(labelText: 'Remarks'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await context.read<AttendanceProvider>().updateAttendance(
                        record.id,
                        {'status': status, 'remarks': remarksCtrl.text.trim()},
                      );
                  _load();
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final att = context.watch<AttendanceProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance'),
        actions: [
          IconButton(
            icon: const Icon(Icons.date_range),
            onPressed: () async {
              final range = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2024),
                lastDate: DateTime.now(),
                initialDateRange: _dateRange,
              );
              if (range != null) {
                setState(() => _dateRange = range);
                _load();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          if (_dateRange != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  Icon(Icons.filter_alt, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    '${DateFormat('dd MMM').format(_dateRange!.start)} — ${DateFormat('dd MMM yyyy').format(_dateRange!.end)}',
                    style: TextStyle(color: theme.colorScheme.primary, fontSize: 13),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      setState(() => _dateRange = null);
                      _load();
                    },
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: att.loading && att.records.isEmpty
                ? const ShimmerLoader()
                : att.records.isEmpty
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.event_note_outlined,
                              size: 64,
                              color: theme.colorScheme.onSurface.withValues(alpha:0.3)),
                          const SizedBox(height: 12),
                          const Text('No attendance records found'),
                        ]),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: Column(
                          children: [
                            // Header
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: Row(
                                children: [
                                  Expanded(flex: 3, child: Text('Name', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: theme.colorScheme.onSurfaceVariant))),
                                  Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: theme.colorScheme.onSurfaceVariant), textAlign: TextAlign.center)),
                                  Expanded(child: Text('In', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: theme.colorScheme.onSurfaceVariant), textAlign: TextAlign.center)),
                                  Expanded(child: Text('Out', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: theme.colorScheme.onSurfaceVariant), textAlign: TextAlign.center)),
                                  const SizedBox(width: 60),
                                ],
                              ),
                            ),
                            Expanded(
                              child: ListView.separated(
                                itemCount: att.records.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (_, i) {
                                  final r = att.records[i];
                                  return InkWell(
                                    onTap: () => _editRecord(r),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 10),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            flex: 3,
                                            child: Text(
                                              r.studentFullName.isNotEmpty
                                                  ? r.studentFullName
                                                  : r.studentId,
                                              style: const TextStyle(fontSize: 13),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          Expanded(
                                            flex: 2,
                                            child: Text(r.date,
                                                style: const TextStyle(fontSize: 12),
                                                textAlign: TextAlign.center),
                                          ),
                                          Expanded(
                                            child: Text(r.timeIn ?? '-',
                                                style: const TextStyle(fontSize: 12),
                                                textAlign: TextAlign.center),
                                          ),
                                          Expanded(
                                            child: Text(r.timeOut ?? '-',
                                                style: const TextStyle(fontSize: 12),
                                                textAlign: TextAlign.center),
                                          ),
                                          _statusChip(r.status),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _bulkMarkAbsent,
        icon: const Icon(Icons.group_off),
        label: const Text('Bulk Absent'),
        backgroundColor: Colors.red,
      ),
    );
  }

  Widget _statusChip(String status) {
    Color color;
    switch (status) {
      case 'present': color = Colors.green;
      case 'late': color = Colors.orange;
      default: color = Colors.red;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha:0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        status.substring(0, 1).toUpperCase(),
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }
}
