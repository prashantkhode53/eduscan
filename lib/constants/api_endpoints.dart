class ApiEndpoints {
  // ── Backend URL is chosen at BUILD/RUN time, not hardcoded ────────────────
  // Pass it with:  --dart-define-from-file=dev.json   (dev/staging backend)
  //           or:  --dart-define-from-file=prod.json  (production backend)
  // If no flag is passed, it defaults to PRODUCTION (Hetzner) below, so a
  // plain `flutter build apk --release` is always safe.
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://167.233.94.60:3000', // production (Hetzner)
  );
  // ──────────────────────────────────────────────────────────────────────────

  // Academy (multi-tenant)
  static const String academyRegister  = '$baseUrl/api/academy/register';
  static const String academyLogin     = '$baseUrl/api/academy/login';
  static const String academyProfile   = '$baseUrl/api/academy/profile';
  static const String academyCourses   = '$baseUrl/api/academy/courses';
  static String academySubjects(String courseId) => '$baseUrl/api/academy/courses/$courseId/subjects';
  static String academySubjectById(String subjectId) => '$baseUrl/api/academy/courses/subjects/$subjectId';
  static const String academyStudents  = '$baseUrl/api/academy/students';
  static const String academyFees           = '$baseUrl/api/academy/fees';
  static const String academyFeeReceipts    = '$baseUrl/api/academy/fees/receipts';
  static String academyFeeReceiptById(String id) => '$baseUrl/api/academy/fees/receipts/$id';
  static String academyFeeReceiptResend(String id) => '$baseUrl/api/academy/fees/receipts/$id/resend';
  static const String academyAttendanceScan = '$baseUrl/api/academy/attendance/scan';
  static const String academyQrCodes        = '$baseUrl/api/academy/qr-codes';
  static const String academyAcademicYears  = '$baseUrl/api/academy/academic-years';
  static const String academyNotifications  = '$baseUrl/api/academy/notifications';

  // Super Admin
  static const String superAdminAcademies  = '$baseUrl/api/super-admin/academies';

  // Parent — 2-step face-verified login + protected routes
  static const String parentCheckCredentials = '$baseUrl/api/academy/parent/check-credentials';
  static const String parentVerifyFace       = '$baseUrl/api/academy/parent/verify-face';
  static const String parentVerifyPassword   = '$baseUrl/api/academy/parent/verify-password';
  static const String parentFcmToken         = '$baseUrl/api/academy/parent/fcm-token';
  static const String parentProfile          = '$baseUrl/api/academy/parent/profile';
  static const String parentAttendance       = '$baseUrl/api/academy/parent/attendance';
  static const String parentReceipts         = '$baseUrl/api/academy/parent/receipts';
  static String parentReceiptById(String id) => '$baseUrl/api/academy/parent/receipts/$id';
  static const String parentNotifications        = '$baseUrl/api/academy/parent/notifications';
  static const String parentNotificationsLatest  = '$baseUrl/api/academy/parent/notifications/latest';
  static String parentNotificationRead(String id) => '$baseUrl/api/academy/parent/notifications/$id/read';

  // Admin — student master password
  static String studentMasterPassword(String id) => '$baseUrl/api/academy/students/$id/master-password';

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
