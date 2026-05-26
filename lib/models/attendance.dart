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
    String s(String key, [String fallback = '']) =>
        (json[key] as String?) ?? fallback;

    int? safeInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    double? safeDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    // DATE columns from pg come as ISO strings; take only the date part
    String safeDate(dynamic v) {
      if (v == null) return '';
      final str = v.toString();
      return str.length >= 10 ? str.substring(0, 10) : str;
    }

    return Attendance(
      id: s('id'),
      studentId: s('student_id'),
      date: safeDate(json['date']),
      timeIn: json['time_in'] as String?,
      timeOut: json['time_out'] as String?,
      durationMins: safeInt(json['duration_mins']),
      status: s('status', 'absent'),
      checkinMode: s('checkin_mode', 'face_auto'),
      checkoutMode: s('checkout_mode', 'not_recorded'),
      confidenceIn: safeDouble(json['confidence_in']),
      confidenceOut: safeDouble(json['confidence_out']),
      remarks: json['remarks'] as String?,
      markedBy: json['marked_by'] as String?,
      createdAt: json['created_at'] as String?,
      firstName: json['first_name'] as String?,
      lastName: json['last_name'] as String?,
      classGrade: json['class_grade'] as String?,
      division: json['division'] as String?,
      rollNo: safeInt(json['roll_no']),
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
      [firstName, lastName].where((p) => p != null && p.isNotEmpty).join(' ');

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
