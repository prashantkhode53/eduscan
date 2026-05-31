class ParentUser {
  final String studentId;
  final String studentFirstName;
  final String studentLastName;
  final String parentName;
  final String academySlug;
  final String academyName;

  const ParentUser({
    required this.studentId,
    required this.studentFirstName,
    required this.studentLastName,
    required this.parentName,
    required this.academySlug,
    required this.academyName,
  });

  String get studentFullName => '$studentFirstName $studentLastName'.trim();

  factory ParentUser.fromJson(Map<String, dynamic> json) => ParentUser(
        studentId:         json['studentId']         as String? ?? '',
        studentFirstName:  json['studentFirstName']  as String? ?? '',
        studentLastName:   json['studentLastName']   as String? ?? '',
        parentName:        json['parentName']        as String? ?? '',
        academySlug:       json['academySlug']       as String? ?? '',
        academyName:       json['academyName']       as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'studentId':        studentId,
        'studentFirstName': studentFirstName,
        'studentLastName':  studentLastName,
        'parentName':       parentName,
        'academySlug':      academySlug,
        'academyName':      academyName,
      };
}
