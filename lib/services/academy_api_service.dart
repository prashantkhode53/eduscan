import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/api_endpoints.dart';
import 'storage_service.dart';
import '../utils/network_aware_client.dart';

/// Thrown when the backend returns a 409 FACE_DUPLICATE response.
/// Carries the matched student's details so the UI can show a rich warning.
class FaceDuplicateException implements Exception {
  final String message;
  final String? studentId;
  final String? studentName;
  final List<String> courses;
  final String? registeredAt;
  final double? confidence;

  const FaceDuplicateException({
    required this.message,
    this.studentId,
    this.studentName,
    this.courses = const [],
    this.registeredAt,
    this.confidence,
  });

  @override
  String toString() => message;
}

/// Thrown for any non-success API response that isn't a face-duplicate.
/// Carries the backend's structured fields so the UI can show a specific,
/// traceable message instead of a generic one:
///  - [message]   user-safe reason from the server
///  - [statusCode] HTTP status (e.g. 400, 422, 500)
///  - [errorRef]   short correlation id logged server-side (for support)
///  - [category]   coarse failure type: validation | face | database | schema | server
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? errorRef;
  final String? category;

  const ApiException(
    this.message, {
    this.statusCode,
    this.errorRef,
    this.category,
  });

  /// True when the failure is a server/database/schema fault (not user-fixable),
  /// so the UI should surface the reference code for support follow-up.
  bool get isServerFault =>
      category == 'server' || category == 'database' || category == 'schema' ||
      (statusCode != null && statusCode! >= 500);

  @override
  String toString() => message;
}

/// All API calls scoped to an academy (requires academy JWT in Authorization header).
class AcademyApiService {
  static const Duration _timeout     = Duration(seconds: 30);
  static const Duration _regTimeout  = Duration(seconds: 90);
  static final _http = NetworkAwareClient();

  static Future<Map<String, String>> _headers() async {
    final token = await StorageService.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static dynamic _parse(http.Response res) {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      // Non-JSON body (e.g. an HTML 502 from the proxy while the server wakes).
      throw ApiException(
        res.statusCode >= 500
            ? 'The server is starting up or temporarily unavailable. Please try again in a moment.'
            : 'Unexpected server response (${res.statusCode}).',
        statusCode: res.statusCode,
        category: 'server',
      );
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return body['data'] ?? body;
    }
    // Structured face-duplicate 409 — raise a typed exception so the UI can
    // show a rich dialog instead of a generic red snackbar.
    if (res.statusCode == 409) {
      final data = body['data'] as Map<String, dynamic>?;
      if (data != null && data['code'] == 'FACE_DUPLICATE') {
        final dup = data['duplicate'] as Map<String, dynamic>? ?? {};
        final rawCourses = dup['courses'];
        final courses = rawCourses is List
            ? rawCourses.map((e) => e.toString()).toList()
            : <String>[];
        throw FaceDuplicateException(
          message:      body['message'] as String? ?? 'Face already registered.',
          studentId:    dup['student_id']    as String?,
          studentName:  dup['student_name']  as String?,
          courses:      courses,
          registeredAt: dup['registered_at'] as String?,
          confidence:   (dup['confidence']   as num?)?.toDouble(),
        );
      }
    }
    // Typed failure carrying the server's reason + correlation ref + category.
    throw ApiException(
      body['message'] as String? ?? 'Request failed (${res.statusCode})',
      statusCode: res.statusCode,
      errorRef:   body['error_ref'] as String?,
      category:   body['category']  as String?,
    );
  }

  // ── Stats ─────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getStats({String? academicYearId}) async {
    final params = <String, String>{
      if (academicYearId != null) 'academic_year_id': academicYearId,
    };
    final uri = params.isEmpty
        ? Uri.parse('${ApiEndpoints.academyStudents}/stats')
        : Uri.parse('${ApiEndpoints.academyStudents}/stats')
            .replace(queryParameters: params);
    final res = await _http.get(uri, headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  // ── Academic Years ────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getAcademicYears() async {
    final res = await _http.get(Uri.parse(ApiEndpoints.academyAcademicYears), headers: await _headers())
        .timeout(_timeout);
    final data = _parse(res);
    return (data as List).cast<Map<String, dynamic>>();
  }

  static Future<Map<String, dynamic>?> getCurrentAcademicYear() async {
    final res = await _http.get(Uri.parse('${ApiEndpoints.academyAcademicYears}/current'),
            headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>?;
  }

  static Future<Map<String, dynamic>> createAcademicYear(
      Map<String, dynamic> body) async {
    final res = await _http.post(Uri.parse(ApiEndpoints.academyAcademicYears),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> updateAcademicYear(
      String id, Map<String, dynamic> body) async {
    final res = await _http.put(Uri.parse('${ApiEndpoints.academyAcademicYears}/$id'),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> deleteAcademicYear(String id) async {
    final res = await _http.delete(Uri.parse('${ApiEndpoints.academyAcademicYears}/$id'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  // ── Parent notifications (admin broadcast) ──────────────────────────────────

  /// Broadcast a notification to all parents in the selected academic year(s)
  /// who are enrolled in one of the selected course(s).
  /// Returns { notification_id, total_recipients, success_count, failed_count, status }.
  static Future<Map<String, dynamic>> sendParentNotification({
    required List<String> academicYearIds,
    required List<String> courseIds,
    required String message,
  }) async {
    final res = await _http.post(
          Uri.parse(ApiEndpoints.academyNotifications),
          headers: await _headers(),
          body: jsonEncode({
            'academic_year_ids': academicYearIds,
            'course_ids':        courseIds,
            'message':           message,
          }),
        )
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  /// Admin notification history (newest first, paginated).
  /// [limit] is clamped server-side to 50; defaults to the backend's 20.
  static Future<Map<String, dynamic>> getSentNotifications(
      {int page = 1, int? limit}) async {
    final params = <String, String>{
      'page': page.toString(),
      if (limit != null) 'limit': limit.toString(),
    };
    final uri = Uri.parse(ApiEndpoints.academyNotifications)
        .replace(queryParameters: params);
    final res = await _http.get(uri, headers: await _headers()).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  /// Fetch the ENTIRE sent-notification history by walking the paginated
  /// endpoint at its max page size (50). Used only for the Excel export, where
  /// the full dataset is needed; the in-app list shows just the latest few.
  /// Caps total pages so a runaway history can never loop unbounded.
  static Future<List<Map<String, dynamic>>> getAllSentNotifications() async {
    const pageLimit = 50;     // backend hard cap
    const maxPages  = 200;    // safety bound (≤10k rows)
    final all = <Map<String, dynamic>>[];
    for (var page = 1; page <= maxPages; page++) {
      final data = await getSentNotifications(page: page, limit: pageLimit);
      final list = (data['notifications'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      all.addAll(list);
      if (list.length < pageLimit) break; // last page reached
    }
    return all;
  }

  // ── Courses ───────────────────────────────────────────────────────────────

  static Future<List<dynamic>> getCourses({String? academicYearId}) async {
    final params = <String, String>{
      if (academicYearId != null) 'academic_year_id': academicYearId,
    };
    final uri = params.isEmpty
        ? Uri.parse(ApiEndpoints.academyCourses)
        : Uri.parse(ApiEndpoints.academyCourses).replace(queryParameters: params);
    final res = await _http.get(uri, headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as List<dynamic>;
  }

  static Future<Map<String, dynamic>> createCourse(Map<String, dynamic> body) async {
    final res = await _http.post(Uri.parse(ApiEndpoints.academyCourses),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> updateCourse(
      String id, Map<String, dynamic> body) async {
    final res = await _http.put(Uri.parse('${ApiEndpoints.academyCourses}/$id'),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> deleteCourse(String id) async {
    final res = await _http.delete(Uri.parse('${ApiEndpoints.academyCourses}/$id'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  // ── Subjects ──────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getSubjectsByCourse(String courseId) async {
    final res = await _http.get(Uri.parse(ApiEndpoints.academySubjects(courseId)),
            headers: await _headers())
        .timeout(_timeout);
    final data = _parse(res);
    return (data as List).cast<Map<String, dynamic>>();
  }

  static Future<Map<String, dynamic>> createSubject(
      String courseId, Map<String, dynamic> body) async {
    final res = await _http.post(Uri.parse(ApiEndpoints.academySubjects(courseId)),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> updateSubject(
      String subjectId, Map<String, dynamic> body) async {
    final res = await _http.put(Uri.parse(ApiEndpoints.academySubjectById(subjectId)),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> deleteSubject(String subjectId) async {
    final res = await _http.delete(Uri.parse(ApiEndpoints.academySubjectById(subjectId)),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  // ── Students ──────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getStudents({
    String? search,
    String? courseId,
    int page = 1,
    int limit = 50,
    String status = 'active',
  }) async {
    final params = <String, String>{
      'page': page.toString(),
      'limit': limit.toString(),
      'status': status,
      if (search != null && search.isNotEmpty) 'search': search,
      if (courseId != null) 'course_id': courseId,
    };
    final uri = Uri.parse(ApiEndpoints.academyStudents)
        .replace(queryParameters: params);
    final res = await _http.get(uri, headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> registerStudent(
      Map<String, dynamic> body) async {
    // The long timeout only applies when a face is included (InsightFace
    // embedding is slow); a details-only "save before scan" is a quick DB write.
    final hasFace = (body['face_images'] as List?)?.isNotEmpty ?? false;
    final res = await _http.post(Uri.parse(ApiEndpoints.academyStudents),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(hasFace ? _regTimeout : _timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  /// Check whether a fully-registered student with the same first name, last name,
  /// and date of birth already exists in this academy's schema.
  /// Returns the matched student map, or null if no duplicate found.
  /// Bulk-upload pre-parsed student records. The server validates, deduplicates
  /// against the DB, and creates student profiles. Returns detailed results.
  static Future<Map<String, dynamic>> bulkUploadStudents(
      List<Map<String, dynamic>> students, {String? academicYearId}) async {
    final res = await _http.post(
          Uri.parse('${ApiEndpoints.academyStudents}/bulk-upload'),
          headers: await _headers(),
          body: jsonEncode({
            'students': students,
            if (academicYearId != null) 'academic_year_id': academicYearId,
          }),
        )
        .timeout(const Duration(seconds: 120));
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>?> checkStudentDuplicate({
    required String firstName,
    required String lastName,
    required String dob,
  }) async {
    final uri = Uri.parse('${ApiEndpoints.academyStudents}/check-duplicate')
        .replace(queryParameters: {
      'first_name': firstName.trim(),
      'last_name':  lastName.trim(),
      'dob':        dob.trim(),
    });
    final res = await _http.get(uri, headers: await _headers())
        .timeout(_timeout);
    final data = _parse(res) as Map<String, dynamic>;
    if (data['exists'] == true) {
      return data['student'] as Map<String, dynamic>?;
    }
    return null;
  }

  static Future<Map<String, dynamic>> getStudentById(String id) async {
    final res = await _http.get(Uri.parse('${ApiEndpoints.academyStudents}/$id'),
            headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> scanFace(
      String imageBase64, String mode) async {
    final res = await _http.post(
          Uri.parse(ApiEndpoints.academyAttendanceScan),
          headers: await _headers(),
          body: jsonEncode({'image_base64': imageBase64, 'mode': mode}),
        )
        .timeout(const Duration(seconds: 20));
    return _parse(res) as Map<String, dynamic>;
  }

  /// Probes whether the face-recognition service is awake and its model loaded.
  /// Returns true only when InsightFace reports ready. The probe itself nudges
  /// a sleeping Render container to wake, so repeated calls converge to ready.
  /// Best-effort: returns false (never throws) on any timeout/network error so
  /// the scan screen can simply keep polling.
  static Future<bool> checkScanReady() async {
    try {
      final uri = Uri.parse(ApiEndpoints.health)
          .replace(queryParameters: {'include': 'insightface'});
      final res = await _http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return false;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final insightface = body['insightface'] as Map<String, dynamic>?;
      return insightface?['ready'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> updateStudent(
      String id, Map<String, dynamic> body) async {
    final res = await _http.patch(Uri.parse('${ApiEndpoints.academyStudents}/$id'),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(_regTimeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> deleteStudent(String id) async {
    final res = await _http.delete(Uri.parse('${ApiEndpoints.academyStudents}/$id'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  /// Phase 2 of registration / re-capture: attach or replace ONLY the face.
  static Future<void> updateStudentFace(
      String id, List<String> faceImages) async {
    final res = await _http.patch(Uri.parse('${ApiEndpoints.academyStudents}/$id/face'),
            headers: await _headers(),
            body: jsonEncode({'face_images': faceImages}))
        .timeout(_regTimeout);
    _parse(res);
  }

  // ── Fees ──────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getFees({
    String? status,
    String? studentId,
    String? courseId,
    List<String>? courseIds,
    String? academicYearId,
    String? dueFilter,
    int page = 1,
    int limit = 50,
  }) async {
    final params = <String, String>{
      'page': page.toString(),
      'limit': limit.toString(),
      if (status != null)    'status':     status,
      if (studentId != null) 'student_id': studentId,
      if (courseId != null)  'course_id':  courseId,
      if (courseIds != null && courseIds.isNotEmpty)
        'course_ids': courseIds.join(','),
      if (academicYearId != null) 'academic_year_id': academicYearId,
      if (dueFilter != null) 'due_filter': dueFilter,
    };
    final uri = Uri.parse(ApiEndpoints.academyFees)
        .replace(queryParameters: params);
    final res = await _http.get(uri, headers: await _headers()).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> collectFee({
    required String feeRecordId,
    required double amountPaid,
    String paymentMode = 'cash',
    String? remarks,
  }) async {
    final res = await _http.post(
          Uri.parse('${ApiEndpoints.academyFees}/collect'),
          headers: await _headers(),
          body: jsonEncode({
            'fee_record_id': feeRecordId,
            'amount_paid':   amountPaid,
            'payment_mode':  paymentMode,
            if (remarks != null) 'remarks': remarks,
          }),
        )
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> collectFeeBulk({
    required String studentId,
    required List<Map<String, dynamic>> items,
    String paymentMode = 'cash',
    String? remarks,
  }) async {
    final res = await _http.post(
          Uri.parse('${ApiEndpoints.academyFees}/collect'),
          headers: await _headers(),
          body: jsonEncode({
            'student_id':   studentId,
            'items':        items,
            'payment_mode': paymentMode,
            if (remarks != null) 'remarks': remarks,
          }),
        )
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getFeesStudentSummary({
    String? dueFilter,
    List<String>? courseIds,
    String? academicYearId,
  }) async {
    final params = <String, String>{
      if (dueFilter != null) 'due_filter': dueFilter,
      if (courseIds != null && courseIds.isNotEmpty)
        'course_ids': courseIds.join(','),
      if (academicYearId != null) 'academic_year_id': academicYearId,
    };
    final uri = Uri.parse('${ApiEndpoints.academyFees}/students-summary')
        .replace(queryParameters: params.isEmpty ? null : params);
    final res = await _http.get(uri, headers: await _headers()).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  /// Installment-wise export data for the selected Academic Year + Course(s).
  /// Returns { academic_year_name, course_label, start_month, students: [...] }
  /// where each student has a `monthly` map (YYYY-MM → amount, IST) and `total`.
  static Future<Map<String, dynamic>> getFeesExportData({
    required String academicYearId,
    required List<String> courseIds,
  }) async {
    final uri = Uri.parse('${ApiEndpoints.academyFees}/export-data').replace(
      queryParameters: {
        'academic_year_id': academicYearId,
        'course_ids':       courseIds.join(','),
      },
    );
    final res = await _http.get(uri, headers: await _headers()).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> generateMonthlyFees() async {
    final res = await _http.post(
          Uri.parse('${ApiEndpoints.academyFees}/generate'),
          headers: await _headers(),
          body: jsonEncode({}),
        )
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> markOverdueFees() async {
    final res = await _http.post(Uri.parse('${ApiEndpoints.academyFees}/mark-overdue'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  static Future<Map<String, dynamic>> getStudentFees(String studentId) async {
    final res = await _http.get(Uri.parse('${ApiEndpoints.academyFees}/student/$studentId'),
            headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  // ── Receipts ──────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> listReceipts({
    String? studentId,
    String? from,
    String? to,
    String? q,
    List<String>? courseIds,
    String? academicYearId,
    int page = 1,
    int limit = 50,
  }) async {
    final params = <String, String>{
      'page': page.toString(),
      'limit': limit.toString(),
      if (studentId != null) 'student_id': studentId,
      if (from != null)      'from':       from,
      if (to != null)        'to':         to,
      if (q != null && q.isNotEmpty) 'q': q,
      if (courseIds != null && courseIds.isNotEmpty)
        'course_ids': courseIds.join(','),
      if (academicYearId != null) 'academic_year_id': academicYearId,
    };
    final uri = Uri.parse(ApiEndpoints.academyFeeReceipts)
        .replace(queryParameters: params);
    final res = await _http.get(uri, headers: await _headers()).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getReceipt(String id) async {
    final res = await _http.get(
      Uri.parse(ApiEndpoints.academyFeeReceiptById(id)),
      headers: await _headers(),
    ).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> resendReceipt(String id) async {
    final res = await _http.post(
      Uri.parse(ApiEndpoints.academyFeeReceiptResend(id)),
      headers: await _headers(),
    ).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  // ── QR Codes ──────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> listQrCodes() async {
    final res = await _http.get(Uri.parse(ApiEndpoints.academyQrCodes), headers: await _headers())
        .timeout(_timeout);
    final data = _parse(res);
    return (data as List).cast<Map<String, dynamic>>();
  }

  static Future<Map<String, dynamic>?> getActiveQrCode() async {
    final res = await _http.get(Uri.parse('${ApiEndpoints.academyQrCodes}/active'), headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>?;
  }

  static Future<Map<String, dynamic>> createQrCode(Map<String, dynamic> body) async {
    final res = await _http.post(Uri.parse(ApiEndpoints.academyQrCodes),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> updateQrCode(
      String id, Map<String, dynamic> body) async {
    final res = await _http.put(Uri.parse('${ApiEndpoints.academyQrCodes}/$id'),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> activateQrCode(String id) async {
    final res = await _http.patch(Uri.parse('${ApiEndpoints.academyQrCodes}/$id/activate'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  static Future<void> deleteQrCode(String id) async {
    final res = await _http.delete(Uri.parse('${ApiEndpoints.academyQrCodes}/$id'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  /// Admin: set or replace the fallback login password for a student.
  static Future<void> setStudentMasterPassword(String studentId, String password) async {
    final res = await _http.put(
          Uri.parse(ApiEndpoints.studentMasterPassword(studentId)),
          headers: await _headers(),
          body: jsonEncode({'password': password}),
        )
        .timeout(_timeout);
    _parse(res);
  }

  /// Admin: revoke the fallback login password for a student.
  static Future<void> deleteStudentMasterPassword(String studentId) async {
    final res = await _http.delete(
          Uri.parse(ApiEndpoints.studentMasterPassword(studentId)),
          headers: await _headers(),
        )
        .timeout(_timeout);
    _parse(res);
  }
}
