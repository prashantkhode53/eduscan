import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/whatsapp_status.dart';
import '../services/whatsapp_api_service.dart';

class WhatsAppProvider extends ChangeNotifier {
  WhatsAppStatus _status          = WhatsAppStatus.disconnected();
  bool           _loading         = false;
  String?        _error;
  bool           _serviceReachable = false;

  // Internal — lifecycle managed by the provider
  StreamSubscription<Map<String, dynamic>>? _sseSub;
  Timer?  _pollTimer;
  Timer?  _sseReconnectTimer;
  bool    _disposed = false;

  WhatsAppProvider() {
    // Initial data load + start real-time stream
    _initialLoad();
  }

  // ── Getters ───────────────────────────────────────────────────────────────

  WhatsAppStatus get status           => _status;
  bool           get loading          => _loading;
  String?        get error            => _error;
  bool           get serviceReachable => _serviceReachable;
  bool           get isConnected      => _status.connected;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _disposed = true;
    _sseSub?.cancel();
    _pollTimer?.cancel();
    _sseReconnectTimer?.cancel();
    super.dispose();
  }

  // ── Initial load ──────────────────────────────────────────────────────────

  Future<void> _initialLoad() async {
    await refresh();
    _connectSSE();
  }

  // ── SSE connection ────────────────────────────────────────────────────────

  void _connectSSE() {
    if (_disposed) return;
    _sseSub?.cancel();
    _sseReconnectTimer?.cancel();

    _sseSub = WhatsAppApiService.streamStatus().listen(
      (data) {
        if (_disposed) return;
        _applyStatusData(data);
        _serviceReachable = true;
        _error            = null;
        notifyListeners();
      },
      onError: (_) {
        // SSE failed — fall back to adaptive polling
        if (!_disposed) _startAdaptivePolling();
      },
      onDone: () {
        // SSE stream ended — reconnect after a short delay
        if (!_disposed) {
          _sseReconnectTimer = Timer(
            const Duration(seconds: 5), _connectSSE);
        }
      },
      cancelOnError: true,
    );
  }

  // ── Adaptive polling (fallback when SSE is unavailable) ───────────────────

  void _startAdaptivePolling() {
    _pollTimer?.cancel();
    final interval = _status.connected
        ? const Duration(seconds: 10)
        : const Duration(seconds: 2);
    _pollTimer = Timer.periodic(interval, (_) {
      if (!_disposed) refresh();
    });
  }

  void _restartPollingForState() {
    if (_sseSub != null) return; // SSE is active — no polling needed
    _startAdaptivePolling();
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Manual refresh — fetches status and QR if needed.
  Future<void> refresh() async {
    if (_disposed) return;
    _loading = true;
    _error   = null;
    notifyListeners();

    try {
      final statusData = await WhatsAppApiService.getStatus();
      _applyStatusData(statusData, withStats: true);

      // Fetch QR separately when disconnected and no QR in status
      if (!_status.connected && _status.qrData == null && _status.hasQr) {
        try {
          final qrData = await WhatsAppApiService.getQr();
          _status = WhatsAppStatus.mergeQr(_status, qrData);
        } catch (_) {
          // QR fetch failure is non-fatal
        }
      }

      _serviceReachable = true;
    } catch (e) {
      final raw = e.toString().replaceFirst('Exception: ', '');
      _error            = _friendlyError(raw);
      _serviceReachable = false;
    }

    _loading = false;
    if (!_disposed) {
      notifyListeners();
      _restartPollingForState();
    }
  }

  /// Trigger a full WhatsApp session restart on the server and watch for QR.
  Future<void> reconnect() async {
    if (_disposed) return;
    _loading = true;
    _error   = null;
    notifyListeners();

    try {
      await WhatsAppApiService.reconnect();
    } catch (_) {
      // Reconnect is best-effort; SSE/poll will show updated state
    }

    // Ensure SSE is running so we get the new QR the moment it fires
    _connectSSE();

    _loading = false;
    if (!_disposed) notifyListeners();
  }

  // ── Messaging helpers ─────────────────────────────────────────────────────

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

  // ── Internal helpers ──────────────────────────────────────────────────────

  void _applyStatusData(Map<String, dynamic> data, {bool withStats = false}) {
    if (withStats) {
      _status = WhatsAppStatus.fromStatusJson(data);
    } else {
      // SSE payload has qrData inline — merge into a minimal status
      final base = WhatsAppStatus(
        status:          data['status']    as String? ?? _status.status,
        connected:       data['connected'] as bool?   ?? _status.connected,
        hasQr:           data['hasQr']     as bool?   ?? _status.hasQr,
        qrData:          data['qrData']    as String?,
        qrBase64:        data['qrBase64']  as String?,
        initError:       data['initError'] as String?,
        lastConnectedAt: _status.lastConnectedAt,
        totalToday:      _status.totalToday,
        sentToday:       _status.sentToday,
        failedToday:     _status.failedToday,
        lastSentAt:      _status.lastSentAt,
      );
      _status = base;
    }
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
}
