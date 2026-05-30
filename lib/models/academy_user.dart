class AcademyUser {
  final String userId;
  final String academyId;
  final String academySlug;
  final String academyName;
  final String role; // admin | teacher | student | parent
  final String name;
  final String email;
  final String? avatarUrl;

  const AcademyUser({
    required this.userId,
    required this.academyId,
    required this.academySlug,
    required this.academyName,
    required this.role,
    required this.name,
    required this.email,
    this.avatarUrl,
  });

  factory AcademyUser.fromJson(Map<String, dynamic> json) => AcademyUser(
        userId:      json['userId']      as String? ?? json['user_id']      as String,
        academyId:   json['academyId']   as String? ?? json['academy_id']   as String,
        academySlug: json['academySlug'] as String? ?? json['academy_slug'] as String? ?? '',
        academyName: json['academyName'] as String? ?? json['academy_name'] as String,
        role:        json['role']        as String,
        name:        json['name']        as String,
        email:       json['email']       as String,
        avatarUrl:   json['avatarUrl']   as String? ?? json['avatar_url']   as String?,
      );

  Map<String, dynamic> toJson() => {
        'userId':      userId,
        'academyId':   academyId,
        'academySlug': academySlug,
        'academyName': academyName,
        'role':        role,
        'name':        name,
        'email':       email,
        if (avatarUrl != null) 'avatarUrl': avatarUrl,
      };

  String get initials {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : 'U';
  }

  bool get isAdmin   => role == 'admin';
  bool get isTeacher => role == 'teacher';
  bool get isStudent => role == 'student';
  bool get isParent  => role == 'parent';
}
