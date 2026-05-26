import 'package:flutter/foundation.dart';
import '../models/whatsapp_status.dart';
import '../services/whatsapp_api_service.dart';

class WhatsAppProvider extends ChangeNotifier {
  WhatsAppStatus _status = WhatsAppStatus.disconnected();
  bool    _loading         = false;
  String? _error;
  bool    _serviceReachable = false;

  // ── Getters ───────────────────────────────────────────────────────────────

  WhatsAppStatus get status           => _status;
  bool           get loading          => _loading;
  String?        get error            => _error;
  bool           get serviceReachable => _serviceReachable;
  bool           get isConnected      => _status.connected;

  // ── Data fetching ─────────────────────────────────────────────────────────

  Future<void> refresh() async {
    _loading = true;
    _error   = null;
    notifyListeners();

    try {
      final statusData = await WhatsAppApiService.getStatus();
      var current = WhatsAppStatus.fromStatusJson(statusData);

      // Fetch QR when disconnected so the user can scan
      if (!current.connected) {
        try {
          final qrData = await WhatsAppApiService.getQr();
          current = WhatsAppStatus.mergeQr(current, qrData);
        } catch (_) {
          // QR fetch failure is non-fatal
        }
      }

      _status           = current;
      _serviceReachable = true;
    } catch (e) {
      final raw = e.toString().replaceFirst('Exception: ', '');
      _error = _friendlyError(raw);
      _serviceReachable = false;
    }

    _loading = false;
    notifyListeners();
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> reconnect() async {
    _loading = true;
    _error   = null;
    notifyListeners();
    try {
      await WhatsAppApiService.reconnect();
    } catch (_) {
      // Reconnect is best-effort; poll will update state
    }
    await refresh();
  }

  static String _friendlyError(String raw) {
    if (raw.contains('Route not found')) {
      return 'WhatsApp service unavailable — backend may not be deployed yet';
    }
    if (raw.contains('timed out') || raw.contains('TimeoutException')) {
      return 'Request timed out — check your connection';
    }
    if (raw.contains('SocketException') || raw.contains('Failed host lookup')) {
      return 'Cannot reach server — check your connection';
    }
    if (raw.contains('401') || raw.contains('Unauthorized')) {
      return 'Session expired — please log in again';
    }
    return raw;
  }

  Future<bool> sendTestMessage(String phone) async {
    try {
      await WhatsAppApiService.sendCustomMessage(
        phone:   phone,
        message: 'Test message from EduScan — WhatsApp service is working ✓',
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> sendCheckinNotification({
    required String phone,
    required String parentName,
    required String studentName,
    required String time,
  }) async {
    try {
      await WhatsAppApiService.sendCheckinNotification(
        phone: phone, parentName: parentName,
        studentName: studentName, time: time,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> sendCheckoutNotification({
    required String phone,
    required String parentName,
    required String studentName,
    required String time,
  }) async {
    try {
      await WhatsAppApiService.sendCheckoutNotification(
        phone: phone, parentName: parentName,
        studentName: studentName, time: time,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
