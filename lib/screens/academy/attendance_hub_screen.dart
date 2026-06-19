import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';
import 'attendance_student_detail_screen.dart';

/// Attendance Intelligence hub (admin/teacher).
///
/// Reached from the "Attendance" Quick Action on the academy admin dashboard.
/// Three tabs over read-only insight endpoints:
///   • Today      — action list (who needs attention now)
///   • Students   — every student with a score band
///   • Defaulters — grouped/sorted by stage
class AttendanceHubScreen extends StatefulWidget {
  const AttendanceHubScreen({super.key});

  @override
  State<AttendanceHubScreen> createState() => _AttendanceHubScreenState();
}

class _AttendanceHubScreenState extends State<AttendanceHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

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
          tabs: const [
            Tab(text: 'Today'),
            Tab(text: 'Students'),
            Tab(text: 'Defaulters'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _TodayTab(),
          _StudentsTab(),
          _DefaultersTab(),
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
