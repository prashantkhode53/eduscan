import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../providers/parent_auth_provider.dart';
import '../../services/parent_api_service.dart';
import '../../services/fcm_service.dart';
import '../../utils/fee_format.dart';
import '../../utils/date_utils.dart' as du;
import 'parent_receipts_screen.dart';
import 'parent_notifications_screen.dart';
import 'parent_attendance_screen.dart';
import '../../widgets/notification_ticker.dart';

class ParentDashboardScreen extends StatefulWidget {
  const ParentDashboardScreen({super.key});

  @override
  State<ParentDashboardScreen> createState() => _ParentDashboardScreenState();
}

class _ParentDashboardScreenState extends State<ParentDashboardScreen> {
  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _history = [];
  bool _loading = true;
  String? _error;

  // Latest broadcast (drives the always-visible ticker) + unread badge count.
  String? _latestMessage;
  int     _unreadCount = 0;

  @override
  void initState() {
    super.initState();
    _loadCachedTicker();   // show last-known message instantly (persists sessions)
    _load();
    _loadNotifications();
    // When a parent_notification push arrives while the app is open, refresh the
    // ticker + badge immediately so the dashboard reflects the newest message.
    FcmService.onParentNotification = _loadNotifications;
  }

  @override
  void dispose() {
    if (FcmService.onParentNotification == _loadNotifications) {
      FcmService.onParentNotification = null;
    }
    super.dispose();
  }

  String get _tickerCacheKey {
    final sid = context.read<ParentAuthProvider>().user?.studentId ?? 'unknown';
    return 'ticker_latest_$sid';
  }

  Future<void> _loadCachedTicker() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_tickerCacheKey);
      if (cached != null && cached.isNotEmpty && mounted) {
        setState(() => _latestMessage = cached);
      }
    } catch (_) {/* best-effort */}
  }

  Future<void> _loadNotifications() async {
    try {
      final results = await Future.wait([
        ParentApiService.getLatestNotification(),
        ParentApiService.getNotifications(page: 1, limit: 1),
      ]);
      if (!mounted) return;
      final latest = results[0] as Map<String, dynamic>?;
      final list   = results[1] as Map<String, dynamic>;
      final message = latest?['message']?.toString();
      setState(() {
        _latestMessage = message ?? _latestMessage;
        _unreadCount   = (list['unread_count'] as num?)?.toInt() ?? _unreadCount;
      });
      if (message != null && message.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_tickerCacheKey, message);
      }
    } catch (_) {/* ticker/badge are non-critical; keep cached value */}
  }

  Future<void> _openNotifications() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ParentNotificationsScreen()),
    );
    if (changed == true) _loadNotifications();   // refresh badge after reading
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        ParentApiService.getProfile(),
        ParentApiService.getAttendance(days: 30),
      ]);
      if (!mounted) return;
      setState(() {
        _profile = results[0] as Map<String, dynamic>;
        _history = results[1] as List<Map<String, dynamic>>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error   = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Log Out'),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Log Out')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await FcmService.deleteToken();
    if (!mounted) return;
    await context.read<ParentAuthProvider>().logout();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  String _fmtTime(String? t) => du.fmtTimeOfDay(t);

  String _fmtDuration(dynamic mins) {
    final m = (mins as num?)?.toInt() ?? 0;
    final h = m ~/ 60;
    final r = m  % 60;
    return h > 0 ? '${h}h ${r}m' : '${r}m';
  }

  String _fmtDate(dynamic raw) => du.fmtDate(raw?.toString());

  String _dayLabel(String dateStr) {
    try {
      final d = DateTime.parse(dateStr);
      const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
      return days[d.weekday - 1];
    } catch (_) { return ''; }
  }

  @override
  Widget build(BuildContext context) {
    final auth  = context.watch<ParentAuthProvider>();
    final theme = Theme.of(context);
    final user  = auth.user;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(user?.academyName ?? 'EduScan',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold)),
            if (user != null)
              Text(user.studentFullName,
                  style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          // Notifications bell with unread-count badge
          IconButton(
            tooltip: 'Notifications',
            onPressed: _openNotifications,
            icon: Badge(
              isLabelVisible: _unreadCount > 0,
              label: Text(_unreadCount > 99 ? '99+' : '$_unreadCount'),
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          IconButton(
              icon: const Icon(Icons.receipt_long_outlined),
              tooltip: 'Fee Receipts',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const ParentReceiptsScreen()),
              )),
          IconButton(
              icon: const Icon(Icons.refresh_outlined),
              tooltip: 'Refresh',
              onPressed: () { _load(); _loadNotifications(); }),
          IconButton(
              icon: const Icon(Icons.logout_outlined),
              tooltip: 'Log Out',
              onPressed: _logout),
        ],
      ),
      body: Column(
        children: [
          // Always-visible latest-announcement ticker (persists across sessions).
          if (_latestMessage != null && _latestMessage!.isNotEmpty)
            NotificationTicker(
              message: _latestMessage!,
              onTap: _openNotifications,
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _buildError(theme)
                    : RefreshIndicator(
                        onRefresh: () async {
                          await _load();
                          await _loadNotifications();
                        },
                        child: ListView(
                          padding: EdgeInsets.fromLTRB(
                              16, 16, 16,
                              MediaQuery.of(context).padding.bottom + 24),
                          children: [
                            _buildTodayCard(theme),
                            const SizedBox(height: 16),
                            _buildWeekStrip(theme),
                            const SizedBox(height: 16),
                            if (_pendingFees.isNotEmpty) ...[
                              _buildFeesCard(theme),
                              const SizedBox(height: 16),
                            ],
                            _buildHistory(theme),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  // ── Error ─────────────────────────────────────────────────────────────────

  Widget _buildError(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 56, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.6))),
              const SizedBox(height: 20),
              FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry')),
            ],
          ),
        ),
      );

  // ── Today card ────────────────────────────────────────────────────────────

  Map<String, dynamic> get _today =>
      (_profile?['today_attendance'] as Map<String, dynamic>?) ?? {};

  Widget _buildTodayCard(ThemeData theme) {
    final hasIn  = _today['time_in']  != null;
    final hasOut = _today['time_out'] != null;

    Color cardColor;
    IconData icon;
    String headline;
    if (hasIn && hasOut) {
      cardColor = Colors.green.shade700;
      icon      = Icons.check_circle_outline;
      headline  = 'Checked Out';
    } else if (hasIn) {
      cardColor = Colors.blue.shade600;
      icon      = Icons.login_outlined;
      headline  = 'Currently Present';
    } else {
      cardColor = Colors.grey.shade600;
      icon      = Icons.access_time_outlined;
      headline  = 'Not Yet Arrived';
    }

    return Card(
      color: cardColor,
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: Colors.white, size: 28),
              const SizedBox(width: 10),
              Text('Today',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 13)),
              const Spacer(),
              Text(
                _formatToday(),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ]),
            const SizedBox(height: 10),
            Text(headline,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(children: [
              _timeChip(Icons.login,  'In',  _fmtTime(_today['time_in'] as String?)),
              const SizedBox(width: 12),
              if (hasOut)
                _timeChip(Icons.logout, 'Out', _fmtTime(_today['time_out'] as String?)),
              if (hasOut) ...[
                const SizedBox(width: 12),
                _timeChip(Icons.timer_outlined, 'Duration',
                    _fmtDuration(_today['duration_mins'])),
              ],
            ]),
          ],
        ),
      ),
    );
  }

  String _formatToday() {
    final now = DateTime.now();
    const months = ['Jan','Feb','Mar','Apr','May','Jun',
                    'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${now.day} ${months[now.month - 1]} ${now.year}';
  }

  Widget _timeChip(IconData icon, String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 12, color: Colors.white70),
              const SizedBox(width: 4),
              Text(label,
                  style: const TextStyle(color: Colors.white70, fontSize: 10)),
            ]),
            const SizedBox(height: 2),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
          ],
        ),
      );

  // ── This week strip ───────────────────────────────────────────────────────

  Widget _buildWeekStrip(ThemeData theme) {
    // Build a map of date → status from history
    final byDate = <String, String>{};
    for (final r in _history) {
      byDate[_fmtDate(r['date'])] = r['status'] as String? ?? '';
    }

    // Generate Mon–Sun of current week
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final days = List.generate(7, (i) => monday.add(Duration(days: i)));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This Week',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: days.map((d) {
                final key    = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                final status = byDate[key];
                final isToday = key == now.toIso8601String().split('T')[0];
                final isFuture = d.isAfter(now);
                const days7 = ['M','T','W','T','F','S','S'];
                return _dayDot(
                  label:    days7[d.weekday - 1],
                  status:   status,
                  isToday:  isToday,
                  isFuture: isFuture,
                  theme:    theme,
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dayDot({
    required String  label,
    required String? status,
    required bool    isToday,
    required bool    isFuture,
    required ThemeData theme,
  }) {
    Color bg;
    IconData? icon;
    if (isFuture) {
      bg   = theme.colorScheme.surfaceContainerLow;
      icon = null;
    } else if (status == 'present' || status == 'late') {
      bg   = Colors.green;
      icon = Icons.check;
    } else if (status == 'absent') {
      bg   = Colors.red.shade400;
      icon = Icons.close;
    } else {
      bg   = Colors.grey.shade300;
      icon = null;
    }

    return Column(
      children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: isToday
                ? Border.all(color: theme.colorScheme.primary, width: 2)
                : null,
          ),
          child: icon != null
              ? Icon(icon, size: 16, color: Colors.white)
              : null,
        ),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(
                fontSize: 10,
                fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                color: isToday
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface.withValues(alpha: 0.6))),
      ],
    );
  }

  // ── Pending fees ──────────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _pendingFees =>
      ((_profile?['pending_fees'] as List?) ?? [])
          .cast<Map<String, dynamic>>();

  Widget _buildFeesCard(ThemeData theme) {
    return Card(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.warning_amber_outlined,
                  color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              Text('Fees Due',
                  style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold, color: Colors.orange.shade800)),
            ]),
            const SizedBox(height: 10),
            ..._pendingFees.map((f) {
              final due    = double.tryParse(f['amount_due']?.toString() ?? '0') ?? 0;
              final paid   = double.tryParse(f['amount_paid']?.toString() ?? '0') ?? 0;
              final balance = due - paid;
              final date   = _fmtDate(f['due_date']);
              final status = f['status'] as String? ?? '';
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(courseLabelOf(f),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 13),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                          Text('Due: $date',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.6))),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('₹${balance.toStringAsFixed(0)}',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: status == 'overdue'
                                    ? Colors.red
                                    : Colors.orange.shade800)),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: (status == 'overdue'
                                    ? Colors.red
                                    : Colors.orange)
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(status.toUpperCase(),
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: status == 'overdue'
                                      ? Colors.red
                                      : Colors.orange.shade800)),
                        ),
                      ],
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

  // ── Attendance history ────────────────────────────────────────────────────

  Widget _buildHistory(ThemeData theme) {
    if (_history.isEmpty) {
      // Still let parents open the full filterable view (e.g. to check a past month).
      return Card(
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ParentAttendanceScreen()),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.event_note_outlined,
                      size: 40,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
                  const SizedBox(height: 8),
                  Text('No attendance records yet',
                      style: TextStyle(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.5))),
                  const SizedBox(height: 4),
                  Text('Tap to view other months',
                      style: TextStyle(fontSize: 12,
                          color: theme.colorScheme.primary)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tappable header → full filterable attendance record with Excel download.
          InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ParentAttendanceScreen()),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(children: [
                Text('Last 30 Days',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('View all',
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600)),
                Icon(Icons.chevron_right, size: 18, color: theme.colorScheme.primary),
              ]),
            ),
          ),
          const Divider(height: 1),
          ...(_history.take(30).map((r) {
            final status = r['status'] as String? ?? '';
            final date   = _fmtDate(r['date']);
            final timeIn = _fmtTime(r['time_in'] as String?);
            final timeOut= _fmtTime(r['time_out'] as String?);
            final hasOut = r['time_out'] != null;

            Color statusColor;
            IconData statusIcon;
            switch (status) {
              case 'present': statusColor = Colors.green;  statusIcon = Icons.check_circle; break;
              case 'late':    statusColor = Colors.orange; statusIcon = Icons.watch_later_outlined; break;
              case 'absent':  statusColor = Colors.red;    statusIcon = Icons.cancel_outlined; break;
              default:        statusColor = Colors.grey;   statusIcon = Icons.help_outline;
            }

            return ListTile(
              dense: true,
              leading: Icon(statusIcon, color: statusColor, size: 22),
              title: Text(
                '$date  ·  ${_dayLabel(date)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
              subtitle: Text(
                hasOut
                    ? 'In: $timeIn  ·  Out: $timeOut  ·  ${_fmtDuration(r['duration_mins'])}'
                    : (r['time_in'] != null ? 'In: $timeIn' : 'Absent'),
                style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
              ),
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(status.toUpperCase(),
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: statusColor)),
              ),
            );
          })),
        ],
      ),
    );
  }
}
