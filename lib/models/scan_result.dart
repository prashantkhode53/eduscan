enum ScanAction {
  checkin,
  checkout,
  duplicate,
  unknown,
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
    required this.message,
  });

  factory ScanResult.fromJson(Map<String, dynamic> json) {
    ScanAction parseAction(String? a) {
      switch (a) {
        case 'checkin':
          return ScanAction.checkin;
        case 'checkout':
          return ScanAction.checkout;
        case 'duplicate':
          return ScanAction.duplicate;
        case 'outside_hours':
          return ScanAction.outsideHours;
        case 'already_complete':
          return ScanAction.alreadyComplete;
        case 'error':
          return ScanAction.error;
        default:
          return ScanAction.unknown;
      }
    }

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
      rollNo: student?['roll_no'] as int?,
      timeIn: json['time_in'] as String?,
      timeOut: json['time_out'] as String?,
      durationMins: json['duration_mins'] as int?,
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
