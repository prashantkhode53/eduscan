import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/student_provider.dart';
import '../widgets/offline_banner.dart';
import '../widgets/shimmer_loader.dart';
import '../widgets/student_card.dart';

class StudentListScreen extends StatefulWidget {
  const StudentListScreen({super.key});

  @override
  State<StudentListScreen> createState() => _StudentListScreenState();
}

class _StudentListScreenState extends State<StudentListScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  String _statusFilter = 'active';
  String? _classFilter;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(refresh: true));
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      final provider = context.read<StudentProvider>();
      if (!provider.loading && provider.hasMore) {
        provider.fetchStudents(
          search: _searchCtrl.text.trim(),
          status: _statusFilter,
          classGrade: _classFilter,
        );
      }
    }
  }

  void _load({bool refresh = false}) {
    context.read<StudentProvider>().fetchStudents(
          search: _searchCtrl.text.trim(),
          status: _statusFilter,
          classGrade: _classFilter,
          refresh: refresh,
        );
  }

  void _onSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _load(refresh: true));
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<StudentProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Students'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onSearch,
              decoration: const InputDecoration(
                hintText: 'Search by name or ID...',
                prefixIcon: Icon(Icons.search),
                suffixIcon: Icon(Icons.mic_none),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final status in ['active', 'inactive', 'all'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(status[0].toUpperCase() + status.substring(1)),
                      selected: _statusFilter == status,
                      onSelected: (_) {
                        setState(() => _statusFilter = status);
                        _load(refresh: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // Show API errors prominently so auth/network issues are visible
          if (provider.error != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                border: Border.all(color: Colors.red.shade200),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red.shade700, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      provider.error!,
                      style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    color: Colors.red.shade700,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => _load(refresh: true),
                  ),
                ],
              ),
            ),
          Expanded(
            child: provider.loading && provider.students.isEmpty
                ? const ShimmerLoader()
                : provider.students.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.people_outline,
                                size: 64,
                                color:
                                    theme.colorScheme.onSurface.withValues(alpha:0.3)),
                            const SizedBox(height: 12),
                            Text(
                              provider.error != null
                                  ? 'Could not load students'
                                  : 'No students found',
                              style: TextStyle(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha:0.5))),
                            if (provider.error == null) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Tap "Register Student" to add the first student',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha:0.4)),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () => provider.fetchStudents(
                          refresh: true,
                          search: _searchCtrl.text.trim(),
                          status: _statusFilter,
                          classGrade: _classFilter,
                        ),
                        child: ListView.builder(
                          controller: _scroll,
                          itemCount: provider.students.length +
                              (provider.hasMore ? 1 : 0),
                          itemBuilder: (_, i) {
                            if (i == provider.students.length) {
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(child: CircularProgressIndicator()),
                              );
                            }
                            final student = provider.students[i];
                            return StudentCard(
                              student: student,
                              onTap: () => Navigator.pushNamed(
                                context,
                                '/students/detail',
                                arguments: student.id,
                              ).then((_) => _load(refresh: true)),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pushNamed(context, '/students/register')
            .then((_) => _load(refresh: true)),
        icon: const Icon(Icons.person_add),
        label: const Text('Register Student'),
      ),
    );
  }
}
