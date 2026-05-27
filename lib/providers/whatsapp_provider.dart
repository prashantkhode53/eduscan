import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/whatsapp_status.dart';
import '../services/whatsapp_api_service.dart';

class WhatsAppProvider extends ChangeNotifier with WidgetsBindingObserver {
  WhatsAppStatus _status          = WhatsAppStatus.disconnected();
  bool           _loading         = false;
  String?        _error;
  bool           _serviceReachable = false;
  bool           _disposed         = false;

  // Internal timers / subscriptions
  StreamSubscription<Map<String, dynamic>>? _sseSub;
  StreamSubscription<ConnectivityResult>?   _connSub;
  Timer? _pollTimer;
  Timer? _sseReconnectTimer;

  // ── Getters ───────────────────────────────────────────────────────────────

  WhatsAppStatus get status           => _status;
  bool           get loading          => _loading;
  String?        get error            => _error;
  bool           get serviceReachable => _serviceReachable;
  bool           get isConnected      => _status.connected;

  // ── Constructor / Dispose ─────────────────────────────────────────────────

  WhatsAppProvider() {
    WidgetsBinding.instance.addObserver(this);
    _watchConnectivity();
    _initialLoad();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _sseSub?.cancel();
    _connSub?.cancel();
    _pollTimer?.cancel();
    _sseReconnectTimer?.cancel();
    super.dispose();
  }

  // ── App lifecycle ─────────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.resumed:
        // Foreground: restart SSE for real-time updates and refresh once
        _connectSSE();
        refresh();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Background / killed: release SSE to conserve battery
        _sseSub?.cancel();
        _sseSub = null;
        _pollTimer?.cancel();
        _pollTimer = null;
        _sseReconnectTimer?.cancel();
        _sseReconnectTimer = null;
        break;
      default:
        break;
    }
  }

  // ── Connectivity watcher ──────────────────────────────────────────────────

  void _watchConnectivity() {
    _connSub?.cancel();
    _connSub = Connectivity().onConnectivityChanged.listen((result) {
      if (_disposed) return;
      final online = result == ConnectivityResult.mobile ||
                     result == ConnectivityResult.wifi   ||
                     result == ConnectivityResult.ethernet;
      if (online && !_serviceReachable) {
        // Network just restored — reconnect SSE and refresh status
        _connectSSE();
        refresh();
      }
    });
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
        _notifySafe();
      },
      onError: (_) {
        if (!_disposed) _startAdaptivePolling();
      },
      onDone: () {
        if (_disposed) return;
        // SSE stream ended — reconnect after a short delay
        _sseReconnectTimer = Timer(const Duration(seconds: 5), () {
          if (!_disposed) _connectSSE();
        });
      },
      cancelOnError: true,
    );
  }

  // ── Adaptive polling (SSE fallback) ───────────────────────────────────────

  void _startAdaptivePolling() {
    _pollTimer?.cancel();
    final interval = _status.connected
        ? const Duration(seconds: 10)
        : const Duration(seconds: 3);
    _pollTimer = Timer.periodic(interval, (_) {
      if (!_disposed) refresh();
    });
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Polls /status (and /qr when needed). Safe to call from any lifecycle state.
  Future<void> refresh() async {
    if (_disposed) return;
    _loading = true;
    _error   = null;
    _notifySafe();

    try {
      final statusData = await WhatsAppApiService.getStatus();
      _applyStatusData(statusData, withStats: true);

      // Fetch QR separately only when service has one but SSE hasn't delivered it
      if (!_status.connected && _status.qrData == null && _status.hasQr) {
        try {
          final qrData = await WhatsAppApiService.getQr();
          if (!_disposed) _status = WhatsAppStatus.mergeQr(_status, qrData);
        } catch (_) { /* QR fetch failure is non-fatal */ }
      }

      _serviceReachable = true;
    } catch (e) {
      final raw = e.toString().replaceFirst('Exception: ', '');
      _error            = _friendlyError(raw);
      _serviceReachable = false;
    }

    _loading = false;
    _notifySafe();
  }

  /// Sends POST /whatsapp/reconnect, then restarts SSE for instant QR delivery.
  Future<void> reconnect() async {
    if (_disposed) return;
    _loading = true;
    _error   = null;
    _notifySafe();

    try {
      await WhatsAppApiService.reconnect();
    } catch (_) { /* best-effort */ }

    // (Re)start SSE so QR appears the moment the server generates it
    _connectSSE();

    _loading = false;
    _notifySafe();
  }

  // ── Messaging helpers ─────────────────────────────────────────────────────

  Future<bool> sendTestMessage(String phone) async {
    try {
      await WhatsAppApiService.sendCustomMessage(
        phone:   phone,
        message: 'Test message from EduScan — WhatsApp service is working ✓',
      );
      return true;
    } catch (_) { return false; }
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
    } catch (_) { return false; }
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
    } catch (_) { return false; }
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  void _applyStatusData(Map<String, dynamic> data, {bool withStats = false}) {
    if (withStats) {
      _status = WhatsAppStatus.fromStatusJson(data);
    } else {
      // SSE payload — contains qrData inline, no stats
      _status = WhatsAppStatus(
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
    }
  }

  void _notifySafe() {
    if (!_disposed) notifyListeners();
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
