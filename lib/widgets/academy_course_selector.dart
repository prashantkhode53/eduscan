import 'package:flutter/material.dart';

/// Two-level multi-select widget: Course (expandable) → Subjects (checkboxes with fee override).
///
/// The parent screen manages:
///   - [courses]              — available courses loaded for the selected academic year
///   - [subjectsByCourse]     — subjects per course (populated lazily on expand)
///   - [selectedSubjectFees]  — currently selected subjects mapped to their fee
///   - [expandedCourses]      — which course cards are open
///   - [subjectsLoadingFor]   — course IDs whose subjects are loading
///   - [subjectsError]        — course IDs that failed to load subjects
///
/// Callbacks fire upward; this widget has no business logic.
class AcademyCourseSelector extends StatefulWidget {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> courses;

  /// subjects keyed by course ID, populated after the course is expanded
  final Map<String, List<Map<String, dynamic>>> subjectsByCourse;

  /// selected subject IDs → custom fee amount
  final Map<String, double> selectedSubjectFees;

  /// which course cards are expanded
  final Set<String> expandedCourses;

  /// course IDs whose subjects are currently loading
  final Set<String> subjectsLoadingFor;

  /// course IDs that had a subject-load error (value = error message)
  final Map<String, String> subjectsError;

  final void Function(String courseId) onCourseExpand;
  final void Function(String subjectId, double defaultFee, bool selected) onSubjectToggle;
  final void Function(String subjectId, double fee) onSubjectFeeChanged;
  final VoidCallback onNext;
  final VoidCallback onRetry;
  final String? nextLabel;

  /// Subject IDs that are permanently enrolled and cannot be deselected.
  final Set<String> lockedSubjectIds;

  const AcademyCourseSelector({
    super.key,
    required this.loading,
    this.error,
    required this.courses,
    required this.subjectsByCourse,
    required this.selectedSubjectFees,
    required this.expandedCourses,
    required this.subjectsLoadingFor,
    required this.subjectsError,
    required this.onCourseExpand,
    required this.onSubjectToggle,
    required this.onSubjectFeeChanged,
    required this.onNext,
    required this.onRetry,
    this.nextLabel,
    this.lockedSubjectIds = const {},
  });

  @override
  State<AcademyCourseSelector> createState() => _AcademyCourseSelectorState();
}

class _AcademyCourseSelectorState extends State<AcademyCourseSelector> {
  // Stable fee controllers keyed by subject ID.
  final Map<String, TextEditingController> _ctrls = {};

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _seedControllers();
  }

  void _seedControllers() {
    for (final entry in widget.selectedSubjectFees.entries) {
      if (!_ctrls.containsKey(entry.key)) {
        _ctrls[entry.key] =
            TextEditingController(text: entry.value.toStringAsFixed(0));
      }
    }
  }

  @override
  void didUpdateWidget(AcademyCourseSelector old) {
    super.didUpdateWidget(old);
    _seedControllers();
    final removed = _ctrls.keys
        .where((k) => !widget.selectedSubjectFees.containsKey(k))
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

  List<Map<String, dynamic>> get _filtered {
    if (_query.isEmpty) return widget.courses;
    final q = _query.toLowerCase();
    return widget.courses.where((c) {
      final name = (c['name'] as String? ?? '').toLowerCase();
      return name.contains(q);
    }).toList();
  }

  // true if at least one subject from this course is selected
  bool _courseHasSelection(String courseId) {
    final subjects = widget.subjectsByCourse[courseId] ?? [];
    return subjects.any((s) =>
        widget.selectedSubjectFees.containsKey(s['id'] as String? ?? ''));
  }

  int _courseSelectedCount(String courseId) {
    final subjects = widget.subjectsByCourse[courseId] ?? [];
    return subjects
        .where((s) =>
            widget.selectedSubjectFees.containsKey(s['id'] as String? ?? ''))
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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

    if (widget.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 56, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text('Could not load courses',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(widget.error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.6))),
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

    if (widget.courses.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_outlined,
                  size: 64,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
              const SizedBox(height: 12),
              const Text('No courses available',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Create courses in Course Master first.',
                  style: TextStyle(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.6))),
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

    final filtered = _filtered;
    final totalSelected = widget.selectedSubjectFees.length;
    final totalFee = widget.selectedSubjectFees.values
        .fold(0.0, (a, b) => a + b);

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search courses…',
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
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _query.isEmpty
                  ? '${widget.courses.length} course${widget.courses.length > 1 ? 's' : ''} — tap to expand & select subjects'
                  : '${filtered.length} of ${widget.courses.length} matching',
              style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
            ),
          ),
        ),

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
                  itemBuilder: (_, i) => _CourseCard(
                    course: filtered[i],
                    subjects:
                        widget.subjectsByCourse[filtered[i]['id'] as String] ??
                            [],
                    isExpanded: widget.expandedCourses
                        .contains(filtered[i]['id'] as String),
                    isLoadingSubjects: widget.subjectsLoadingFor
                        .contains(filtered[i]['id'] as String),
                    subjectsError: widget.subjectsError[filtered[i]['id'] as String],
                    hasSelection: _courseHasSelection(filtered[i]['id'] as String),
                    selectedCount: _courseSelectedCount(filtered[i]['id'] as String),
                    selectedSubjectFees: widget.selectedSubjectFees,
                    feeControllers: _ctrls,
                    lockedSubjectIds: widget.lockedSubjectIds,
                    onExpand: () =>
                        widget.onCourseExpand(filtered[i]['id'] as String),
                    onSubjectToggle: widget.onSubjectToggle,
                    onSubjectFeeChanged: widget.onSubjectFeeChanged,
                  ),
                ),
        ),

        // Bottom bar
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
              if (totalSelected > 0)
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
                          '$totalSelected subject${totalSelected > 1 ? 's' : ''} selected',
                          style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.75)),
                        ),
                      ]),
                      Text(
                        'Total ₹${totalFee.toStringAsFixed(0)}/mo',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              FilledButton.icon(
                onPressed: totalSelected == 0 ? null : widget.onNext,
                icon: const Icon(Icons.arrow_forward),
                label: Text(totalSelected == 0
                    ? 'Select at least one subject'
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

// ── Course card with expandable subject list ───────────────────────────────────

class _CourseCard extends StatelessWidget {
  final Map<String, dynamic> course;
  final List<Map<String, dynamic>> subjects;
  final bool isExpanded;
  final bool isLoadingSubjects;
  final String? subjectsError;
  final bool hasSelection;
  final int selectedCount;
  final Map<String, double> selectedSubjectFees;
  final Map<String, TextEditingController> feeControllers;
  final Set<String> lockedSubjectIds;
  final VoidCallback onExpand;
  final void Function(String subjectId, double defaultFee, bool selected) onSubjectToggle;
  final void Function(String subjectId, double fee) onSubjectFeeChanged;

  const _CourseCard({
    required this.course,
    required this.subjects,
    required this.isExpanded,
    required this.isLoadingSubjects,
    required this.subjectsError,
    required this.hasSelection,
    required this.selectedCount,
    required this.selectedSubjectFees,
    required this.feeControllers,
    this.lockedSubjectIds = const {},
    required this.onExpand,
    required this.onSubjectToggle,
    required this.onSubjectFeeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final courseId = course['id'] as String;

    return Card(
      key: ValueKey(courseId),
      margin: const EdgeInsets.only(bottom: 10),
      elevation: hasSelection ? 2 : 0,
      shadowColor: hasSelection
          ? theme.colorScheme.primary.withValues(alpha: 0.25)
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: hasSelection
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: hasSelection ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Course header row (always visible) ──────────────────────────
          InkWell(
            borderRadius: isExpanded
                ? const BorderRadius.vertical(top: Radius.circular(13))
                : BorderRadius.circular(13),
            onTap: onExpand,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  // Selection dot
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 22, height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: hasSelection
                          ? theme.colorScheme.primary
                          : Colors.transparent,
                      border: Border.all(
                        color: hasSelection
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                        width: 2,
                      ),
                    ),
                    child: hasSelection
                        ? Center(
                            child: Text(
                              selectedCount > 9 ? '9+' : '$selectedCount',
                              style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            ))
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          course['name'] as String? ?? '',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: hasSelection
                                ? theme.colorScheme.primary
                                : null,
                          ),
                        ),
                        if (hasSelection)
                          Text(
                            '$selectedCount subject${selectedCount > 1 ? 's' : ''} selected',
                            style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.primary
                                    .withValues(alpha: 0.75)),
                          ),
                      ],
                    ),
                  ),
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color:
                        theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ],
              ),
            ),
          ),

          // ── Expandable subject list ──────────────────────────────────────
          if (isExpanded) ...[
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            if (isLoadingSubjects)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (subjectsError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text('Could not load subjects: $subjectsError',
                        style: TextStyle(
                            color: theme.colorScheme.error, fontSize: 13)),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: onExpand,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              )
            else if (subjects.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No subjects configured. Add subjects in Course Master.',
                  style: TextStyle(
                      fontSize: 13,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                child: Column(
                  children: subjects.map((sub) {
                    final subId = sub['id'] as String;
                    final defaultFee = double.tryParse(
                            sub['default_fee']?.toString() ?? '0') ??
                        0.0;
                    final isSelected = selectedSubjectFees.containsKey(subId);

                    final isLocked = lockedSubjectIds.contains(subId);
                    return _SubjectRow(
                      subject: sub,
                      isSelected: isSelected,
                      isLocked: isLocked,
                      defaultFee: defaultFee,
                      feeController: feeControllers[subId],
                      onToggle: (selected) =>
                          onSubjectToggle(subId, defaultFee, selected),
                      onFeeChanged: (fee) => onSubjectFeeChanged(subId, fee),
                    );
                  }).toList(),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ── Individual subject row (checkbox + fee override) ──────────────────────────

class _SubjectRow extends StatelessWidget {
  final Map<String, dynamic> subject;
  final bool isSelected;
  final bool isLocked;
  final double defaultFee;
  final TextEditingController? feeController;
  final void Function(bool selected) onToggle;
  final void Function(double fee) onFeeChanged;

  const _SubjectRow({
    required this.subject,
    required this.isSelected,
    this.isLocked = false,
    required this.defaultFee,
    required this.feeController,
    required this.onToggle,
    required this.onFeeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Checkbox (always interactive — enrolled subjects show confirmation dialog in parent)
          SizedBox(
            width: 24, height: 24,
            child: Checkbox(
              value: isSelected,
              onChanged: (v) => onToggle(v ?? false),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 10),

          // Subject name + "Enrolled" badge for already-enrolled subjects
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    subject['name'] as String? ?? '',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      color: isSelected ? theme.colorScheme.primary : null,
                    ),
                  ),
                ),
                if (isLocked)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    margin: const EdgeInsets.only(left: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Enrolled',
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Fee: read-only badge for locked enrolled subjects; editable for new selections
          if (!isSelected)
            Text(
              '₹${defaultFee.toStringAsFixed(0)}',
              style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
            )
          else if (isLocked)
            GestureDetector(
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Subject fee cannot be modified — already assigned to this student.',
                  ),
                  duration: Duration(seconds: 3),
                ),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: theme.colorScheme.outline.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '₹${(double.tryParse(feeController?.text ?? '') ?? defaultFee).toStringAsFixed(0)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.lock_outline,
                        size: 12,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
                  ],
                ),
              ),
            )
          else ...[
            SizedBox(
              width: 100,
              child: TextFormField(
                controller: feeController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  prefixText: '₹ ',
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (v) {
                  final fee = double.tryParse(v);
                  if (fee != null) onFeeChanged(fee);
                },
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '(def: ₹${defaultFee.toStringAsFixed(0)})',
              style: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
            ),
          ],
        ],
      ),
    );
  }
}

