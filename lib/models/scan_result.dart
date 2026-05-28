enum ScanAction {
  checkin,
  checkout,
  duplicate,
  unknown,
  ambiguous,  // two students have nearly identical embeddings — admin must clean up
  error,
  outsideHours,
  alreadyComplete,
}

class ScanResult {
  final bool success;
  final ScanAction action;
  final String? studentId;
  final String? studentName;
  final String? classGrade;
  final String? division;
  final int? rollNo;
  final String? timeIn;
  final String? timeOut;
  final int? durationMins;
  final double? confidence;
  final String message;

  const ScanResult({
    required this.success,
    required this.action,
    this.studentId,
    this.studentName,
    this.classGrade,
    this.division,
    this.rollNo,
    this.timeIn,
    this.timeOut,
    this.durationMins,
    this.confidence,
    required this.message,
  });

  factory ScanResult.fromJson(Map<String, dynamic> json) {
    ScanAction parseAction(String? a) => switch (a) {
      'checkin'          => ScanAction.checkin,
      'checkout'         => ScanAction.checkout,
      'duplicate'        => ScanAction.duplicate,
      'ambiguous'        => ScanAction.ambiguous,
      'outside_hours'    => ScanAction.outsideHours,
      'already_complete' => ScanAction.alreadyComplete,
      'error'            => ScanAction.error,
      _                  => ScanAction.unknown,
    };

    final student = json['student'] as Map<String, dynamic>?;
    return ScanResult(
      success: json['success'] as bool? ?? false,
      action: parseAction(json['action'] as String?),
      studentId: student?['id'] as String?,
      studentName: student != null
          ? '${student['first_name'] ?? ''} ${student['last_name'] ?? ''}'.trim()
          : null,
      classGrade: student?['class_grade'] as String?,
      division: student?['division'] as String?,
      rollNo: (student?['roll_no'] as num?)?.toInt(),
      timeIn: json['time_in'] as String?,
      timeOut: json['time_out'] as String?,
      durationMins: (json['duration_mins'] as num?)?.toInt(),
      confidence: (json['confidence'] as num?)?.toDouble(),
      message: json['message'] as String? ?? '',
    );
  }

  String get durationLabel {
    if (durationMins == null || durationMins! <= 0) return '';
    final h = durationMins! ~/ 60;
    final m = durationMins! % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
}
