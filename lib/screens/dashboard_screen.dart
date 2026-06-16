import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/attendance_provider.dart';
import '../services/api_service.dart';
import '../widgets/offline_banner.dart';
import '../widgets/stat_card.dart';
import '../constants/app_colors.dart';
import '../utils/date_utils.dart' as du;
import 'manage_academies_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  Future<void> _loadData() async {
    // Silently warm up backend + InsightFace on every dashboard load.
    // Fire-and-forget — never blocks the UI or throws to the caller.
    ApiService.checkHealth().ignore();

    final att = context.read<AttendanceProvider>();
    await Future.wait([
      att.fetchDashboardStats(),
      att.fetchWeeklyStats(),
      att.fetchRecentActivity(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final att = context.watch<AttendanceProvider>();
    final stats = att.dashboardStats;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'EduScan',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        actions: [
          CircleAvatar(
            radius: 16,
            backgroundColor: theme.colorScheme.primary,
            child: Text(
              auth.admin?.initials ?? 'A',
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () async {
              await auth.logout();
              if (mounted) Navigator.of(context).pushReplacementNamed('/login');
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadData,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Good ${_greeting()}, ${auth.admin?.displayName ?? 'Admin'}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha:0.7),
                      ),
                    ),
                    Text(
                      DateFormat('EEEE, d MMMM yyyy').format(DateTime.now()),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha:0.5),
                      ),
                    ),
                    const SizedBox(height: 16),
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 1.3,
                      children: [
                        StatCard(
                          title: 'Total Students',
                          value: stats?['total_students']?.toString() ?? '-',
                          icon: Icons.groups_outlined,
                          color: AppColors.primary,
                          onTap: () => Navigator.pushNamed(context, '/students'),
                        ),
                        StatCard(
                          title: 'Present Today',
                          value: stats?['present_today']?.toString() ?? '-',
                          icon: Icons.check_circle_outline,
                          color: Colors.green,
                          onTap: () => Navigator.pushNamed(context, '/attendance'),
                        ),
                        StatCard(
                          title: 'Absent Today',
                          value: stats?['absent_today']?.toString() ?? '-',
                          icon: Icons.cancel_outlined,
                          color: Colors.red,
                        ),
                        StatCard(
                          title: 'Attendance %',
                          value: stats != null
                              ? '${(stats['attendance_percentage'] as num).toStringAsFixed(1)}%'
                              : '-',
                          icon: Icons.pie_chart_outline,
                          color: Colors.orange,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // ── Manage Academies shortcut ──────────────────────
                    InkWell(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ManageAcademiesScreen()),
                      ),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              theme.colorScheme.primary,
                              theme.colorScheme.primary.withValues(alpha: 0.75),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(children: [
                          const Icon(Icons.school_outlined,
                              color: Colors.white, size: 28),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Manage Academies',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15)),
                                Text('View, export, activate or delete academies',
                                    style: TextStyle(
                                        color: Colors.white
                                            .withValues(alpha: 0.8),
                                        fontSize: 12)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right,
                              color: Colors.white, size: 22),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text('Weekly Attendance',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: SizedBox(
                          height: 180,
                          child: att.weeklyStats.isEmpty
                              ? const Center(child: Text('No data yet'))
                              : BarChart(_buildBarChart(att.weeklyStats, theme)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text('Recent Activity',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    if (att.recentActivity.isEmpty)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: Text('No recent activity',
                                style: TextStyle(
                                    color: theme.colorScheme.onSurface.withValues(alpha:0.5))),
                          ),
                        ),
                      )
                    else
                      Card(
                        child: ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: att.recentActivity.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final r = att.recentActivity[i] as Map<String, dynamic>;
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.primary.withValues(alpha:0.12),
                                child: Text(
                                  '${(r['first_name'] as String? ?? 'A')[0]}${(r['last_name'] as String? ?? '')[0]}'
                                      .toUpperCase(),
                                  style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                              title: Text(
                                  '${r['first_name']} ${r['last_name']}'),
                              subtitle: Text(
                                  'Class ${r['class_grade']}-${r['division']}  •  ${_fmt12(r['time_in'] as String?)}'),
                              trailing: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: r['status'] == 'present'
                                      ? Colors.green.withValues(alpha:0.12)
                                      : Colors.red.withValues(alpha:0.12),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  (r['status'] as String).toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: r['status'] == 'present'
                                        ? Colors.green.shade700
                                        : Colors.red.shade700,
                                  ),
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
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) {
          setState(() => _currentIndex = i);
          switch (i) {
            case 0: break;
            case 1: Navigator.pushNamed(context, '/students'); break;
            case 2: Navigator.pushNamed(context, '/checkin'); break;
            case 3: Navigator.pushNamed(context, '/attendance'); break;
            case 4: Navigator.pushNamed(context, '/reports'); break;
          }
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Students'),
          NavigationDestination(icon: Icon(Icons.face_retouching_natural), label: 'Scan'),
          NavigationDestination(icon: Icon(Icons.event_note_outlined), selectedIcon: Icon(Icons.event_note), label: 'Attendance'),
          NavigationDestination(icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart), label: 'Reports'),
        ],
      ),
    );
  }

  BarChartData _buildBarChart(List<Map<String, dynamic>> data, ThemeData theme) {
    final groups = <String, double>{};
    for (final d in data) {
      final key = '${d['class_grade']}-${d['division']}';
      final pct = (d['percentage'] as num?)?.toDouble() ?? 0;
      groups[key] = (groups[key] ?? 0) + pct;
    }
    final keys = groups.keys.toList();
    return BarChartData(
      barGroups: keys.asMap().entries.map((e) {
        return BarChartGroupData(x: e.key, barRods: [
          BarChartRodData(
            toY: (groups[e.value] ?? 0).clamp(0, 100),
            color: theme.colorScheme.primary,
            width: 16,
            borderRadius: BorderRadius.circular(4),
          ),
        ]);
      }).toList(),
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (v, _) {
              final idx = v.toInt();
              if (idx < 0 || idx >= keys.length) return const SizedBox.shrink();
              return Text(keys[idx], style: const TextStyle(fontSize: 9));
            },
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 32,
            getTitlesWidget: (v, _) =>
                Text('${v.toInt()}%', style: const TextStyle(fontSize: 9)),
          ),
        ),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      gridData: FlGridData(
        drawHorizontalLine: true,
        horizontalInterval: 20,
      ),
      borderData: FlBorderData(show: false),
      maxY: 100,
    );
  }

  String _fmt12(String? t) =>
      (t == null || t.isEmpty) ? '' : du.fmtTimeOfDay(t);

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'morning';
    if (h < 17) return 'afternoon';
    return 'evening';
  }
}
