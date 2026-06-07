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
    final body = jsonDecode(res.body) as Map<String, dynamic>;
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
    throw Exception(body['message'] ?? 'Request failed (${res.statusCode})');
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
    String? month,
    int page = 1,
    int limit = 50,
  }) async {
    final params = <String, String>{
      'page': page.toString(),
      'limit': limit.toString(),
      if (status != null)    'status':     status,
      if (studentId != null) 'student_id': studentId,
      if (courseId != null)  'course_id':  courseId,
      if (month != null)     'month':      month,
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

  static Future<Map<String, dynamic>> generateMonthlyFees({String? month}) async {
    final res = await _http.post(
          Uri.parse('${ApiEndpoints.academyFees}/generate'),
          headers: await _headers(),
          body: jsonEncode({if (month != null) 'month': month}),
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
