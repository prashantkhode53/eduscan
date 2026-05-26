import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants/whatsapp_endpoints.dart';
import 'storage_service.dart';

/// HTTP client for the WhatsApp module.
/// Auth reuses the existing JWT token — no separate API key required.
class WhatsAppApiService {
  static const Duration _timeout = Duration(seconds: 15);

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

  // ── Status ────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getStatus() async {
    final res = await http
        .get(Uri.parse(WhatsAppEndpoints.status), headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getQr() async {
    final res = await http
        .get(Uri.parse(WhatsAppEndpoints.qr), headers: await _headers())
        .timeout(_timeout);
    return _parse(res) as Map<String, dynamic>;
  }

  // ── Server-Sent Events ────────────────────────────────────────────────────
  // Streams real-time state updates (status, hasQr, qrData, qrBase64, initError).
  // Caller should cancel the subscription on screen dispose.

  static Stream<Map<String, dynamic>> streamStatus() async* {
    final token = await StorageService.getToken();
    if (token == null) return;

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(WhatsAppEndpoints.events));
      request.headers['Authorization'] = 'Bearer $token';
      request.headers['Accept']        = 'text/event-stream';
      request.headers['Cache-Control'] = 'no-cache';

      final response = await client.send(request);
      if (response.statusCode != 200) return;

      String buffer = '';
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        buffer += chunk;
        // SSE blocks are delimited by double newline
        while (buffer.contains('\n\n')) {
          final idx   = buffer.indexOf('\n\n');
          final block = buffer.substring(0, idx);
          buffer      = buffer.substring(idx + 2);

          for (final line in block.split('\n')) {
            if (line.startsWith('data: ')) {
              try {
                yield jsonDecode(line.substring(6)) as Map<String, dynamic>;
              } catch (_) {}
            }
          }
        }
      }
    } finally {
      client.close();
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  static Future<void> reconnect() async {
    final res = await http
        .post(Uri.parse(WhatsAppEndpoints.reconnect), headers: await _headers())
        .timeout(_timeout);
    _parse(res);
  }

  // ── Messaging ─────────────────────────────────────────────────────────────

  static Future<void> sendCheckinNotification({
    required String phone,
    required String parentName,
    required String studentName,
    required String time,
  }) async {
    final res = await http
        .post(
          Uri.parse(WhatsAppEndpoints.sendCheckin),
          headers: await _headers(),
          body: jsonEncode({
            'phone': phone,
            'parentName': parentName,
            'studentName': studentName,
            'time': time,
          }),
        )
        .timeout(_timeout);
    _parse(res);
  }

  static Future<void> sendCheckoutNotification({
    required String phone,
    required String parentName,
    required String studentName,
    required String time,
  }) async {
    final res = await http
        .post(
          Uri.parse(WhatsAppEndpoints.sendCheckout),
          headers: await _headers(),
          body: jsonEncode({
            'phone': phone,
            'parentName': parentName,
            'studentName': studentName,
            'time': time,
          }),
        )
        .timeout(_timeout);
    _parse(res);
  }

  static Future<void> sendCustomMessage({
    required String phone,
    required String message,
  }) async {
    final res = await http
        .post(
          Uri.parse(WhatsAppEndpoints.sendCustom),
          headers: await _headers(),
          body: jsonEncode({'phone': phone, 'message': message}),
        )
        .timeout(_timeout);
    _parse(res);
  }
}
