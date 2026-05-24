import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityProvider extends ChangeNotifier {
  bool _isOnline = true;
  StreamSubscription<ConnectivityResult>? _subscription;

  bool get isOnline => _isOnline;

  ConnectivityProvider() {
    _init();
  }

  Future<void> _init() async {
    final result = await Connectivity().checkConnectivity();
    _isOnline = _hasConnection(result);
    notifyListeners();

    _subscription = Connectivity().onConnectivityChanged.listen((result) async {
      _isOnline = _hasConnection(result);
      notifyListeners();
    });
  }

  bool _hasConnection(ConnectivityResult result) {
    return result == ConnectivityResult.mobile ||
        result == ConnectivityResult.wifi ||
        result == ConnectivityResult.ethernet;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
