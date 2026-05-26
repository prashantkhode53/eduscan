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
    // All string helpers guard against null — the list endpoint returns a
    // subset of columns; the detail endpoint returns all. Both shapes work.
    String s(String key, [String fallback = '']) =>
        (json[key] as String?) ?? fallback;

    List<double> parseEmbedding(dynamic raw) {
      if (raw == null) return [];
      if (raw is List) {
        return raw.map((e) {
          if (e is num) return e.toDouble();
          return double.tryParse(e.toString()) ?? 0.0;
        }).toList();
      }
      if (raw is String) {
        try {
          // JSONB returned as string from some DB drivers
          return (raw
                  .replaceAll('[', '')
                  .replaceAll(']', '')
                  .split(','))
              .map((e) => double.tryParse(e.trim()) ?? 0.0)
              .toList();
        } catch (_) {
          return [];
        }
      }
      return [];
    }

    double? parseDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    int? parseInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    // node-postgres returns DATE as an ISO string; strip time component
    String parseDate(dynamic v) {
      if (v == null) return '';
      final str = v.toString();
      return str.length >= 10 ? str.substring(0, 10) : str;
    }

    return Student(
      id: s('id'),
      firstName: s('first_name'),
      middleName: json['middle_name'] as String?,
      lastName: s('last_name'),
      dob: parseDate(json['dob']),
      gender: s('gender'),
      bloodGroup: json['blood_group'] as String?,
      nationality: json['nationality'] as String?,
      govtId: json['govt_id'] as String?,
      institution: s('institution'),
      academicYear: s('academic_year'),
      classGrade: s('class_grade'),
      division: s('division'),
      rollNo: parseInt(json['roll_no']),
      stream: json['stream'] as String?,
      admissionDate: parseDate(json['admission_date']),
      parentName: s('parent_name'),
      parentRelation: json['parent_relation'] as String?,
      mobile: s('mobile'),
      email: json['email'] as String?,
      address: json['address'] as String?,
      knownAllergies: json['known_allergies'] as String?,
      medicalConditions: json['medical_conditions'] as String?,
      emergencyContact: json['emergency_contact'] as String?,
      transportRoute: json['transport_route'] as String?,
      faceEmbedding: parseEmbedding(json['face_embedding']),
      faceQuality: parseDouble(json['face_quality']),
      status: s('status', 'active'),
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
    final f = firstName.isNotEmpty ? firstName[0] : '?';
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
