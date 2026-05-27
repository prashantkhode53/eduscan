import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Monitors network state and notifies listeners on changes.
class ConnectivityProvider extends ChangeNotifier {
  bool _isOnline  = true;
  bool _wasOnline = true;

  StreamSubscription<ConnectivityResult>? _subscription;

  // Fires whenever connectivity is RESTORED (offline → online).
  // WhatsAppProvider subscribes to this to auto-reconnect SSE.
  final StreamController<void> _reconnectController =
      StreamController<void>.broadcast();
  Stream<void> get onReconnected => _reconnectController.stream;

  bool get isOnline => _isOnline;

  ConnectivityProvider() {
    _init();
  }

  Future<void> _init() async {
    final result = await Connectivity().checkConnectivity();
    _isOnline  = _hasConnection(result);
    _wasOnline = _isOnline;
    notifyListeners();

    _subscription = Connectivity().onConnectivityChanged.listen((result) {
      _isOnline = _hasConnection(result);

      if (_isOnline && !_wasOnline) {
        // Just came back online — broadcast so consumers can reconnect
        _reconnectController.add(null);
      }
      _wasOnline = _isOnline;
      notifyListeners();
    });
  }

  bool _hasConnection(ConnectivityResult result) {
    return result == ConnectivityResult.mobile  ||
           result == ConnectivityResult.wifi    ||
           result == ConnectivityResult.ethernet;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _reconnectController.close();
    super.dispose();
  }
}
