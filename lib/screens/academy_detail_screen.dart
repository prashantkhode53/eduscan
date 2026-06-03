import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import '../services/super_admin_api_service.dart';
import 'academy_students_screen.dart';

class AcademyDetailScreen extends StatefulWidget {
  final Map<String, dynamic> academy;
  const AcademyDetailScreen({super.key, required this.academy});

  @override
  State<AcademyDetailScreen> createState() => _AcademyDetailScreenState();
}

class _AcademyDetailScreenState extends State<AcademyDetailScreen> {
  Map<String, dynamic>? _stats;
  bool _loading = true;
  bool _changed = false; // true when caller should refresh list

  late Map<String, dynamic> _academy;

  @override
  void initState() {
    super.initState();
    _academy = Map.from(widget.academy);
    _loadStats();
  }

  Future<void> _loadStats() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final data = await SuperAdminApiService.getAcademyStats(
          _academy['slug'] as String);
      if (!mounted) return;
      setState(() {
        _stats   = data['stats'] as Map<String, dynamic>?;
        _academy = (data['academy'] as Map<String, dynamic>?) ?? _academy;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        backgroundColor: Colors.red,
      ));
    }
  }

  bool get _isActive => _academy['status'] == 'active';
  String get _slug   => _academy['slug'] as String;
  String get _name   => _academy['name'] as String? ?? '';

  // ── Toggle active / inactive ──────────────────────────────────────────────

  Future<void> _toggleStatus() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(_isActive ? 'Deactivate Academy' : 'Activate Academy'),
        content: Text(_isActive
            ? 'Deactivate "$_name"?\n\nUsers will not be able to login until the academy is reactivated.'
            : 'Activate "$_name"?\n\nThe academy will immediately become operational.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: _isActive ? Colors.orange : Colors.green),
              onPressed: () => Navigator.pop(context, true),
              child: Text(_isActive ? 'Deactivate' : 'Activate')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      if (_isActive) {
        await SuperAdminApiService.deactivateAcademy(_slug);
      } else {
        await SuperAdminApiService.activateAcademy(_slug);
      }
      _changed = true;
      await _loadStats();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  // ── Export student data ───────────────────────────────────────────────────

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
        const SnackBar(content: Text('Exporting student data…')));
    try {
      final data     = await SuperAdminApiService.exportAcademyStudents(_slug);
      final students = (data['students'] as List? ?? [])
          .cast<Map<String, dynamic>>();

      // Build CSV
      final headers = [
        'Student ID', 'First Name', 'Last Name', 'Mobile', 'Email',
        'Parent Name', 'Parent Mobile', 'Courses', 'Academic Year',
        'Status', 'Registration Date',
      ];
      String _q(String s) => '"${s.replaceAll('"', '""')}"';
      final lines = [
        headers.map(_q).join(','),
        ...students.map((s) => [
          s['id']               ?? '',
          s['first_name']       ?? '',
          s['last_name']        ?? '',
          s['mobile']           ?? '',
          s['email']            ?? '',
          s['parent_name']      ?? '',
          s['parent_mobile']    ?? '',
          s['courses']          ?? '',
          s['academic_year']    ?? '',
          s['status']           ?? '',
          s['registration_date'] ?? '',
        ].map((v) => _q(v.toString())).join(',')),
      ];

      final dir  = await getApplicationDocumentsDirectory();
      final safe = _name.replaceAll(RegExp(r'[^\w\s]'), '').trim();
      final file = File('${dir.path}/${safe}_Students.csv');
      await file.writeAsString(lines.join('\n'));

      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text('Exported ${students.length} students'),
        backgroundColor: Colors.green,
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => OpenFilex.open(file.path),
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        backgroundColor: Colors.red,
      ));
    }
  }

  // ── Delete academy (multi-step dialog) ────────────────────────────────────

  Future<void> _deleteAcademy() async {
    // Step 1: Stats warning
    final proceed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Academy Permanently'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _WarningBadge('This action CANNOT be undone.'),
            const SizedBox(height: 12),
            _InfoRow('Academy',  _name),
            _InfoRow('Schema',   _slug),
            _InfoRow('Students', '${_stats?['total_students'] ?? 0}'),
            _InfoRow('Courses',  '${_stats?['courses'] ?? 0}'),
            _InfoRow('Attendance records',
                '${_stats?['attendance_records'] ?? 0}'),
            const SizedBox(height: 12),
            const Text(
              'All data including students, attendance, fees, courses and '
              'academic years will be permanently removed.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue')),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    // Step 2: Name + password confirmation
    final nameCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    bool passVisible = false;
    bool confirmed   = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        final nameOk =
            nameCtrl.text.trim().toLowerCase() == _name.trim().toLowerCase();
        return AlertDialog(
          title: const Text('Confirm Permanent Deletion'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Type the academy name to confirm:',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6))),
              const SizedBox(height: 6),
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  hintText: _name,
                  border: const OutlineInputBorder(),
                  errorText: nameCtrl.text.isNotEmpty && !nameOk
                      ? 'Does not match'
                      : null,
                ),
                onChanged: (_) => setDlg(() {}),
              ),
              const SizedBox(height: 12),
              Text('Enter your Super Admin password:',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6))),
              const SizedBox(height: 6),
              TextField(
                controller: passCtrl,
                obscureText: !passVisible,
                decoration: InputDecoration(
                  hintText: 'Password',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(passVisible
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () => setDlg(() => passVisible = !passVisible),
                  ),
                ),
                onChanged: (_) => setDlg(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: nameOk && passCtrl.text.isNotEmpty
                  ? () {
                      confirmed = true;
                      Navigator.pop(ctx);
                    }
                  : null,
              child: const Text('Delete Permanently'),
            ),
          ],
        );
      }),
    );

    if (!confirmed || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
        const SnackBar(content: Text('Deleting academy…')));
    try {
      await SuperAdminApiService.deleteAcademy(
          _slug, passCtrl.text, nameCtrl.text);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text('"$_name" permanently deleted'),
        backgroundColor: Colors.green,
      ));
      Navigator.pop(context, true); // signal list to refresh
    } catch (e) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        backgroundColor: Colors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      onPopInvokedWithResult: (_, __) {},
      child: Scaffold(
        appBar: AppBar(
          title: Text(_name),
          leading: BackButton(
              onPressed: () => Navigator.pop(context, _changed)),
          actions: [
            IconButton(
                icon: const Icon(Icons.refresh), onPressed: _loadStats),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // ── Academy info card ─────────────────────────────────
                  _SectionLabel('Academy Information'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _InfoTile(Icons.school_outlined,  'Name',       _name),
                          _InfoTile(Icons.storage_outlined, 'Schema',     _slug),
                          _InfoTile(Icons.person_outline,   'Admin',
                              _academy['admin_name'] as String? ?? '—'),
                          _InfoTile(Icons.email_outlined,   'Email',
                              _academy['admin_email'] as String? ?? '—'),
                          _InfoTile(Icons.phone_outlined,   'Phone',
                              _academy['phone'] as String? ?? '—'),
                          _InfoTile(Icons.calendar_today_outlined, 'Created',
                              _fmtDate(_academy['created_at'])),
                          _InfoTile(
                            Icons.circle,
                            'Status',
                            _isActive ? 'Active' : 'Inactive',
                            valueColor: _isActive ? Colors.green : Colors.orange,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Stats ─────────────────────────────────────────────
                  _SectionLabel('Statistics'),
                  GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 1.1,
                    children: [
                      _StatTile('Total', '${_stats?['total_students'] ?? 0}',
                          Colors.blue, Icons.people_outline),
                      _StatTile('Active', '${_stats?['active_students'] ?? 0}',
                          Colors.green, Icons.check_circle_outline),
                      _StatTile('Deleted', '${_stats?['deleted_students'] ?? 0}',
                          Colors.red, Icons.delete_outline),
                      _StatTile('Courses', '${_stats?['courses'] ?? 0}',
                          Colors.purple, Icons.menu_book_outlined),
                      _StatTile('Years', '${_stats?['academic_years'] ?? 0}',
                          Colors.teal, Icons.calendar_today_outlined),
                      _StatTile('Attendance',
                          '${_stats?['attendance_records'] ?? 0}',
                          Colors.orange, Icons.fact_check_outlined),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // ── Actions ───────────────────────────────────────────
                  _SectionLabel('Actions'),
                  const SizedBox(height: 8),

                  _ActionButton(
                    icon: Icons.people_outline,
                    label: 'View Students',
                    color: theme.colorScheme.primary,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => AcademyStudentsScreen(
                              slug: _slug, academyName: _name)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _ActionButton(
                    icon: Icons.download_outlined,
                    label: 'Export Student Data (.csv)',
                    color: Colors.teal,
                    onTap: _export,
                  ),
                  const SizedBox(height: 8),
                  _ActionButton(
                    icon: _isActive
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                    label: _isActive ? 'Deactivate Academy' : 'Activate Academy',
                    color: _isActive ? Colors.orange : Colors.green,
                    onTap: _toggleStatus,
                  ),
                  const SizedBox(height: 16),
                  // Delete — visually distinct warning button
                  OutlinedButton.icon(
                    onPressed: _deleteAcademy,
                    icon: const Icon(Icons.delete_forever, color: Colors.red),
                    label: const Text('Delete Academy Permanently',
                        style: TextStyle(color: Colors.red)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
      ),
    );
  }

  String _fmtDate(dynamic raw) {
    if (raw == null) return '—';
    final s = raw.toString();
    if (s.length >= 10) {
      final p = s.substring(0, 10).split('-');
      if (p.length == 3) return '${p[2]}/${p[1]}/${p[0]}';
    }
    return s;
  }
}

// ── Small helpers ──────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.bold)),
  );
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  final Color?   valueColor;
  const _InfoTile(this.icon, this.label, this.value, {this.valueColor});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(children: [
      Icon(icon, size: 16,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45)),
      const SizedBox(width: 10),
      SizedBox(
        width: 90,
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.55))),
      ),
      Expanded(
        child: Text(value,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: valueColor)),
      ),
    ]),
  );
}

class _StatTile extends StatelessWidget {
  final String   label;
  final String   value;
  final Color    color;
  final IconData icon;
  const _StatTile(this.label, this.value, this.color, this.icon);
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.2)),
    ),
    padding: const EdgeInsets.all(10),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        Text(label,
            style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.8)),
            textAlign: TextAlign.center),
      ],
    ),
  );
}

class _ActionButton extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final Color        color;
  final VoidCallback onTap;
  const _ActionButton(
      {required this.icon, required this.label,
       required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: onTap,
    icon: Icon(icon),
    label: Text(label),
    style: FilledButton.styleFrom(
      backgroundColor: color,
      minimumSize: const Size.fromHeight(48),
    ),
  );
}

class _WarningBadge extends StatelessWidget {
  final String text;
  const _WarningBadge(this.text);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Colors.red.shade50,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.red.shade200),
    ),
    child: Row(children: [
      Icon(Icons.warning_amber_rounded,
          color: Colors.red.shade700, size: 18),
      const SizedBox(width: 8),
      Expanded(child: Text(text,
          style: TextStyle(color: Colors.red.shade800,
              fontWeight: FontWeight.bold, fontSize: 12))),
    ]),
  );
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [
      SizedBox(
        width: 130,
        child: Text('$label:',
            style: const TextStyle(fontSize: 12,
                fontWeight: FontWeight.w500)),
      ),
      Expanded(child: Text(value,
          style: const TextStyle(fontSize: 12))),
    ]),
  );
}
