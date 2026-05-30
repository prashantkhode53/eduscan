import 'package:flutter/material.dart';

/// Searchable multi-select course list used by both the Add Student
/// and Edit Student registration flows.
///
/// Manages its own search state and stable [TextEditingController] instances
/// for per-course fee overrides. All business logic lives in the parent;
/// this widget only handles display and delegates changes via callbacks.
class AcademyCourseSelector extends StatefulWidget {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> courses;
  final Map<String, double> selectedFees;
  final void Function(String courseId, double defaultFee, bool selected) onToggle;
  final void Function(String courseId, double fee) onFeeChanged;
  final VoidCallback onNext;
  final VoidCallback onRetry;
  /// Label on the CTA button. Defaults to 'Continue to Face Capture'.
  final String? nextLabel;

  const AcademyCourseSelector({
    super.key,
    required this.loading,
    this.error,
    required this.courses,
    required this.selectedFees,
    required this.onToggle,
    required this.onFeeChanged,
    required this.onNext,
    required this.onRetry,
    this.nextLabel,
  });

  @override
  State<AcademyCourseSelector> createState() => _AcademyCourseSelectorState();
}

class _AcademyCourseSelectorState extends State<AcademyCourseSelector> {
  // Stable fee controllers keyed by course ID.
  // Created when a course is first selected; disposed when deselected.
  final Map<String, TextEditingController> _ctrls = {};

  // Search
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Seed controllers for any courses already selected when the widget is
    // first built (e.g. edit flow with pre-populated enrolments).
    for (final entry in widget.selectedFees.entries) {
      _ctrls[entry.key] = TextEditingController(
          text: entry.value.toStringAsFixed(0));
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_query.isEmpty) return widget.courses;
    final q = _query.toLowerCase();
    return widget.courses.where((c) {
      final name    = (c['name']    as String? ?? '').toLowerCase();
      final subject = (c['subject'] as String? ?? '').toLowerCase();
      return name.contains(q) || subject.contains(q);
    }).toList();
  }

  String _scheduleLabel(dynamic s) {
    switch (s?.toString()) {
      case 'quarterly': return 'Quarterly';
      case 'onetime':   return 'One-time';
      default:          return 'Monthly';
    }
  }

  @override
  void didUpdateWidget(AcademyCourseSelector old) {
    super.didUpdateWidget(old);
    // Create controllers for newly selected courses
    for (final entry in widget.selectedFees.entries) {
      if (!_ctrls.containsKey(entry.key)) {
        _ctrls[entry.key] = TextEditingController(
            text: entry.value.toStringAsFixed(0));
      }
    }
    // Dispose controllers for deselected courses
    final removed = _ctrls.keys
        .where((k) => !widget.selectedFees.containsKey(k))
        .toList();
    for (final k in removed) {
      _ctrls[k]!.dispose();
      _ctrls.remove(k);
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    for (final c in _ctrls.values) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // ── Loading ──────────────────────────────────────────────────────────
    if (widget.loading) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text('Loading courses…',
              style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
        ],
      );
    }

    // ── API error ────────────────────────────────────────────────────────
    if (widget.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 56,
                  color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text('Could not load courses',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(widget.error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13,
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.6))),
              const SizedBox(height: 20),
              FilledButton.icon(
                  onPressed: widget.onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    // ── No courses in academy ────────────────────────────────────────────
    if (widget.courses.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_outlined, size: 64,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
              const SizedBox(height: 12),
              const Text('No courses available',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Create courses in Course Master first.',
                  style: TextStyle(
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.6))),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Go Back')),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                      onPressed: widget.onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh')),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // ── Searchable list ──────────────────────────────────────────────────
    final filtered = _filtered;

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search by course name or subject…',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      })
                  : null,
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerLow,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 12),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),

        // Count hint
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _query.isEmpty
                  ? '${widget.courses.length} course${widget.courses.length > 1 ? 's' : ''} available — tap to select'
                  : '${filtered.length} of ${widget.courses.length} matching',
              style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
            ),
          ),
        ),

        // Course list / no-results
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search_off_outlined,
                          size: 48,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.3)),
                      const SizedBox(height: 12),
                      Text('No courses match "$_query"',
                          style: TextStyle(
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.55))),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.clear, size: 16),
                        label: const Text('Clear search'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final c          = filtered[i];
                    final id         = c['id'] as String;
                    final defaultFee = (c['default_fee'] as num).toDouble();
                    final selected   = widget.selectedFees.containsKey(id);

                    final meta = <String>[];
                    final subj = c['subject'] as String?;
                    final dur  = c['duration_months'];
                    if (subj != null && subj.isNotEmpty) meta.add(subj);
                    if (dur != null) meta.add('$dur months');
                    meta.add(_scheduleLabel(c['schedule']));

                    return Card(
                      key: ValueKey(id),
                      margin: const EdgeInsets.only(bottom: 10),
                      elevation: selected ? 2 : 0,
                      shadowColor: selected
                          ? theme.colorScheme.primary.withValues(alpha: 0.25)
                          : null,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () =>
                            widget.onToggle(id, defaultFee, !selected),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Header: circle indicator + name + fee
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    width: 22, height: 22,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: selected
                                          ? theme.colorScheme.primary
                                          : Colors.transparent,
                                      border: Border.all(
                                        color: selected
                                            ? theme.colorScheme.primary
                                            : theme.colorScheme.outline,
                                        width: 2,
                                      ),
                                    ),
                                    child: selected
                                        ? const Icon(Icons.check,
                                            size: 13, color: Colors.white)
                                        : null,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      c['name'] as String,
                                      style: theme.textTheme.bodyLarge
                                          ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: selected
                                            ? theme.colorScheme.primary
                                            : null,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        '₹${defaultFee.toStringAsFixed(0)}',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: selected
                                              ? theme.colorScheme.primary
                                              : theme.colorScheme.onSurface,
                                        ),
                                      ),
                                      Text(
                                        _scheduleLabel(c['schedule']),
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.5)),
                                      ),
                                    ],
                                  ),
                                ],
                              ),

                              // Meta chips (subject · duration · schedule)
                              if (meta.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Padding(
                                  padding: const EdgeInsets.only(left: 34),
                                  child: Wrap(
                                    spacing: 6, runSpacing: 4,
                                    children: meta
                                        .map((m) => _CourseMeta(label: m))
                                        .toList(),
                                  ),
                                ),
                              ],

                              // Per-student fee override (when selected)
                              if (selected) ...[
                                const SizedBox(height: 12),
                                const Divider(height: 1),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Icon(Icons.payments_outlined,
                                        size: 16,
                                        color: theme.colorScheme.primary),
                                    const SizedBox(width: 8),
                                    Text('Custom fee:',
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.7))),
                                    const SizedBox(width: 10),
                                    SizedBox(
                                      width: 120,
                                      child: TextFormField(
                                        controller: _ctrls[id],
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          isDense: true,
                                          border: OutlineInputBorder(),
                                          prefixText: '₹ ',
                                          contentPadding: EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 8),
                                        ),
                                        onChanged: (v) {
                                          final fee = double.tryParse(v);
                                          if (fee != null) {
                                            widget.onFeeChanged(id, fee);
                                          }
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        'Default: ₹${defaultFee.toStringAsFixed(0)}',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.45)),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),

        // Bottom bar — selection summary + CTA
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              top: BorderSide(
                  color: theme.colorScheme.outlineVariant, width: 1),
            ),
          ),
          padding: EdgeInsets.fromLTRB(
              16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.selectedFees.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(children: [
                        Icon(Icons.check_circle,
                            size: 16, color: theme.colorScheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          '${widget.selectedFees.length} course${widget.selectedFees.length > 1 ? 's' : ''} selected',
                          style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.75)),
                        ),
                      ]),
                      Text(
                        'Total ₹${widget.selectedFees.values.fold(0.0, (a, b) => a + b).toStringAsFixed(0)}/mo',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              FilledButton.icon(
                onPressed:
                    widget.selectedFees.isEmpty ? null : widget.onNext,
                icon: const Icon(Icons.arrow_forward),
                label: Text(widget.selectedFees.isEmpty
                    ? 'Select at least one course'
                    : (widget.nextLabel ?? 'Continue to Face Capture')),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Internal helper ───────────────────────────────────────────────────────────

class _CourseMeta extends StatelessWidget {
  final String label;
  const _CourseMeta({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7))),
    );
  }
}
