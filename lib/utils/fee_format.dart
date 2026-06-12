/// Shared formatting helpers for the Fees Management surfaces so course +
/// enrolled-subject display is identical everywhere (All / Pending / Overdue /
/// Partial / Receipts / Student Fee Details / Collection / Payment History /
/// Reports / Parent view).

/// Formats a course with its enrolled subjects, e.g. "NEET (Math, Physics)".
/// Falls back gracefully when subjects or the course name are missing.
String courseWithSubjects(String? courseName, String? subjectNames) {
  final course = (courseName ?? '').trim();
  final subjects = (subjectNames ?? '').trim();
  if (course.isEmpty) return subjects.isEmpty ? 'Course' : subjects;
  if (subjects.isEmpty) return course;
  return '$course ($subjects)';
}

/// Reads the enrolled-subject names from a fee/record/receipt map, tolerating
/// either the aggregated `subject_names` string ("Math, Physics") or a
/// `subjects` breakdown array of {name, fee} objects.
String? subjectNamesOf(Map<String, dynamic> m) {
  final agg = (m['subject_names'] as String?)?.trim();
  if (agg != null && agg.isNotEmpty) return agg;
  final list = m['subjects'];
  if (list is List && list.isNotEmpty) {
    final names = list
        .map((e) => e is Map ? (e['name']?.toString() ?? '') : e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    if (names.isNotEmpty) return names.join(', ');
  }
  return null;
}

/// Convenience: "Course (Subjects)" straight from a record map.
String courseLabelOf(Map<String, dynamic> m) =>
    courseWithSubjects(m['course_name'] as String?, subjectNamesOf(m));
