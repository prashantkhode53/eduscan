import 'dart:io' show SocketException;
import 'package:http/http.dart' as http;

const String kNoNetworkMessage =
    'No internet connection. Please check your network and try again.';

/// HTTP client wrapper that converts low-level network failures into a
/// user-friendly exception before they reach any screen or provider.
class NetworkAwareClient extends http.BaseClient {
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      return await _inner.send(request);
    } on SocketException {
      throw Exception(kNoNetworkMessage);
    } on http.ClientException catch (e) {
      if (_isNetworkError(e.message)) throw Exception(kNoNetworkMessage);
      rethrow;
    }
  }

  static bool _isNetworkError(String msg) =>
      msg.contains('SocketException') ||
      msg.contains('Failed host lookup') ||
      msg.contains('No address associated') ||
      msg.contains('Connection refused') ||
      msg.contains('Network is unreachable') ||
      msg.contains('Connection reset');

  @override
  void close() => _inner.close();
}
