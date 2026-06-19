import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/api_endpoints.dart';
import 'storage_service.dart';
import '../utils/network_aware_client.dart';

class ParentApiService {
  static const Duration _timeout     = Duration(seconds: 20);
  static const Duration _faceTimeout = Duration(seconds: 35); // InsightFace cold start
  static final _http = NetworkAwareClient();

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
    final res = await _http.post(
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
    final res = await _http.post(
          Uri.parse(ApiEndpoints.parentVerifyFace),
          headers: _sessionHeaders(sessionToken),
          body: jsonEncode({'face_image': faceImageBase64}),
        )
        .timeout(_faceTimeout);
    return _parse(res) as Map<String, dynamic>;
  }

  /// Fallback login using admin-issued institute password.
  /// [sessionToken] is the 5-min token from [checkCredentials].
  /// Returns { token, student, academy, login_method } on success.
  static Future<Map<String, dynamic>> verifyPassword({
    required String sessionToken,
    required String password,
  }) async {
    final res = await _http.post(
          Uri.parse(ApiEndpoints.parentVerifyPassword),
          headers: _sessionHeaders(sessionToken),
          body: jsonEncode({'password': password}),
        )
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> saveFcmToken(String fcmToken) async {
    final res = await _http.post(
          Uri.parse(ApiEndpoints.parentFcmToken),
          headers: await _authHeaders(),
          body: jsonEncode({'fcm_token': fcmToken}),
        )
        .timeout(_timeout);
    _parse(res);
  }

  static Future<Map<String, dynamic>> getProfile() async {
    final res = await _http.get(Uri.parse(ApiEndpoints.parentProfile), headers: await _authHeaders())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  /// Child attendance records.
  ///
  /// Backward compatible: with no [month]/[from]/[to] it returns the trailing
  /// [days] (the original behaviour the dashboard uses). The backend filter
  /// precedence is month → from/to → days.
  ///   • [month]  'YYYY-MM' — that whole calendar month
  ///   • [from]/[to] 'YYYY-MM-DD' — explicit range (to defaults to today)
  static Future<List<Map<String, dynamic>>> getAttendance({
    int days = 30,
    String? month,
    String? from,
    String? to,
  }) async {
    final params = <String, String>{};
    if (month != null && month.isNotEmpty) {
      params['month'] = month;
    } else if (from != null && from.isNotEmpty) {
      params['from'] = from;
      if (to != null && to.isNotEmpty) params['to'] = to;
    } else {
      params['days'] = days.toString();
    }
    final uri = Uri.parse(ApiEndpoints.parentAttendance)
        .replace(queryParameters: params);
    final res = await _http.get(uri, headers: await _authHeaders())
        .timeout(_timeout);
    return (_parse(res) as List).cast<Map<String, dynamic>>();
  }

  static Future<Map<String, dynamic>> getReceipts({
    String? from,
    String? to,
    int page = 1,
    int limit = 30,
  }) async {
    final params = <String, String>{
      'page': page.toString(),
      'limit': limit.toString(),
      if (from != null) 'from': from,
      if (to != null)   'to':   to,
    };
    final uri = Uri.parse(ApiEndpoints.parentReceipts)
        .replace(queryParameters: params);
    final res = await _http.get(uri, headers: await _authHeaders())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getReceiptById(String id) async {
    final res = await _http.get(
      Uri.parse(ApiEndpoints.parentReceiptById(id)),
      headers: await _authHeaders(),
    ).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  // ── Notifications ───────────────────────────────────────────────────────────

  /// Paginated notification inbox for the logged-in parent.
  /// Returns { notifications: [...], unread_count, page, limit }.
  static Future<Map<String, dynamic>> getNotifications({
    int page = 1,
    int limit = 20,
  }) async {
    final uri = Uri.parse(ApiEndpoints.parentNotifications).replace(
      queryParameters: {'page': page.toString(), 'limit': limit.toString()},
    );
    final res = await _http.get(uri, headers: await _authHeaders())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  /// Single most-recent notification (drives the dashboard ticker).
  /// Returns the latest map, or null if the parent has no notifications.
  static Future<Map<String, dynamic>?> getLatestNotification() async {
    final res = await _http.get(
      Uri.parse(ApiEndpoints.parentNotificationsLatest),
      headers: await _authHeaders(),
    ).timeout(_timeout);
    final data = _parse(res) as Map<String, dynamic>;
    return data['latest'] as Map<String, dynamic>?;
  }

  /// Mark a notification as read for this parent.
  static Future<void> markNotificationRead(String id) async {
    final res = await _http.post(
      Uri.parse(ApiEndpoints.parentNotificationRead(id)),
      headers: await _authHeaders(),
    ).timeout(_timeout);
    _parse(res);
  }
}
