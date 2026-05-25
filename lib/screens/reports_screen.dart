import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/pdf_service.dart';
import '../widgets/offline_banner.dart';
import '../widgets/shimmer_loader.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  bool _loading = true;

  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _weeklyStats = [];
  List<Map<String, dynamic>> _studentReport = [];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        ApiService.getDashboardStats(),
        ApiService.getWeeklyStats(),
        ApiService.getStudentReportSummary(),
      ]);
      _summary = results[0] as Map<String, dynamic>;
      _weeklyStats = (results[1] as List).cast<Map<String, dynamic>>();
      _studentReport = (results[2] as List).cast<Map<String, dynamic>>();
    } catch (_) {}
    setState(() => _loading = false);
  }

  Future<void> _exportPdf() async {
    if (_summary == null) return;
    try {
      await PdfService.exportSummaryReport(
        summary: _summary!,
        weeklyStats: _weeklyStats,
        studentReport: _studentReport,
        generatedAt: DateTime.now(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Report exported'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: _exportPdf,
            tooltip: 'Export PDF',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'Students'),
          ],
        ),
      ),
      body: _loading
          ? const ShimmerLoader()
          : Column(
              children: [
                const OfflineBanner(),
                Expanded(
                  child: TabBarView(
                    controller: _tabCtrl,
                    children: [
                      _buildOverviewTab(theme),
                      _buildStudentsTab(theme),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildOverviewTab(ThemeData theme) {
    if (_summary == null) {
      return const Center(child: Text('No data available'));
    }

    final totalStudents = _summary!['total_students'] ?? 0;
    final presentToday = _summary!['present_today'] ?? 0;
    final absentToday = _summary!['absent_today'] ?? 0;
    final lateToday = _summary!['late_today'] ?? 0;
    final avgAttendance = (_summary!['avg_attendance_percent'] as num?)?.toDouble() ?? 0.0;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Summary chips
          Row(
            children: [
              _statCard('Total', totalStudents.toString(), Colors.blue, Icons.people, theme),
              const SizedBox(width: 12),
              _statCard('Present', presentToday.toString(), Colors.green, Icons.check_circle, theme),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _statCard('Absent', absentToday.toString(), Colors.red, Icons.cancel, theme),
              const SizedBox(width: 12),
              _statCard('Late', lateToday.toString(), Colors.orange, Icons.access_time, theme),
            ],
          ),
          const SizedBox(height: 16),

          // Attendance rate
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Today\'s Attendance Rate',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: totalStudents > 0
                                ? presentToday / totalStudents
                                : 0,
                            minHeight: 12,
                            backgroundColor:
                                theme.colorScheme.surfaceContainerHighest,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              avgAttendance >= 75 ? Colors.green : Colors.orange,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${avgAttendance.toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: avgAttendance >= 75 ? Colors.green : Colors.orange,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Weekly bar chart
          if (_weeklyStats.isNotEmpty) ...[
            Text('Weekly Attendance (Last 7 Days)',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                child: SizedBox(
                  height: 200,
                  child: BarChart(
                    BarChartData(
                      alignment: BarChartAlignment.spaceAround,
                      maxY: (_weeklyStats
                                  .map((e) =>
                                      (e['present'] as num?)?.toDouble() ?? 0)
                                  .reduce((a, b) => a > b ? a : b) *
                              1.3)
                          .clamp(10, double.infinity),
                      barTouchData: BarTouchData(enabled: false),
                      titlesData: FlTitlesData(
                        leftTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            getTitlesWidget: (value, meta) {
                              final idx = value.toInt();
                              if (idx < 0 || idx >= _weeklyStats.length) {
                                return const SizedBox.shrink();
                              }
                              final dateStr =
                                  _weeklyStats[idx]['date'] as String? ?? '';
                              try {
                                final d = DateTime.parse(dateStr);
                                return Text(
                                  DateFormat('E').format(d),
                                  style: const TextStyle(fontSize: 10),
                                );
                              } catch (_) {
                                return Text(dateStr,
                                    style: const TextStyle(fontSize: 10));
                              }
                            },
                          ),
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      gridData: const FlGridData(show: false),
                      barGroups: _weeklyStats.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final stat = entry.value;
                        final present =
                            (stat['present'] as num?)?.toDouble() ?? 0;
                        final absent =
                            (stat['absent'] as num?)?.toDouble() ?? 0;
                        return BarChartGroupData(
                          x: idx,
                          barRods: [
                            BarChartRodData(
                              toY: present,
                              color: Colors.green,
                              width: 12,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            BarChartRodData(
                              toY: absent,
                              color: Colors.red.withValues(alpha:0.7),
                              width: 12,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _legend('Present', Colors.green),
                const SizedBox(width: 16),
                _legend('Absent', Colors.red),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStudentsTab(ThemeData theme) {
    if (_studentReport.isEmpty) {
      return const Center(child: Text('No student data'));
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: _studentReport.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final s = _studentReport[i];
          final pct = (s['attendance_percentage'] as num?)?.toDouble() ?? 0;
          final good = pct >= 75;
          return ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 20,
              backgroundColor: (good ? Colors.green : Colors.red).withValues(alpha:0.15),
              child: Text(
                '${pct.toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: good ? Colors.green : Colors.red,
                ),
              ),
            ),
            title: Text(
              '${s['first_name'] ?? ''} ${s['last_name'] ?? ''}'.trim(),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              'Class ${s['class_grade'] ?? ''}-${s['division'] ?? ''}  ·  '
              'P: ${s['present_days'] ?? 0}  A: ${s['absent_days'] ?? 0}  L: ${s['late_days'] ?? 0}',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: Icon(
              good ? Icons.thumb_up_outlined : Icons.warning_amber_outlined,
              color: good ? Colors.green : Colors.orange,
              size: 18,
            ),
          );
        },
      ),
    );
  }

  Widget _statCard(
      String label, String value, Color color, IconData icon, ThemeData theme) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: color)),
                  Text(label,
                      style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface.withValues(alpha:0.6))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legend(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 12,
            height: 12,
            decoration:
                BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}
