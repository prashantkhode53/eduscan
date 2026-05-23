class AppStrings {
  static const String appName = 'EduScan';
  static const String slogan = "Know who's present. Always.";
  static const String appVersion = '1.0.0';

  // Auth
  static const String login = 'Login';
  static const String logout = 'Logout';
  static const String username = 'Username';
  static const String password = 'Password';
  static const String forgotPassword = 'Forgot password?';
  static const String resetPassword = 'Reset Password';
  static const String sendOtp = 'Send OTP';
  static const String verifyOtp = 'Verify OTP';
  static const String enterEmail = 'Enter registered email';
  static const String enterOtp = 'Enter 6-digit OTP';
  static const String newPassword = 'New Password';
  static const String confirmPassword = 'Confirm Password';

  // Dashboard
  static const String dashboard = 'Dashboard';
  static const String totalStudents = 'Total Students';
  static const String presentToday = 'Present Today';
  static const String absentToday = 'Absent Today';
  static const String unknownFaces = 'Unknown Faces';
  static const String recentActivity = 'Recent Activity';
  static const String weeklyAttendance = 'Weekly Attendance';

  // Students
  static const String students = 'Students';
  static const String registerStudent = 'Register Student';
  static const String studentList = 'Student List';
  static const String searchStudents = 'Search students...';
  static const String noStudentsFound = 'No students found';
  static const String studentDetails = 'Student Details';
  static const String deleteStudent = 'Delete Student';
  static const String confirmDelete = 'Are you sure you want to deactivate this student?';

  // Attendance
  static const String attendance = 'Attendance';
  static const String checkIn = 'CHECK IN';
  static const String checkOut = 'CHECK OUT';
  static const String checkedIn = 'Checked In';
  static const String checkedOut = 'Checked Out';
  static const String offline = 'Offline';
  static const String syncing = 'Syncing...';
  static const String waitingForScan = 'Waiting for scan...';
  static const String positionFace = 'Position your face';
  static const String faceRecognised = 'Recorded';
  static const String faceNotRecognised = 'Not recognised';
  static const String alreadyCheckedIn = 'Already checked in';
  static const String outsideHours = 'Outside school hours';

  // Reports
  static const String reports = 'Reports';
  static const String exportPdf = 'Export PDF';
  static const String exportCsv = 'Export CSV';
  static const String attendancePercentage = 'Attendance %';

  // Settings
  static const String settings = 'Settings';
  static const String schoolName = 'School Name';
  static const String schoolHours = 'School Hours';
  static const String faceThreshold = 'Face Recognition Threshold';
  static const String kioskApiKey = 'Kiosk API Key';
  static const String regenerate = 'Regenerate';
  static const String autoMarkAbsent = 'Auto Mark Absent';
  static const String syncNow = 'Sync Now';
  static const String lastSynced = 'Last Synced';
  static const String pendingRecords = 'Pending Records';
  static const String dbConnection = 'Database Connection';

  // Errors
  static const String networkError = 'Network error. Please check your connection.';
  static const String serverError = 'Server error. Please try again later.';
  static const String sessionExpired = 'Session expired. Please login again.';
  static const String invalidCredentials = 'Invalid username or password.';
  static const String fieldRequired = 'This field is required';
}
