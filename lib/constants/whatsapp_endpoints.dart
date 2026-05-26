import 'api_endpoints.dart';

/// WhatsApp module endpoints — served by the SAME existing Render backend.
/// Base URL is [ApiEndpoints.baseUrl]; no separate service needed.
class WhatsAppEndpoints {
  static String get _base => ApiEndpoints.baseUrl;

  static String get status       => '$_base/whatsapp/status';
  static String get qr           => '$_base/whatsapp/qr';
  static String get events       => '$_base/whatsapp/events';
  static String get reconnect    => '$_base/whatsapp/reconnect';
  static String get sendCheckin  => '$_base/whatsapp/send-checkin';
  static String get sendCheckout => '$_base/whatsapp/send-checkout';
  static String get sendCustom   => '$_base/whatsapp/send-custom';
}
