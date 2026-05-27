import 'dart:async';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/whatsapp_status.dart';
import '../services/whatsapp_api_service.dart';

class WhatsAppProvider extends ChangeNotifier with WidgetsBindingObserver {
  WhatsAppStatus _status           = WhatsAppStatus.disconnected();
  bool           _loading          = false;
  String?        _error;
  bool           _serviceReachable = false;
  bool           _disposed         = false;

  StreamSubscription<Map<String, dynamic>>? _sseSub;
  StreamSubscription<ConnectivityResult>?   _connSub;
  Timer? _pollTimer;
  Timer? _sseReconnectTimer;

  // SSE retry backoff: 5s → 10s → 20s → 40s → max 60s
  int _sseRetryCount = 0;

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
        _connectSSE();
        refresh();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _sseSub?.cancel();          _sseSub = null;
        _pollTimer?.cancel();       _pollTimer = null;
        _sseReconnectTimer?.cancel(); _sseReconnectTimer = null;
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
    // Stop polling the moment SSE is (re)established — SSE handles real-time now
    _pollTimer?.cancel();
    _pollTimer = null;

    _sseSub = WhatsAppApiService.streamStatus().listen(
      (data) {
        if (_disposed) return;
        _sseRetryCount = 0;       // successful data — reset backoff
        _pollTimer?.cancel();     // belt-and-suspenders: kill any lingering poll
        _pollTimer = null;
        _applyStatusData(data);
        _serviceReachable = true;
        _error            = null;
        _notifySafe();
      },
      onError: (_) {
        // SSE failed — fall back to silent polling until SSE recovers
        if (!_disposed) _startSilentPolling();
      },
      onDone: () {
        if (_disposed) return;
        // Server closed stream — reconnect with exponential backoff
        final delaySec = min(5 * (1 << _sseRetryCount), 60);
        _sseRetryCount++;
        _sseReconnectTimer = Timer(Duration(seconds: delaySec), () {
          if (!_disposed) _connectSSE();
        });
      },
      cancelOnError: true,
    );
  }

  // ── Silent polling (SSE fallback) ─────────────────────────────────────────
  // Background polls NEVER set _loading = true so the UI doesn't flash.
  // Intervals are long because SSE is the primary mechanism.

  void _startSilentPolling() {
    _pollTimer?.cancel();
    // 15 s when disconnected (waiting for QR / reconnect)
    // 30 s when connected (heartbeat check only)
    final interval = _status.connected
        ? const Duration(seconds: 30)
        : const Duration(seconds: 15);
    _pollTimer = Timer.periodic(interval, (_) {
      if (!_disposed) _silentPoll();
    });
  }

  /// Fetches latest status silently — no loading indicator, no UI flash.
  Future<void> _silentPoll() async {
    if (_disposed) return;
    try {
      final data = await WhatsAppApiService.getStatus();
      _applyStatusData(data, withStats: true);
      if (!_status.connected && _status.qrData == null && _status.hasQr) {
        try {
          final qrData = await WhatsAppApiService.getQr();
          if (!_disposed) _status = WhatsAppStatus.mergeQr(_status, qrData);
        } catch (_) {}
      }
      _serviceReachable = true;
      _error            = null;
    } catch (_) {
      _serviceReachable = false;
    }
    _notifySafe(); // one notify, no _loading flip
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// User-initiated refresh — shows the loading spinner once.
  Future<void> refresh() async {
    if (_disposed) return;
    _loading = true;
    _error   = null;
    _notifySafe();

    try {
      final statusData = await WhatsAppApiService.getStatus();
      _applyStatusData(statusData, withStats: true);

      if (!_status.connected && _status.qrData == null && _status.hasQr) {
        try {
          final qrData = await WhatsAppApiService.getQr();
          if (!_disposed) _status = WhatsAppStatus.mergeQr(_status, qrData);
        } catch (_) {}
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

  /// Sends POST /whatsapp/reconnect then restarts SSE for instant QR delivery.
  /// No-op if the session is already connected — never destroys a live session.
  Future<void> reconnect() async {
    if (_disposed) return;

    // If already connected, just do a silent refresh — don't touch the backend session
    if (_status.connected) {
      await refresh();
      return;
    }

    _loading = true;
    _error   = null;
    _notifySafe();

    try {
      await WhatsAppApiService.reconnect();
    } catch (_) {}

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
