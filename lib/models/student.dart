class Student {
  final String id;
  final String firstName;
  final String? middleName;
  final String lastName;
  final String dob;
  final String gender;
  final String? bloodGroup;
  final String? nationality;
  final String? govtId;
  final String institution;
  final String academicYear;
  final String classGrade;
  final String division;
  final int? rollNo;
  final String? stream;
  final String admissionDate;
  final String parentName;
  final String? parentRelation;
  final String mobile;
  final String? email;
  final String? address;
  final String? knownAllergies;
  final String? medicalConditions;
  final String? emergencyContact;
  final String? transportRoute;
  final List<double> faceEmbedding;
  final double? faceQuality;
  final String status;
  final String? createdAt;
  final String? updatedAt;

  const Student({
    required this.id,
    required this.firstName,
    this.middleName,
    required this.lastName,
    required this.dob,
    required this.gender,
    this.bloodGroup,
    this.nationality,
    this.govtId,
    required this.institution,
    required this.academicYear,
    required this.classGrade,
    required this.division,
    this.rollNo,
    this.stream,
    required this.admissionDate,
    required this.parentName,
    this.parentRelation,
    required this.mobile,
    this.email,
    this.address,
    this.knownAllergies,
    this.medicalConditions,
    this.emergencyContact,
    this.transportRoute,
    required this.faceEmbedding,
    this.faceQuality,
    required this.status,
    this.createdAt,
    this.updatedAt,
  });

  factory Student.fromJson(Map<String, dynamic> json) {
    List<double> parseEmbedding(dynamic raw) {
      if (raw == null) return [];
      if (raw is List) return raw.map((e) => (e as num).toDouble()).toList();
      return [];
    }

    // node-postgres returns DECIMAL/NUMERIC as strings; parse defensively
    double? parseDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    // node-postgres returns INT as num, but guard against string just in case
    int? parseInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    // node-postgres returns DATE as ISO string or DateTime; take date part only
    String parseDate(dynamic v) {
      if (v == null) return '';
      final s = v.toString();
      return s.length >= 10 ? s.substring(0, 10) : s;
    }

    return Student(
      id: json['id'] as String,
      firstName: json['first_name'] as String,
      middleName: json['middle_name'] as String?,
      lastName: json['last_name'] as String,
      dob: parseDate(json['dob']),
      gender: json['gender'] as String,
      bloodGroup: json['blood_group'] as String?,
      nationality: json['nationality'] as String?,
      govtId: json['govt_id'] as String?,
      institution: json['institution'] as String,
      academicYear: json['academic_year'] as String,
      classGrade: json['class_grade'] as String,
      division: json['division'] as String,
      rollNo: parseInt(json['roll_no']),
      stream: json['stream'] as String?,
      admissionDate: parseDate(json['admission_date']),
      parentName: json['parent_name'] as String,
      parentRelation: json['parent_relation'] as String?,
      mobile: json['mobile'] as String,
      email: json['email'] as String?,
      address: json['address'] as String?,
      knownAllergies: json['known_allergies'] as String?,
      medicalConditions: json['medical_conditions'] as String?,
      emergencyContact: json['emergency_contact'] as String?,
      transportRoute: json['transport_route'] as String?,
      faceEmbedding: parseEmbedding(json['face_embedding']),
      faceQuality: parseDouble(json['face_quality']),
      status: json['status'] as String? ?? 'active',
      createdAt: json['created_at'] as String?,
      updatedAt: json['updated_at'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'first_name': firstName,
        'middle_name': middleName,
        'last_name': lastName,
        'dob': dob,
        'gender': gender,
        'blood_group': bloodGroup,
        'nationality': nationality,
        'govt_id': govtId,
        'institution': institution,
        'academic_year': academicYear,
        'class_grade': classGrade,
        'division': division,
        'roll_no': rollNo,
        'stream': stream,
        'admission_date': admissionDate,
        'parent_name': parentName,
        'parent_relation': parentRelation,
        'mobile': mobile,
        'email': email,
        'address': address,
        'known_allergies': knownAllergies,
        'medical_conditions': medicalConditions,
        'emergency_contact': emergencyContact,
        'transport_route': transportRoute,
        'face_embedding': faceEmbedding,
        'face_quality': faceQuality,
        'status': status,
      };

  String get fullName => [firstName, middleName, lastName]
      .where((p) => p != null && p.isNotEmpty)
      .join(' ');

  String get classLabel => '$classGrade-$division';

  String get initials {
    final f = firstName.isNotEmpty ? firstName[0] : '';
    final l = lastName.isNotEmpty ? lastName[0] : '';
    return '$f$l'.toUpperCase();
  }
}

class StudentRegistration {
  final String firstName;
  final String? middleName;
  final String lastName;
  final String dob;
  final String gender;
  final String? bloodGroup;
  final String? nationality;
  final String? govtId;
  final String institution;
  final String academicYear;
  final String classGrade;
  final String division;
  final int? rollNo;
  final String? stream;
  final String admissionDate;
  final String parentName;
  final String? parentRelation;
  final String mobile;
  final String? email;
  final String? address;
  final String? knownAllergies;
  final String? medicalConditions;
  final String? emergencyContact;
  final String? transportRoute;
  final List<double> faceEmbedding;
  final double? faceQuality;

  const StudentRegistration({
    required this.firstName,
    this.middleName,
    required this.lastName,
    required this.dob,
    required this.gender,
    this.bloodGroup,
    this.nationality,
    this.govtId,
    required this.institution,
    required this.academicYear,
    required this.classGrade,
    required this.division,
    this.rollNo,
    this.stream,
    required this.admissionDate,
    required this.parentName,
    this.parentRelation,
    required this.mobile,
    this.email,
    this.address,
    this.knownAllergies,
    this.medicalConditions,
    this.emergencyContact,
    this.transportRoute,
    required this.faceEmbedding,
    this.faceQuality,
  });

  Map<String, dynamic> toJson() => {
        'first_name': firstName,
        'middle_name': middleName,
        'last_name': lastName,
        'dob': dob,
        'gender': gender,
        'blood_group': bloodGroup,
        'nationality': nationality,
        'govt_id': govtId,
        'institution': institution,
        'academic_year': academicYear,
        'class_grade': classGrade,
        'division': division,
        'roll_no': rollNo,
        'stream': stream,
        'admission_date': admissionDate,
        'parent_name': parentName,
        'parent_relation': parentRelation,
        'mobile': mobile,
        'email': email,
        'address': address,
        'known_allergies': knownAllergies,
        'medical_conditions': medicalConditions,
        'emergency_contact': emergencyContact,
        'transport_route': transportRoute,
        'face_embedding': faceEmbedding,
        'face_quality': faceQuality,
      };
}
