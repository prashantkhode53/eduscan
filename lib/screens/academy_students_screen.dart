import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import '../services/super_admin_api_service.dart';

class AcademyStudentsScreen extends StatefulWidget {
  final String slug;
  final String academyName;
  const AcademyStudentsScreen(
      {super.key, required this.slug, required this.academyName});

  @override
  State<AcademyStudentsScreen> createState() => _AcademyStudentsScreenState();
}

class _AcademyStudentsScreenState extends State<AcademyStudentsScreen> {
  List<Map<String, dynamic>> _students = [];
  bool   _loading   = true;
  bool   _exporting = false;
  int    _total     = 0;
  int    _page      = 1;
  String _search    = '';
  String _status    = 'active'; // active / deleted / all
  static const int _limit = 50;

  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (!mounted) return;
    if (reset) { _page = 1; _students = []; }
    setState(() => _loading = true);
    try {
      final data = await SuperAdminApiService.getAcademyStudents(
        widget.slug,
        search: _search,
        status: _status,
        page:   _page,
        limit:  _limit,
      );
      if (!mounted) return;
      setState(() {
        final rows = (data['students'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        _students = reset ? rows : [..._students, ...rows];
        _total    = data['total'] as int? ?? 0;
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

  Future<void> _export() async {
    setState(() => _exporting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final data     = await SuperAdminApiService.exportAcademyStudents(widget.slug);
      final students = (data['students'] as List? ?? [])
          .cast<Map<String, dynamic>>();

      String _q(String s) => '"${s.replaceAll('"', '""')}"';
      final headers = [
        'Student ID', 'First Name', 'Last Name', 'Mobile', 'Email',
        'Parent Name', 'Parent Mobile', 'Courses', 'Academic Year',
        'Status', 'Registration Date',
      ];
      final lines = [
        headers.map(_q).join(','),
        ...students.map((s) => [
          s['id']                ?? '',
          s['first_name']        ?? '',
          s['last_name']         ?? '',
          s['mobile']            ?? '',
          s['email']             ?? '',
          s['parent_name']       ?? '',
          s['parent_mobile']     ?? '',
          s['courses']           ?? '',
          s['academic_year']     ?? '',
          s['status']            ?? '',
          s['registration_date'] ?? '',
        ].map((v) => _q(v.toString())).join(',')),
      ];

      final dir  = await getApplicationDocumentsDirectory();
      final safe = widget.academyName.replaceAll(RegExp(r'[^\w\s]'), '').trim();
      final file = File('${dir.path}/${safe}_Students.csv');
      await file.writeAsString(lines.join('\n'));

      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Exported ${students.length} students'),
        backgroundColor: Colors.green,
        action: SnackBarAction(
            label: 'Open', onPressed: () => OpenFilex.open(file.path)),
      ));
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ));
      }
    }
    if (mounted) setState(() => _exporting = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final hasMore  = _students.length < _total;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Students', style: TextStyle(fontSize: 16)),
            Text(widget.academyName,
                style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
          ],
        ),
        actions: [
          if (_exporting)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: 'Export CSV',
              onPressed: _export,
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Search bar ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search by name, ID, or mobile…',
                prefixIcon: const Icon(Icons.search, size: 20),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                suffixIcon: _search.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _search = '');
                          _load(reset: true);
                        })
                    : null,
              ),
              onChanged: (q) {
                setState(() => _search = q);
                _load(reset: true);
              },
            ),
          ),

          // ── Status filter ──────────────────────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: ['active', 'deleted', 'all'].map((s) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  label: Text(s[0].toUpperCase() + s.substring(1)),
                  selected: _status == s,
                  onSelected: (_) {
                    setState(() => _status = s);
                    _load(reset: true);
                  },
                  visualDensity: VisualDensity.compact,
                ),
              )).toList(),
            ),
          ),

          // ── Total count ────────────────────────────────────────────────
          if (!_loading || _students.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              child: Row(children: [
                Text('$_total student${_total == 1 ? '' : 's'}',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.5))),
              ]),
            ),

          // ── Student list ───────────────────────────────────────────────
          Expanded(
            child: _loading && _students.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _students.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.person_search_outlined,
                                size: 48,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.3)),
                            const SizedBox(height: 10),
                            const Text('No students found'),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () => _load(reset: true),
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                          itemCount:
                              _students.length + (hasMore ? 1 : 0),
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 6),
                          itemBuilder: (_, i) {
                            if (i == _students.length) {
                              // Load more button
                              return Center(
                                child: _loading
                                    ? const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: CircularProgressIndicator())
                                    : TextButton(
                                        onPressed: () {
                                          _page++;
                                          _load();
                                        },
                                        child: Text(
                                            'Load more (${_total - _students.length} remaining)'),
                                      ),
                              );
                            }
                            return _StudentCard(student: _students[i]);
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

// ── Student card ───────────────────────────────────────────────────────────────

class _StudentCard extends StatelessWidget {
  final Map<String, dynamic> student;
  const _StudentCard({required this.student});

  @override
  Widget build(BuildContext context) {
    final theme     = Theme.of(context);
    final status    = student['status'] as String? ?? 'active';
    final isActive  = status == 'active';
    final isDeleted = status == 'deleted';
    final courses   = student['courses'] as String? ?? '';
    final year      = student['academic_year'] as String? ?? '';

    Color statusColor = isActive
        ? Colors.green
        : isDeleted
            ? Colors.red
            : Colors.orange;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor:
                  statusColor.withValues(alpha: 0.12),
              child: Text(
                '${(student['first_name'] as String? ?? 'S')[0]}'
                '${(student['last_name']  as String? ?? '')[0]}'
                    .toUpperCase(),
                style: TextStyle(
                    color: statusColor, fontWeight: FontWeight.bold,
                    fontSize: 13),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(
                        '${student['first_name'] ?? ''} ${student['last_name'] ?? ''}'
                            .trim(),
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(status,
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: statusColor)),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Text(student['id'] as String? ?? '',
                      style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.5),
                          fontFamily: 'monospace')),
                  const SizedBox(height: 2),
                  Text(student['mobile'] as String? ?? '',
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.65))),
                  if (courses.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(children: [
                        Icon(Icons.menu_book_outlined,
                            size: 12,
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.7)),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            courses +
                                (year.isNotEmpty ? '  ($year)' : ''),
                            style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.primary
                                    .withValues(alpha: 0.8)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ]),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
