import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/api_endpoints.dart';
import 'storage_service.dart';

class ParentApiService {
  static const Duration _timeout = Duration(seconds: 20);

  static Future<Map<String, String>> _headers() async {
    final token = await StorageService.getParentToken();
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

  static Future<Map<String, dynamic>> login({
    required String academySlug,
    required String studentId,
    required String mobile,
  }) async {
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.parentLogin),
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

  static Future<void> saveFcmToken(String fcmToken) async {
    final res = await http
        .post(
          Uri.parse(ApiEndpoints.parentFcmToken),
          headers: await _headers(),
          body: jsonEncode({'fcm_token': fcmToken}),
        )
        .timeout(_timeout);
    _parse(res);
  }

  static Future<Map<String, dynamic>> getProfile() async {
    final res = await http
        .get(Uri.parse(ApiEndpoints.parentProfile), headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<List<Map<String, dynamic>>> getAttendance({int days = 30}) async {
    final uri = Uri.parse(ApiEndpoints.parentAttendance)
        .replace(queryParameters: {'days': days.toString()});
    final res = await http
        .get(uri, headers: await _headers())
        .timeout(_timeout);
    return (_parse(res) as List).cast<Map<String, dynamic>>();
  }
}
