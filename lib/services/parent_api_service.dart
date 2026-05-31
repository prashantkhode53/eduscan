import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/api_endpoints.dart';
import 'storage_service.dart';

class ParentApiService {
  static const Duration _timeout     = Duration(seconds: 20);
  static const Duration _faceTimeout = Duration(seconds: 35); // InsightFace cold start

  static Future<Map<String, String>> _authHeaders() async {
    final token = await StorageService.getParentToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Map<String, String> _sessionHeaders(String sessionToken) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $sessionToken',
      };

  static dynamic _parse(http.Response res) {
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return body['data'] ?? body;
    }
    throw Exception(body['message'] ?? 'Request failed (${res.statusCode})');
  }

  /// Step 1 — Validate Academy Code + Student ID + Mobile.
  /// Returns { session_token, student_name, academy_name }.
  static Future<Map<String, dynamic>> checkCredentials({
    required String academySlug,
    required String studentId,
    required String mobile,
  }) async {
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.parentCheckCredentials),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'academy_slug': academySlug.toLowerCase().trim(),
            'student_id':   studentId.trim().toUpperCase(),
            'mobile':       mobile.trim(),
          }),
        )
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  /// Step 2 — Send face image for verification.
  /// [sessionToken] is the 5-min token from [checkCredentials].
  /// Returns { token, student, academy, confidence } on success.
  static Future<Map<String, dynamic>> verifyFace({
    required String sessionToken,
    required String faceImageBase64,
  }) async {
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.parentVerifyFace),
          headers: _sessionHeaders(sessionToken),
          body: jsonEncode({'face_image': faceImageBase64}),
        )
        .timeout(_faceTimeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> saveFcmToken(String fcmToken) async {
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.parentFcmToken),
          headers: await _authHeaders(),
          body: jsonEncode({'fcm_token': fcmToken}),
        )
        .timeout(_timeout);
    _parse(res);
  }

  static Future<Map<String, dynamic>> getProfile() async {
    final res = await http
        .get(Uri.parse(ApiEndpoints.parentProfile), headers: await _authHeaders())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<List<Map<String, dynamic>>> getAttendance({int days = 30}) async {
    final uri = Uri.parse(ApiEndpoints.parentAttendance)
        .replace(queryParameters: {'days': days.toString()});
    final res = await http
        .get(uri, headers: await _authHeaders())
        .timeout(_timeout);
    return (_parse(res) as List).cast<Map<String, dynamic>>();
  }
}
