import 'package:flutter/material.dart';

/// A compact Academic Year dropdown shown at the top of the Courses step in the
/// student Registration and Edit flows. It is used ONLY to filter the available
/// course list — it does not change any other behaviour.
///
/// [years] are the active academic-year maps from the API
/// (`{id, academic_year_name, is_current_year, ...}`). [selectedId] is the
/// currently chosen year (null = none chosen yet). [onChanged] fires when the
/// admin picks a different year.
class AcademicYearFilter extends StatelessWidget {
  final List<Map<String, dynamic>> years;
  final bool loading;
  final String? selectedId;
  final ValueChanged<String?> onChanged;

  const AcademicYearFilter({
    super.key,
    required this.years,
    required this.loading,
    required this.selectedId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Icon(Icons.calendar_today_outlined,
              size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: loading
                ? const SizedBox(
                    height: 24,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  )
                : DropdownButtonFormField<String>(
                    value: selectedId,
                    isExpanded: true,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Academic Year',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    hint: const Text('Select academic year'),
                    items: years
                        .map((y) => DropdownMenuItem<String>(
                              value: y['id'] as String?,
                              child: Text(
                                '${y['academic_year_name'] ?? ''}'
                                '${y['is_current_year'] == true ? '  (Current)' : ''}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: onChanged,
                  ),
          ),
        ],
      ),
    );
  }
}
