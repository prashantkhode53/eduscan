class Admin {
  final String id;
  final String username;
  final String email;
  final String? fullName;
  final String role;
  final bool isLocked;
  final String? lastLogin;
  final String createdAt;

  const Admin({
    required this.id,
    required this.username,
    required this.email,
    this.fullName,
    required this.role,
    required this.isLocked,
    this.lastLogin,
    required this.createdAt,
  });

  factory Admin.fromJson(Map<String, dynamic> json) {
    return Admin(
      id: json['id'] as String,
      username: json['username'] as String,
      email: json['email'] as String,
      fullName: json['full_name'] as String?,
      role: json['role'] as String? ?? 'admin',
      isLocked: json['is_locked'] as bool? ?? false,
      lastLogin: json['last_login'] as String?,
      createdAt: json['created_at'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'email': email,
        'full_name': fullName,
        'role': role,
        'is_locked': isLocked,
        'last_login': lastLogin,
        'created_at': createdAt,
      };

  String get displayName => fullName?.isNotEmpty == true ? fullName! : username;

  String get initials {
    if (fullName != null && fullName!.isNotEmpty) {
      final parts = fullName!.trim().split(' ');
      if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
      return parts[0][0].toUpperCase();
    }
    return username[0].toUpperCase();
  }
}

class LoginRequest {
  final String username;
  final String password;

  const LoginRequest({required this.username, required this.password});

  Map<String, dynamic> toJson() => {'username': username, 'password': password};
}
