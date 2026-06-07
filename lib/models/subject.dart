class Subject {
  final String id;
  final String courseId;
  final String name;
  final double defaultFee;
  final bool isActive;

  const Subject({
    required this.id,
    required this.courseId,
    required this.name,
    required this.defaultFee,
    this.isActive = true,
  });

  factory Subject.fromJson(Map<String, dynamic> json) {
    double parseFee(dynamic v) {
      if (v == null) return 0.0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0.0;
    }

    return Subject(
      id:         json['id']          as String? ?? '',
      courseId:   json['course_id']   as String? ?? '',
      name:       json['name']        as String? ?? '',
      defaultFee: parseFee(json['default_fee']),
      isActive:   json['is_active']   as bool?   ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id':          id,
    'course_id':   courseId,
    'name':        name,
    'default_fee': defaultFee,
    'is_active':   isActive,
  };
}

/// An enrolled subject as returned by GET /students/:id (enrolled_subjects array).
class EnrolledSubject {
  final String subjectId;
  final String subjectName;
  final String courseId;
  final String courseName;
  final double feeAmount;
  final String status;

  const EnrolledSubject({
    required this.subjectId,
    required this.subjectName,
    required this.courseId,
    required this.courseName,
    required this.feeAmount,
    this.status = 'active',
  });

  factory EnrolledSubject.fromJson(Map<String, dynamic> json) {
    double parseFee(dynamic v) {
      if (v == null) return 0.0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0.0;
    }

    return EnrolledSubject(
      subjectId:   json['subject_id']   as String? ?? '',
      subjectName: json['subject_name'] as String? ?? '',
      courseId:    json['course_id']    as String? ?? '',
      courseName:  json['course_name']  as String? ?? '',
      feeAmount:   parseFee(json['fee_amount']),
      status:      json['status']       as String? ?? 'active',
    );
  }
}
