class Attendance {
  final String id;
  final String studentId;
  final String date;
  final String? timeIn;
  final String? timeOut;
  final int? durationMins;
  final String status;
  final String checkinMode;
  final String checkoutMode;
  final double? confidenceIn;
  final double? confidenceOut;
  final String? remarks;
  final String? markedBy;
  final String? createdAt;
  // Joined fields
  final String? firstName;
  final String? lastName;
  final String? classGrade;
  final String? division;
  final int? rollNo;

  const Attendance({
    required this.id,
    required this.studentId,
    required this.date,
    this.timeIn,
    this.timeOut,
    this.durationMins,
    required this.status,
    required this.checkinMode,
    required this.checkoutMode,
    this.confidenceIn,
    this.confidenceOut,
    this.remarks,
    this.markedBy,
    this.createdAt,
    this.firstName,
    this.lastName,
    this.classGrade,
    this.division,
    this.rollNo,
  });

  factory Attendance.fromJson(Map<String, dynamic> json) {
    return Attendance(
      id: json['id'] as String,
      studentId: json['student_id'] as String,
      date: json['date'] as String,
      timeIn: json['time_in'] as String?,
      timeOut: json['time_out'] as String?,
      durationMins: json['duration_mins'] as int?,
      status: json['status'] as String? ?? 'absent',
      checkinMode: json['checkin_mode'] as String? ?? 'face_auto',
      checkoutMode: json['checkout_mode'] as String? ?? 'not_recorded',
      confidenceIn: (json['confidence_in'] as num?)?.toDouble(),
      confidenceOut: (json['confidence_out'] as num?)?.toDouble(),
      remarks: json['remarks'] as String?,
      markedBy: json['marked_by'] as String?,
      createdAt: json['created_at'] as String?,
      firstName: json['first_name'] as String?,
      lastName: json['last_name'] as String?,
      classGrade: json['class_grade'] as String?,
      division: json['division'] as String?,
      rollNo: json['roll_no'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'student_id': studentId,
        'date': date,
        'time_in': timeIn,
        'time_out': timeOut,
        'duration_mins': durationMins,
        'status': status,
        'checkin_mode': checkinMode,
        'checkout_mode': checkoutMode,
        'confidence_in': confidenceIn,
        'confidence_out': confidenceOut,
        'remarks': remarks,
      };

  String get studentFullName =>
      [firstName, lastName].where((p) => p != null && p!.isNotEmpty).join(' ');

  String get durationLabel {
    if (durationMins == null || durationMins! <= 0) return '-';
    final h = durationMins! ~/ 60;
    final m = durationMins! % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
}

class AttendanceSummary {
  final int totalDays;
  final int presentDays;
  final int absentDays;
  final int lateDays;
  final double percentage;

  const AttendanceSummary({
    required this.totalDays,
    required this.presentDays,
    required this.absentDays,
    required this.lateDays,
    required this.percentage,
  });

  factory AttendanceSummary.fromJson(Map<String, dynamic> json) {
    return AttendanceSummary(
      totalDays: (json['total_days'] as num?)?.toInt() ?? 0,
      presentDays: (json['present_days'] as num?)?.toInt() ?? 0,
      absentDays: (json['absent_days'] as num?)?.toInt() ?? 0,
      lateDays: (json['late_days'] as num?)?.toInt() ?? 0,
      percentage: (json['percentage'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
