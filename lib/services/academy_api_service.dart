import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/api_endpoints.dart';
import 'storage_service.dart';

/// All API calls scoped to an academy (requires academy JWT in Authorization header).
class AcademyApiService {
  static const Duration _timeout     = Duration(seconds: 30);
  static const Duration _regTimeout  = Duration(seconds: 90);

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
    throw Exception(body['message'] ?? 'Request failed (${res.statusCode})');
  }

  // ── Stats ─────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getStats() async {
    final res = await http
        .get(Uri.parse(ApiEndpoints.academyStudents + '/stats'),
            headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  // ── Courses ───────────────────────────────────────────────────────────────

  static Future<List<dynamic>> getCourses() async {
    final res = await http
        .get(Uri.parse(ApiEndpoints.academyCourses), headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as List<dynamic>;
  }

  static Future<Map<String, dynamic>> createCourse(Map<String, dynamic> body) async {
    final res = await http
        .post(Uri.parse(ApiEndpoints.academyCourses),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> updateCourse(
      String id, Map<String, dynamic> body) async {
    final res = await http
        .put(Uri.parse('${ApiEndpoints.academyCourses}/$id'),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> deleteCourse(String id) async {
    final res = await http
        .delete(Uri.parse('${ApiEndpoints.academyCourses}/$id'),
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
    final res = await http
        .get(uri, headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> registerStudent(
      Map<String, dynamic> body) async {
    // The long timeout only applies when a face is included (InsightFace
    // embedding is slow); a details-only "save before scan" is a quick DB write.
    final hasFace = (body['face_images'] as List?)?.isNotEmpty ?? false;
    final res = await http
        .post(Uri.parse(ApiEndpoints.academyStudents),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(hasFace ? _regTimeout : _timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getStudentById(String id) async {
    final res = await http
        .get(Uri.parse('${ApiEndpoints.academyStudents}/$id'),
            headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> scanFace(
      String imageBase64, String mode) async {
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.academyAttendanceScan),
          headers: await _headers(),
          body: jsonEncode({'image_base64': imageBase64, 'mode': mode}),
        )
        .timeout(const Duration(seconds: 20));
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> updateStudent(
      String id, Map<String, dynamic> body) async {
    final res = await http
        .patch(Uri.parse('${ApiEndpoints.academyStudents}/$id'),
            headers: await _headers(), body: jsonEncode(body))
        .timeout(_regTimeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> deleteStudent(String id) async {
    final res = await http
        .delete(Uri.parse('${ApiEndpoints.academyStudents}/$id'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  /// Phase 2 of registration / re-capture: attach or replace ONLY the face.
  static Future<void> updateStudentFace(
      String id, List<String> faceImages) async {
    final res = await http
        .patch(Uri.parse('${ApiEndpoints.academyStudents}/$id/face'),
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
    final res = await http.get(uri, headers: await _headers()).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> collectFee({
    required String feeRecordId,
    required double amountPaid,
    String paymentMode = 'cash',
    String? remarks,
  }) async {
    final res = await http
        .post(
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
    final res = await http
        .post(
          Uri.parse('${ApiEndpoints.academyFees}/generate'),
          headers: await _headers(),
          body: jsonEncode({if (month != null) 'month': month}),
        )
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> markOverdueFees() async {
    final res = await http
        .post(Uri.parse('${ApiEndpoints.academyFees}/mark-overdue'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  static Future<Map<String, dynamic>> getStudentFees(String studentId) async {
    final res = await http
        .get(Uri.parse('${ApiEndpoints.academyFees}/student/$studentId'),
            headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }
}
