import 'package:flutter/material.dart';
import '../services/super_admin_api_service.dart';
import 'academy_detail_screen.dart';

class ManageAcademiesScreen extends StatefulWidget {
  const ManageAcademiesScreen({super.key});

  @override
  State<ManageAcademiesScreen> createState() => _ManageAcademiesScreenState();
}

class _ManageAcademiesScreenState extends State<ManageAcademiesScreen> {
  List<Map<String, dynamic>> _all      = [];
  List<Map<String, dynamic>> _filtered = [];
  bool    _loading   = true;
  String  _search    = '';
  String  _status    = 'all'; // all / active / inactive
  String  _sort      = 'created_at';

  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final data = await SuperAdminApiService.listAcademies(
        search: _search.isNotEmpty ? _search : null,
        status: _status != 'all' ? _status : null,
        sort:   _sort,
      );
      if (!mounted) return;
      setState(() {
        _all      = data;
        _filtered = data;
        _loading  = false;
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

  void _applySearch(String q) {
    setState(() {
      _search   = q;
      _filtered = _all.where((a) {
        final name = (a['name'] as String? ?? '').toLowerCase();
        final slug = (a['slug'] as String? ?? '').toLowerCase();
        final qLow = q.toLowerCase();
        return name.contains(qLow) || slug.contains(qLow);
      }).toList();
    });
  }

  Future<void> _openDetail(Map<String, dynamic> academy) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => AcademyDetailScreen(academy: academy)),
    );
    if (changed == true) _load();
  }

  // ── Summary helpers ─────────────────────────────────────────────────────────

  int get _total      => _all.length;
  int get _activeCount => _all.where((a) => a['status'] == 'active').length;
  int get _inactiveCount => _all.where((a) => a['status'] != 'active').length;
  int get _totalStudents => _all.fold(0, (s, a) => s + (a['student_count'] as int? ?? 0));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Academies'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            onSelected: (v) { setState(() => _sort = v); _load(); },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'created_at', child: Text('Sort: Newest First')),
              PopupMenuItem(value: 'name',       child: Text('Sort: Name A–Z')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Summary strip ────────────────────────────────────────────────
          if (!_loading)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Row(
                children: [
                  _SummaryCard('Total', '$_total', Colors.blue, Icons.school_outlined),
                  _SummaryCard('Active', '$_activeCount', Colors.green, Icons.check_circle_outline),
                  _SummaryCard('Inactive', '$_inactiveCount', Colors.orange, Icons.pause_circle_outline),
                  _SummaryCard('Students', '$_totalStudents', Colors.purple, Icons.people_outline),
                ],
              ),
            ),

          // ── Search bar ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search by name or schema…',
                prefixIcon: const Icon(Icons.search, size: 20),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                suffixIcon: _search.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          _applySearch('');
                        })
                    : null,
              ),
              onChanged: _applySearch,
            ),
          ),

          // ── Filter chips ─────────────────────────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: ['all', 'active', 'inactive'].map((s) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  label: Text(s == 'all' ? 'All' : s[0].toUpperCase() + s.substring(1)),
                  selected: _status == s,
                  onSelected: (_) {
                    setState(() => _status = s);
                    _load();
                  },
                  visualDensity: VisualDensity.compact,
                ),
              )).toList(),
            ),
          ),

          // ── Academy list ─────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.school_outlined,
                                size: 56,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.25)),
                            const SizedBox(height: 12),
                            const Text('No academies found'),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                          itemCount: _filtered.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (_, i) =>
                              _AcademyCard(
                                academy: _filtered[i],
                                onTap: () => _openDetail(_filtered[i]),
                                onStatusChanged: _load,
                              ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

// ── Summary card ──────────────────────────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final Color  color;
  final IconData icon;
  const _SummaryCard(this.label, this.value, this.color, this.icon);

  @override
  Widget build(BuildContext context) => Container(
    width: 110,
    margin: const EdgeInsets.only(right: 10),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 6),
        Text(value,
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        Text(label,
            style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.8))),
      ],
    ),
  );
}

// ── Academy list card ─────────────────────────────────────────────────────────

class _AcademyCard extends StatelessWidget {
  final Map<String, dynamic> academy;
  final VoidCallback onTap;
  final VoidCallback onStatusChanged;

  const _AcademyCard({
    required this.academy,
    required this.onTap,
    required this.onStatusChanged,
  });

  bool get _isActive => academy['status'] == 'active';

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final students  = academy['student_count'] as int? ?? 0;
    final courses   = academy['course_count']  as int? ?? 0;
    final createdAt = _fmtDate(academy['created_at']);

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: (_isActive ? Colors.green : Colors.orange)
                        .withValues(alpha: 0.15),
                    child: Icon(Icons.school,
                        color: _isActive ? Colors.green : Colors.orange,
                        size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(academy['name'] as String? ?? '',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                        Text(academy['slug'] as String? ?? '',
                            style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.5))),
                      ],
                    ),
                  ),
                  // Status badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: (_isActive ? Colors.green : Colors.orange)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _isActive ? 'Active' : 'Inactive',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: _isActive ? Colors.green.shade700
                                           : Colors.orange.shade700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Stats row
              Row(
                children: [
                  _Chip(Icons.people_outline, '$students students',
                      Colors.blue),
                  const SizedBox(width: 8),
                  _Chip(Icons.menu_book_outlined, '$courses courses',
                      Colors.purple),
                  const Spacer(),
                  Text(createdAt,
                      style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.45))),
                ],
              ),
              const SizedBox(height: 10),
              // Action buttons
              Row(
                children: [
                  _ActionBtn(
                    icon: Icons.info_outline,
                    label: 'Details',
                    color: theme.colorScheme.primary,
                    onTap: onTap,
                  ),
                  const SizedBox(width: 6),
                  if (_isActive)
                    _ActionBtn(
                      icon: Icons.pause_circle_outline,
                      label: 'Deactivate',
                      color: Colors.orange,
                      onTap: () => _toggleStatus(context),
                    )
                  else
                    _ActionBtn(
                      icon: Icons.play_circle_outline,
                      label: 'Activate',
                      color: Colors.green,
                      onTap: () => _toggleStatus(context),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleStatus(BuildContext context) async {
    final isActive = _isActive;
    final name     = academy['name'] as String? ?? '';
    final slug     = academy['slug'] as String;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(isActive ? 'Deactivate Academy' : 'Activate Academy'),
        content: Text(isActive
            ? 'Deactivate "$name"?\n\nUsers will not be able to login until reactivated.'
            : 'Activate "$name"?\n\nThe academy will immediately become operational.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: isActive ? Colors.orange : Colors.green),
              onPressed: () => Navigator.pop(context, true),
              child: Text(isActive ? 'Deactivate' : 'Activate')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    try {
      if (isActive) {
        await SuperAdminApiService.deactivateAcademy(slug);
      } else {
        await SuperAdminApiService.activateAcademy(slug);
      }
      onStatusChanged();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  String _fmtDate(dynamic raw) {
    if (raw == null) return '';
    final s = raw.toString();
    if (s.length >= 10) {
      final p = s.substring(0, 10).split('-');
      if (p.length == 3) return '${p[2]}/${p[1]}/${p[0]}';
    }
    return s;
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  const _Chip(this.icon, this.label, this.color);

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: color),
      const SizedBox(width: 3),
      Text(label,
          style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500)),
    ],
  );
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  final VoidCallback onTap;
  const _ActionBtn({required this.icon, required this.label,
      required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(6),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 12, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    ),
  );
}
