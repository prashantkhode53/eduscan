import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';
import 'attendance_hub_screen.dart' show bandColor, riskColor;

/// Full attendance-score breakdown for a single student (admin/teacher).
///
/// Shows: weighted score + band, per-factor breakdown (Attendance 50 /
/// Punctuality 25 / Regularity 25), risk band (Low/Med/High) WITH its
/// contributing factors (never a %), detected patterns, and a manual
/// "Nudge parent" action (one fire-and-forget FCM via the server).
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

class _AttendanceStudentDetailScreenState
    extends State<AttendanceStudentDetailScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _data;
  bool _nudging = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.getStudentInsight(widget.studentId);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.studentName.isEmpty ? 'Student' : widget.studentName)),
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView()
              : _content(),
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

  Widget _content() {
    final d = _data!;
    final score = (d['score'] as Map?)?.cast<String, dynamic>() ?? {};
    final risk = (d['risk'] as Map?)?.cast<String, dynamic>() ?? {};
    final patterns = ((d['patterns'] as List?) ?? []).cast<Map<String, dynamic>>();
    final counts = (d['counts'] as Map?)?.cast<String, dynamic>() ?? {};
    final factors = ((score['factors'] as List?) ?? []).cast<Map<String, dynamic>>();
    final hasData = score['hasData'] == true;

    if (!hasData) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No attendance data in this window yet.',
              textAlign: TextAlign.center),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      children: [
        _scoreCard(score),
        const SizedBox(height: 16),
        _countsRow(counts),
        const SizedBox(height: 16),
        _riskCard(risk),
        const SizedBox(height: 16),
        _factorsCard(factors),
        if (patterns.isNotEmpty) ...[
          const SizedBox(height: 16),
          _patternsCard(patterns),
        ],
      ],
    );
  }

  Widget _scoreCard(Map<String, dynamic> score) {
    final value = (score['score'] as num?)?.toDouble() ?? 0;
    final band  = score['band'] as String?;
    final pct   = (score['attendancePct'] as num?)?.toDouble() ?? 0;
    return Card(
      color: bandColor(band).withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(children: [
          SizedBox(
            width: 84, height: 84,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox(
                width: 84, height: 84,
                child: CircularProgressIndicator(
                  value: (value / 100).clamp(0, 1),
                  strokeWidth: 8,
                  backgroundColor: bandColor(band).withValues(alpha: 0.15),
                  valueColor: AlwaysStoppedAnimation(bandColor(band)),
                ),
              ),
              Text(value.toStringAsFixed(0),
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold,
                      color: bandColor(band))),
            ]),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Attendance Score',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: bandColor(band),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text((band ?? '').toUpperCase(),
                      style: const TextStyle(color: Colors.white,
                          fontWeight: FontWeight.bold, fontSize: 12)),
                ),
                const SizedBox(height: 8),
                Text('${pct.toStringAsFixed(0)}% attendance',
                    style: TextStyle(color: Theme.of(context)
                        .colorScheme.onSurface.withValues(alpha: 0.7))),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _countsRow(Map<String, dynamic> c) {
    Widget stat(String label, dynamic v, Color color) => Expanded(
          child: Column(children: [
            Text('${v ?? 0}',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
            Text(label, style: const TextStyle(fontSize: 11)),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(children: [
          stat('Present', c['present'], Colors.green),
          stat('Late', c['late'], Colors.orange.shade800),
          stat('Absent', c['absent'], Colors.red),
        ]),
      ),
    );
  }

  Widget _riskCard(Map<String, dynamic> risk) {
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
              Text('Risk', style: Theme.of(context).textTheme.titleSmall
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

  Widget _factorsCard(List<Map<String, dynamic>> factors) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Score breakdown',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ...factors.map((f) {
              final value = (f['value'] as num?)?.toDouble() ?? 0;
              final weight = (f['weight'] as num?)?.toDouble() ?? 0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(child: Text(f['label'] as String? ?? '',
                          style: const TextStyle(fontWeight: FontWeight.w500))),
                      Text('${value.toStringAsFixed(0)} / 100',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ]),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (value / 100).clamp(0, 1),
                        minHeight: 6,
                        backgroundColor: Colors.grey.withValues(alpha: 0.2),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('Weight ${weight.toStringAsFixed(0)}%  •  ${f['detail'] ?? ''}',
                        style: TextStyle(fontSize: 11,
                            color: Theme.of(context).colorScheme.onSurface
                                .withValues(alpha: 0.6))),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _patternsCard(List<Map<String, dynamic>> patterns) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Patterns',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: patterns.map((p) => Chip(
                    label: Text(p['label'] as String? ?? '',
                        style: const TextStyle(fontSize: 12)),
                    backgroundColor: Colors.orange.withValues(alpha: 0.12),
                    side: BorderSide(color: Colors.orange.withValues(alpha: 0.4)),
                    visualDensity: VisualDensity.compact,
                  )).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
