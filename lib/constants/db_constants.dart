class DbConstants {
  static const String dbName = 'eduscan_local.db';
  static const int dbVersion = 1;

  // Tables
  static const String tableStudentsCache = 'students_cache';
  static const String tableAttendanceQueue = 'attendance_queue';
  static const String tableSyncLog = 'sync_log';

  // students_cache columns
  static const String colId = 'id';
  static const String colFirstName = 'first_name';
  static const String colLastName = 'last_name';
  static const String colClassGrade = 'class_grade';
  static const String colDivision = 'division';
  static const String colRollNo = 'roll_no';
  static const String colFaceEmbedding = 'face_embedding';
  static const String colStatus = 'status';
  static const String colSyncedAt = 'synced_at';

  // attendance_queue columns
  static const String colLocalId = 'local_id';
  static const String colStudentId = 'student_id';
  static const String colDate = 'date';
  static const String colTimeIn = 'time_in';
  static const String colTimeOut = 'time_out';
  static const String colDurationMins = 'duration_mins';
  static const String colAttStatus = 'status';
  static const String colCheckinMode = 'checkin_mode';
  static const String colCheckoutMode = 'checkout_mode';
  static const String colConfidenceIn = 'confidence_in';
  static const String colConfidenceOut = 'confidence_out';
  static const String colIsSynced = 'is_synced';
  static const String colCreatedAt = 'created_at';

  // sync_log columns
  static const String colSyncedAtLog = 'synced_at';
  static const String colRecordsPushed = 'records_pushed';
  static const String colRecordsPulled = 'records_pulled';
  static const String colError = 'error';
}
