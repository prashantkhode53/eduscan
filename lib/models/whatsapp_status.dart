class WhatsAppStatus {
  final String status;       // initializing | qr_pending | connected | disconnected | reconnecting
  final bool connected;
  final DateTime? lastConnectedAt;
  final bool hasQr;
  final String? qrData;      // raw QR string for qr_flutter
  final String? qrBase64;    // base64 PNG fallback
  final int totalToday;
  final int sentToday;
  final int failedToday;
  final DateTime? lastSentAt;
  final String? initError;   // set when service fails to start Chromium/WhatsApp

  const WhatsAppStatus({
    required this.status,
    required this.connected,
    this.lastConnectedAt,
    required this.hasQr,
    this.qrData,
    this.qrBase64,
    this.totalToday  = 0,
    this.sentToday   = 0,
    this.failedToday = 0,
    this.lastSentAt,
    this.initError,
  });

  factory WhatsAppStatus.disconnected() => const WhatsAppStatus(
    status: 'disconnected', connected: false, hasQr: false,
  );

  factory WhatsAppStatus.fromStatusJson(Map<String, dynamic> json) {
    final stats = (json['stats'] as Map<String, dynamic>?) ?? {};
    return WhatsAppStatus(
      status:          json['status']     as String? ?? 'disconnected',
      connected:       json['connected']  as bool?   ?? false,
      lastConnectedAt: _parseDate(json['lastConnectedAt']),
      hasQr:           json['hasQr']      as bool?   ?? false,
      qrData:          json['qrData']     as String?,
      qrBase64:        json['qrBase64']   as String?,
      initError:       json['initError']  as String?,
      totalToday:      (stats['totalToday']  as num?)?.toInt() ?? 0,
      sentToday:       (stats['sentToday']   as num?)?.toInt() ?? 0,
      failedToday:     (stats['failedToday'] as num?)?.toInt() ?? 0,
      lastSentAt:      _parseDate(stats['lastSentAt']),
    );
  }

  factory WhatsAppStatus.mergeQr(WhatsAppStatus base, Map<String, dynamic> qrJson) {
    return WhatsAppStatus(
      status:          qrJson['status']    as String? ?? base.status,
      connected:       qrJson['connected'] as bool?   ?? base.connected,
      lastConnectedAt: base.lastConnectedAt,
      hasQr:           qrJson['hasQr']     as bool?   ?? base.hasQr,
      qrData:          qrJson['qrData']    as String? ?? base.qrData,
      qrBase64:        qrJson['qrBase64']  as String? ?? base.qrBase64,
      initError:       base.initError,
      totalToday:      base.totalToday,
      sentToday:       base.sentToday,
      failedToday:     base.failedToday,
      lastSentAt:      base.lastSentAt,
    );
  }

  String get displayStatus {
    switch (status) {
      case 'connected':     return 'Connected';
      case 'qr_pending':    return 'Scan QR Code';
      case 'reconnecting':  return 'Reconnecting...';
      case 'initializing':  return 'Starting up...';
      default:              return 'Disconnected';
    }
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }
}
