class ApiEndpoints {
  // ── CHANGE THIS to your Render URL after deployment ───────────────────────
  // Example: https://eduscan-backend.onrender.com
  // Do NOT use localhost or 192.168.x.x — those only work on local network.
  static const String baseUrl = 'https://eduscan-j4cg.onrender.com';
  // ──────────────────────────────────────────────────────────────────────────

  // Academy (multi-tenant)
  static const String academyRegister  = '$baseUrl/api/academy/register';
  static const String academyLogin     = '$baseUrl/api/academy/login';
  static const String academyProfile   = '$baseUrl/api/academy/profile';
  static const String academyCourses   = '$baseUrl/api/academy/courses';
  static const String academyStudents  = '$baseUrl/api/academy/students';
  static const String academyFees           = '$baseUrl/api/academy/fees';
  static const String academyAttendanceScan = '$baseUrl/api/academy/attendance/scan';

  // Auth
  static const String login            = '$baseUrl/api/auth/login';
  static const String forgotPassword   = '$baseUrl/api/auth/forgot-password';
  static const String verifyOtp        = '$baseUrl/api/auth/verify-otp';
  static const String resetPassword    = '$baseUrl/api/auth/reset-password';
  static const String changePassword   = '$baseUrl/api/auth/change-password';
  static const String health           = '$baseUrl/api/health';

  // Students
  static const String students         = '$baseUrl/api/students';
  static String studentById(String id) => '$baseUrl/api/students/$id';
  static String studentAttendance(String id) => '$baseUrl/api/students/$id/attendance';

  // Attendance
  static const String attendance            = '$baseUrl/api/attendance';
  static String attendanceById(String id)   => '$baseUrl/api/attendance/$id';
  static const String attendanceBatch       = '$baseUrl/api/attendance/batch';
  static const String attendanceBulkAbsent  = '$baseUrl/api/attendance/bulk-absent';
  static const String attendanceScan        = '$baseUrl/api/attendance/scan';

  // Reports
  static const String reportsSummary        = '$baseUrl/api/reports/summary';
  static const String reportsWeekly         = '$baseUrl/api/reports/weekly';
  static const String reportsExport         = '$baseUrl/api/reports/export';
  static const String reportsStudents       = '$baseUrl/api/reports/students';
  static const String reportsRecentActivity = '$baseUrl/api/reports/recent-activity';

  // Settings
  static const String settings       = '$baseUrl/api/settings';
  static const String regenKioskKey  = '$baseUrl/api/settings/regen-kiosk-key';
}
