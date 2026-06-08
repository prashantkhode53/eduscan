import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/api_endpoints.dart';
import 'storage_service.dart';
import '../utils/network_aware_client.dart';

class SuperAdminApiService {
  static const Duration _timeout = Duration(seconds: 30);
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
    throw Exception(body['message'] ?? 'Request failed (${res.statusCode})');
  }

  // ── Academies ──────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> listAcademies({
    String? search,
    String? status,
    String sort = 'created_at',
  }) async {
    final params = <String, String>{
      'sort': sort,
      if (search != null && search.isNotEmpty) 'search': search,
      if (status != null && status != 'all') 'status': status,
    };
    final uri = Uri.parse(ApiEndpoints.superAdminAcademies)
        .replace(queryParameters: params);
    final res = await _http.get(uri, headers: await _headers()).timeout(_timeout);
    final data = _parse(res);
    return (data as List).cast<Map<String, dynamic>>();
  }

  static Future<Map<String, dynamic>> getAcademyStats(String slug) async {
    final res = await _http.get(Uri.parse('${ApiEndpoints.superAdminAcademies}/$slug/stats'),
            headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getAcademyStudents(
    String slug, {
    String search = '',
    String status = 'active',
    int page = 1,
    int limit = 50,
  }) async {
    final params = <String, String>{
      'status': status,
      'page':   page.toString(),
      'limit':  limit.toString(),
      if (search.isNotEmpty) 'search': search,
    };
    final uri = Uri.parse('${ApiEndpoints.superAdminAcademies}/$slug/students')
        .replace(queryParameters: params);
    final res = await _http.get(uri, headers: await _headers()).timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> exportAcademyStudents(String slug) async {
    final res = await _http.get(Uri.parse('${ApiEndpoints.superAdminAcademies}/$slug/export'),
            headers: await _headers())
        .timeout(const Duration(seconds: 60));
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> deactivateAcademy(String slug) async {
    final res = await _http.patch(Uri.parse('${ApiEndpoints.superAdminAcademies}/$slug/deactivate'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  static Future<void> activateAcademy(String slug) async {
    final res = await _http.patch(Uri.parse('${ApiEndpoints.superAdminAcademies}/$slug/activate'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  static Future<void> deleteAcademy(
      String slug, String password, String academyName) async {
    final res = await _http.delete(
          Uri.parse('${ApiEndpoints.superAdminAcademies}/$slug'),
          headers: await _headers(),
          body: jsonEncode({
            'password':     password,
            'academy_name': academyName,
          }),
        )
        .timeout(_timeout);
    _parse(res);
  }

  // ── Account lock / unlock ──────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getAcademyLoginStatus(String slug) async {
    final res = await _http
        .get(Uri.parse('${ApiEndpoints.superAdminAcademies}/$slug/login-status'),
            headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<void> unlockAcademyUser(String slug) async {
    final res = await _http
        .patch(Uri.parse('${ApiEndpoints.superAdminAcademies}/$slug/unlock-user'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  static Future<void> resetLoginAttempts(String slug) async {
    final res = await _http
        .patch(Uri.parse('${ApiEndpoints.superAdminAcademies}/$slug/reset-attempts'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  static Future<void> blockAcademyUser(String slug) async {
    final res = await _http
        .patch(Uri.parse('${ApiEndpoints.superAdminAcademies}/$slug/block-user'),
            headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }
}
