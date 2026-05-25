import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/api_endpoints.dart';
import 'storage_service.dart';

class ApiService {
  // 30s timeout handles Render free-tier cold start (up to ~30s after sleep)
  static const Duration _timeout = Duration(seconds: 30);
  // Shorter timeout for real-time face scan — must feel responsive
  static const Duration _scanTimeout = Duration(seconds: 15);

  // ── Headers ───────────────────────────────────────────────────────────────

  static Future<Map<String, String>> _authHeaders() async {
    final token = await StorageService.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Future<Map<String, String>> _kioskHeaders() async {
    final key = await StorageService.getKioskKey();
    if (key != null && key.isNotEmpty) {
      return {
        'Content-Type': 'application/json',
        'X-Kiosk-Key': key,
      };
    }
    // Fall back to JWT when kiosk key not yet loaded or unavailable
    final token = await StorageService.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  // ── Response parser ───────────────────────────────────────────────────────
  // Unwraps body['data'] when present so callers always get the payload directly.

  static dynamic _parse(http.Response response) {
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body['data'] ?? body;
    }
    throw ApiException(
      message: body['message'] as String? ?? 'Request failed (${response.statusCode})',
      statusCode: response.statusCode,
    );
  }

  // ── Health ────────────────────────────────────────────────────────────────

  static Future<bool> checkHealth() async {
    try {
      final res = await http
          .get(Uri.parse(ApiEndpoints.health))
          .timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Auth ─────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> login(
      String username, String password) async {
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.login),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'username': username, 'password': password}),
        )
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> forgotPassword(String email) async {
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.forgotPassword),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email}),
        )
        .timeout(_timeout);
    _parse(res);
  }

  static Future<String> verifyOtp(String email, String otp) async {
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.verifyOtp),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'otp': otp}),
        )
        .timeout(_timeout);
    final data = _parse(res) as Map<String, dynamic>;
    return data['reset_token'] as String;
  }

  static Future<void> resetPassword(
      String resetToken, String newPassword) async {
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.resetPassword),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(
              {'reset_token': resetToken, 'new_password': newPassword}),
        )
        .timeout(_timeout);
    _parse(res);
  }

  static Future<void> changePassword(
      String currentPassword, String newPassword) async {
    final headers = await _authHeaders();
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.changePassword),
          headers: headers,
          body: jsonEncode({
            'current_password': currentPassword,
            'new_password': newPassword,
          }),
        )
        .timeout(_timeout);
    _parse(res);
  }

  // ── Students ──────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getStudents({
    String? classGrade,
    String? division,
    String? search,
    String status = 'active',
    int page = 1,
    int limit = 50,
  }) async {
    final headers = await _authHeaders();
    final params = <String, String>{
      'status': status,
      'page': page.toString(),
      'limit': limit.toString(),
    };
    if (classGrade != null) params['class'] = classGrade;
    if (division != null) params['division'] = division;
    if (search != null && search.isNotEmpty) params['search'] = search;
    final uri =
        Uri.parse(ApiEndpoints.students).replace(queryParameters: params);
    final res =
        await http.get(uri, headers: headers).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getStudentById(String id) async {
    final headers = await _authHeaders();
    final res = await http
        .get(Uri.parse(ApiEndpoints.studentById(id)), headers: headers)
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<dynamic> createStudent(Map<String, dynamic> body) async {
    final headers = await _authHeaders();
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.students),
          headers: headers,
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    return _parse(res);
  }

  static Future<dynamic> updateStudent(
      String id, Map<String, dynamic> body) async {
    final headers = await _authHeaders();
    final res = await http
        .put(
          Uri.parse(ApiEndpoints.studentById(id)),
          headers: headers,
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    return _parse(res);
  }

  static Future<void> deleteStudent(String id) async {
    final headers = await _authHeaders();
    final res = await http
        .delete(Uri.parse(ApiEndpoints.studentById(id)), headers: headers)
        .timeout(_timeout);
    _parse(res);
  }

  static Future<Map<String, dynamic>> getStudentAttendance(
      String id, {int page = 1}) async {
    final headers = await _authHeaders();
    final uri = Uri.parse(ApiEndpoints.studentAttendance(id))
        .replace(queryParameters: {'page': page.toString(), 'limit': '30'});
    final res =
        await http.get(uri, headers: headers).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  // ── Attendance ────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getAttendance({
    String? date,
    String? dateFrom,
    String? dateTo,
    String? classGrade,
    String? division,
    String? studentId,
    int page = 1,
    int limit = 100,
  }) async {
    final headers = await _authHeaders();
    final params = <String, String>{
      'page': page.toString(),
      'limit': limit.toString(),
    };
    if (date != null) params['date'] = date;
    if (dateFrom != null) params['date_from'] = dateFrom;
    if (dateTo != null) params['date_to'] = dateTo;
    if (classGrade != null) params['class'] = classGrade;
    if (division != null) params['division'] = division;
    if (studentId != null) params['student_id'] = studentId;
    final uri =
        Uri.parse(ApiEndpoints.attendance).replace(queryParameters: params);
    final res =
        await http.get(uri, headers: headers).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<dynamic> updateAttendance(
      String id, Map<String, dynamic> body) async {
    final headers = await _authHeaders();
    final res = await http
        .put(
          Uri.parse(ApiEndpoints.attendanceById(id)),
          headers: headers,
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    return _parse(res);
  }

  static Future<void> batchAttendance(
      List<Map<String, dynamic>> records) async {
    final headers = await _authHeaders();
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.attendanceBatch),
          headers: headers,
          body: jsonEncode({'records': records}),
        )
        .timeout(_timeout);
    _parse(res);
  }

  static Future<void> bulkMarkAbsent(String date,
      {String? classGrade, String? division}) async {
    final headers = await _authHeaders();
    final body = <String, dynamic>{'date': date};
    if (classGrade != null) body['class_grade'] = classGrade;
    if (division != null) body['division'] = division;
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.attendanceBulkAbsent),
          headers: headers,
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    _parse(res);
  }

  // ── Scan — kiosk endpoint (returns raw body for ScanResult.fromJson) ──────

  static Future<Map<String, dynamic>> scan(
    List<double> embedding,
    String mode,
    String classId,
  ) async {
    final headers = await _kioskHeaders();
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.attendanceScan),
          headers: headers,
          body: jsonEncode({
            'embedding': embedding,
            'mode': mode,
            'class_id': classId,
            'timestamp': DateTime.now().toIso8601String(),
          }),
        )
        .timeout(_scanTimeout);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ── Reports ───────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getDashboardStats() async {
    final headers = await _authHeaders();
    final res = await http
        .get(Uri.parse(ApiEndpoints.reportsSummary), headers: headers)
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<List<dynamic>> getWeeklyStats() async {
    final headers = await _authHeaders();
    final res = await http
        .get(Uri.parse(ApiEndpoints.reportsWeekly), headers: headers)
        .timeout(_timeout);
    return _parse(res) as List<dynamic>;
  }

  static Future<List<dynamic>> getRecentActivity() async {
    final headers = await _authHeaders();
    final res = await http
        .get(Uri.parse(ApiEndpoints.reportsRecentActivity), headers: headers)
        .timeout(_timeout);
    return _parse(res) as List<dynamic>;
  }

  static Future<List<dynamic>> getStudentReportSummary() async {
    final headers = await _authHeaders();
    final res = await http
        .get(Uri.parse(ApiEndpoints.reportsStudents), headers: headers)
        .timeout(_timeout);
    return _parse(res) as List<dynamic>;
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getSettings() async {
    final headers = await _authHeaders();
    final res = await http
        .get(Uri.parse(ApiEndpoints.settings), headers: headers)
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> updateSetting(String key, String value) async {
    final headers = await _authHeaders();
    final res = await http
        .put(
          Uri.parse(ApiEndpoints.settings),
          headers: headers,
          body: jsonEncode({'key': key, 'value': value}),
        )
        .timeout(_timeout);
    _parse(res);
  }

  static Future<String> regenKioskKey() async {
    final headers = await _authHeaders();
    final res = await http
        .post(Uri.parse(ApiEndpoints.regenKioskKey), headers: headers)
        .timeout(_timeout);
    final data = _parse(res) as Map<String, dynamic>;
    return data['kiosk_api_key'] as String;
  }
}

// ── Custom exception ──────────────────────────────────────────────────────────

class ApiException implements Exception {
  final String message;
  final int statusCode;

  const ApiException({required this.message, required this.statusCode});

  @override
  String toString() => message;
}
