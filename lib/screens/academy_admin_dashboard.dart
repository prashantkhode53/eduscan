import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/academic_year_provider.dart';
import '../models/academy_user.dart';
import '../services/academy_api_service.dart';
import '../utils/platform_support.dart';
import 'academy/course_master_screen.dart';
import 'academy/academy_student_list_screen.dart';
import 'academy/academy_student_registration_screen.dart';
import 'academy/bulk_upload_screen.dart';
import 'academy/fees_screen.dart';
import 'academy/academy_face_scan_screen.dart';
import 'academy/attendance_hub_screen.dart';
import 'academy/qr_code_screen.dart';
import 'academy/academic_year_master_screen.dart';
import 'academy/send_notification_screen.dart';

class AcademyAdminDashboard extends StatefulWidget {
  const AcademyAdminDashboard({super.key});

  @override
  State<AcademyAdminDashboard> createState() => _AcademyAdminDashboardState();
}

class _AcademyAdminDashboardState extends State<AcademyAdminDashboard> {
  int _currentIndex = 0;
  final _studentReloadTrigger = ValueNotifier<int>(0);

  @override
  void dispose() {
    _studentReloadTrigger.dispose();
    super.dispose();
  }

  final List<_NavItem> _navItems = const [
    _NavItem(icon: Icons.dashboard_outlined,    activeIcon: Icons.dashboard,    label: 'Home'),
    _NavItem(icon: Icons.people_outline,        activeIcon: Icons.people,       label: 'Students'),
    _NavItem(icon: Icons.account_balance_wallet_outlined, activeIcon: Icons.account_balance_wallet, label: 'Fees'),
    _NavItem(icon: Icons.settings_outlined,     activeIcon: Icons.settings,     label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.academyUser;
    if (user == null) return const SizedBox.shrink();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Back on a non-home tab → silently return to Home.
        if (_currentIndex != 0) {
          setState(() => _currentIndex = 0);
          return;
        }
        // Back on Home tab → confirm before leaving.
        if (!context.mounted) return;
        final exit = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Exit App'),
            content: const Text('Are you sure you want to exit EduScan?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Exit'),
              ),
            ],
          ),
        );
        if (exit == true && context.mounted) {
          // Close the app without clearing the session — token stays in
          // SharedPreferences so the next launch skips the login screen.
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: [
            _HomeTab(user: user, studentReloadTrigger: _studentReloadTrigger),
            AcademyStudentListScreen(reloadTrigger: _studentReloadTrigger),
            const FeesScreen(),
            _SettingsTab(user: user),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (i) => setState(() => _currentIndex = i),
          destinations: _navItems
              .map((n) => NavigationDestination(
                    icon: Icon(n.icon),
                    selectedIcon: Icon(n.activeIcon),
                    label: n.label,
                  ))
              .toList(),
        ),
      ),
    );
  }
}

// ── Home tab ──────────────────────────────────────────────────────────────────

class _HomeTab extends StatefulWidget {
  final AcademyUser user;
  final ValueNotifier<int> studentReloadTrigger;
  const _HomeTab({required this.user, required this.studentReloadTrigger});

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  Map<String, dynamic> _stats = {};
  bool _loadingStats = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final yp = context.read<AcademicYearProvider>();
      await yp.init();
      yp.addListener(_onYearChanged);
      _loadStats();
    });
  }

  @override
  void dispose() {
    context.read<AcademicYearProvider>().removeListener(_onYearChanged);
    super.dispose();
  }

  void _onYearChanged() => _loadStats();

  Future<void> _loadStats() async {
    if (!mounted) return;
    setState(() => _loadingStats = true);
    try {
      final yearId = context.read<AcademicYearProvider>().selectedId;
      _stats = await AcademyApiService.getStats(academicYearId: yearId);
    } catch (_) {}
    if (mounted) setState(() => _loadingStats = false);
  }

  String _stat(String key) =>
      _loadingStats ? '…' : (_stats[key]?.toString() ?? '0');

  void _showYearPicker() {
    final yearProvider = context.read<AcademicYearProvider>();
    final theme        = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Select Academic Year',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
          ),
          const Divider(height: 1),
          if (yearProvider.years.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No academic years configured.',
                  style: TextStyle(color: Colors.grey)),
            )
          else
            ...yearProvider.years.map((y) {
              final id       = y['id']                 as String;
              final name     = y['academic_year_name'] as String? ?? '';
              final isCurr   = y['is_current_year']   == true;
              final selected = yearProvider.selectedId == id;
              return ListTile(
                leading: Icon(
                  isCurr ? Icons.star_rounded : Icons.calendar_today_outlined,
                  color: isCurr ? Colors.amber : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  size: 20,
                ),
                title: Text(name,
                    style: TextStyle(
                        fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                trailing: selected
                    ? Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 20)
                    : null,
                onTap: () {
                  yearProvider.select(id, name);
                  Navigator.pop(ctx);
                },
              );
            }),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.settings_outlined, size: 20),
            title: const Text('Manage Academic Years'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => const AcademicYearMasterScreen(),
              )).then((_) => yearProvider.init(force: true));
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Shows a bottom sheet with two registration options and reloads stats
  /// if a student was successfully registered.
  void _showRegisterOptions(BuildContext ctx) {
    showModalBottomSheet<void>(
      context: ctx,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('Register Student',
                  style: Theme.of(ctx).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Choose how you want to add students.',
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(ctx)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6))),
              const SizedBox(height: 20),

              // Option 1 — Bulk upload
              _OptionTile(
                icon: Icons.upload_file_outlined,
                color: Colors.teal,
                title: 'Upload Excel',
                subtitle: 'Register up to 1,000 students at once via .xlsx or .csv',
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await Navigator.push<bool>(
                    ctx,
                    MaterialPageRoute(
                        builder: (_) => const BulkUploadScreen()),
                  );
                  if (ok == true && ctx.mounted) {
                    _loadStats();
                    widget.studentReloadTrigger.value++;
                  }
                },
              ),
              // Option 2 — Single registration (existing flow).
              // Ends in on-device Face Capture (camera + ML Kit), which is
              // mobile-only — hidden on Windows. Bulk Excel upload above works
              // on Windows and remains available there.
              if (PlatformSupport.faceFeatures) ...[
                const SizedBox(height: 12),
                _OptionTile(
                  icon: Icons.person_add_outlined,
                  color: Colors.blue,
                  title: 'Single Student Registration',
                  subtitle:
                      'Personal Info → Parent Info → Courses → Face Capture',
                  onTap: () async {
                    Navigator.pop(ctx);
                    final ok = await Navigator.push<bool>(
                      ctx,
                      MaterialPageRoute(
                          builder: (_) =>
                              const AcademyStudentRegistrationScreen()),
                    );
                    if (ok == true && ctx.mounted) {
                      _loadStats();
                      widget.studentReloadTrigger.value++;
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final user       = widget.user;
    final yearProvider = context.watch<AcademicYearProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text(user.academyName,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          // ── Academic Year selector ─────────────────────────────────────
          GestureDetector(
            onTap: _showYearPicker,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (yearProvider.loading)
                    const SizedBox(
                        width: 12, height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.5))
                  else
                    Text(
                      yearProvider.selectedName.isNotEmpty
                          ? yearProvider.selectedName
                          : 'Select Year',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary),
                    ),
                  Icon(Icons.arrow_drop_down,
                      size: 16, color: theme.colorScheme.primary),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadStats),
          CircleAvatar(
            radius: 16,
            backgroundColor: theme.colorScheme.primary,
            child: Text(user.initials,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadStats,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Welcome card
            Card(
              color: theme.colorScheme.primary,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Welcome back,',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  fontSize: 13)),
                          const SizedBox(height: 4),
                          Text(user.name,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(user.role.toUpperCase(),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.school,
                        size: 48,
                        color: Colors.white.withValues(alpha: 0.4)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Quick actions
            Text('Quick Actions',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.6,
              children: [
                // Row 1: setup workflow first
                _QuickAction(
                  icon: Icons.calendar_today_outlined,
                  label: 'Academic Year',
                  color: Colors.indigo,
                  onTap: () async {
                    final yp = context.read<AcademicYearProvider>();
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AcademicYearMasterScreen()),
                    );
                    await yp.init(force: true);
                  },
                ),
                _QuickAction(
                  icon: Icons.menu_book_outlined,
                  label: 'Manage Courses',
                  color: Colors.orange,
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const CourseMasterScreen()),
                    );
                    _loadStats();
                  },
                ),
                // Row 2: student operations
                _QuickAction(
                  icon: Icons.how_to_reg_outlined,
                  label: 'Register Student',
                  color: Colors.blue,
                  onTap: () => _showRegisterOptions(context),
                ),
                // Face Scan Attendance relies on the camera image stream +
                // on-device ML Kit, which are mobile-only. Hidden on Windows.
                if (PlatformSupport.faceFeatures)
                  _QuickAction(
                    icon: Icons.face_outlined,
                    label: 'Face Scan Attendance',
                    color: Colors.green,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AcademyFaceScanScreen()),
                    ),
                  ),
                // Attendance Intelligence — read-only insights over attendance data
                _QuickAction(
                  icon: Icons.insights_outlined,
                  label: 'Attendance',
                  color: Colors.deepPurple,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const AttendanceHubScreen()),
                  ),
                ),
                // Row 3: financial & utilities
                _QuickAction(
                  icon: Icons.payments_outlined,
                  label: 'Collect Fee',
                  color: Colors.purple,
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const FeesScreen()),
                    );
                    _loadStats();
                  },
                ),
                _QuickAction(
                  icon: Icons.qr_code_2_outlined,
                  label: 'QR Codes',
                  color: Colors.teal,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const QrCodeScreen()),
                  ),
                ),
                _QuickAction(
                  icon: Icons.campaign_outlined,
                  label: 'Send Notifications',
                  color: Colors.pink,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const SendNotificationScreen()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Real stats
            Text('Overview',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                    child: _StatCard(
                        label: 'Students',
                        value: _stat('total_students'),
                        icon: Icons.people_outline,
                        color: Colors.blue)),
                const SizedBox(width: 12),
                Expanded(
                    child: _StatCard(
                        label: 'Courses',
                        value: _stat('total_courses'),
                        icon: Icons.menu_book_outlined,
                        color: Colors.orange)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                    child: _StatCard(
                        label: 'Present Today',
                        value: _stat('present_today'),
                        icon: Icons.check_circle_outline,
                        color: Colors.green)),
                const SizedBox(width: 12),
                Expanded(
                    child: _StatCard(
                        label: 'Fees Due',
                        value: _stat('fees_due'),
                        icon: Icons.warning_amber_outlined,
                        color: Colors.red)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Settings tab ──────────────────────────────────────────────────────────────

class _SettingsTab extends StatefulWidget {
  final AcademyUser user;
  const _SettingsTab({required this.user});

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  AcademyUser get user => widget.user;

  bool? _faceScanSecure;   // null = loading
  bool  _savingSecure = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final s = await AcademyApiService.getSettings();
      if (!mounted) return;
      setState(() => _faceScanSecure =
          (s['face_scan_secure'] ?? 'true').toLowerCase() != 'false');
    } catch (_) {
      if (!mounted) return;
      setState(() => _faceScanSecure = true); // fail safe: show as secure
    }
  }

  Future<void> _toggleFaceScanSecure(bool value) async {
    final previous = _faceScanSecure;
    setState(() { _faceScanSecure = value; _savingSecure = true; });
    try {
      await AcademyApiService.updateSetting(
          'face_scan_secure', value ? 'true' : 'false');
      if (!mounted) return;
      setState(() => _savingSecure = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(value
            ? 'Face Scan Attendance now requires a password to unlock.'
            : 'Face Scan Attendance can be unlocked without a password.'),
        backgroundColor: Colors.green,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() { _faceScanSecure = previous; _savingSecure = false; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        backgroundColor: Colors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor:
                        theme.colorScheme.primary.withValues(alpha: 0.15),
                    child: Text(user.initials,
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary)),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.name,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        Text(user.email,
                            style: TextStyle(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.6),
                                fontSize: 13)),
                        Text(user.academyName,
                            style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontSize: 12,
                                fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text('Log Out',
                  style: TextStyle(color: Colors.red)),
              onTap: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Log Out'),
                    content: const Text('Are you sure you want to logout from EduScan?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: Colors.red),
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Logout')),
                    ],
                  ),
                );
                if (confirm == true && context.mounted) {
                  context.read<AcademicYearProvider>().reset();
                  await context.read<AuthProvider>().logout();
                  Navigator.of(context)
                      .pushNamedAndRemoveUntil('/login', (_) => false);
                }
              },
            ),
          ),

          // ── Face Scan Attendance – Secure by Password ──────────────────
          const SizedBox(height: 16),
          Card(
            child: SwitchListTile(
              secondary: Icon(
                _faceScanSecure == false
                    ? Icons.lock_open_outlined
                    : Icons.lock_outline,
                color: theme.colorScheme.primary,
              ),
              title: const Text('Face Scan Attendance – Secure by Password'),
              subtitle: Text(
                _faceScanSecure == null
                    ? 'Loading…'
                    : (_faceScanSecure!
                        ? 'On — unlocking the scan screen requires the academy password.'
                        : 'Off — the scan screen can be locked/unlocked without a password.'),
                style: const TextStyle(fontSize: 12),
              ),
              value: _faceScanSecure ?? true,
              // Disabled while loading or saving so the value can't be toggled
              // before we know the real state or mid-write.
              onChanged: (_faceScanSecure == null || _savingSecure)
                  ? null
                  : _toggleFaceScanSecure,
            ),
          ),
        ],
      ),
    );
  }
}


// ── Small helpers ─────────────────────────────────────────────────────────────

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _NavItem(
      {required this.icon, required this.activeIcon, required this.label});
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _QuickAction(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: color)),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _StatCard(
      {required this.label,
      required this.value,
      required this.icon,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 8),
            Text(value,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: color)),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6))),
          ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _OptionTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.35)),
          color: color.withValues(alpha: 0.05),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: color.withValues(alpha: 0.15),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6))),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.35)),
          ],
        ),
      ),
    );
  }
}
