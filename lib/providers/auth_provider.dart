import 'package:flutter/material.dart';
import '../models/admin.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';

class AuthProvider extends ChangeNotifier {
  Admin? _admin;
  String? _token;
  bool _loading = false;
  String? _error;
  ThemeMode _themeMode = ThemeMode.system;

  Admin? get admin => _admin;
  String? get token => _token;
  bool get loading => _loading;
  String? get error => _error;
  bool get isLoggedIn => _token != null && _admin != null;
  ThemeMode get themeMode => _themeMode;

  AuthProvider() {
    _loadFromStorage();
  }

  Future<void> _loadFromStorage() async {
    _token = await StorageService.getToken();
    final adminJson = await StorageService.getAdmin();
    if (adminJson != null) {
      try {
        _admin = Admin.fromJson(adminJson);
      } catch (_) {
        _admin = null;
      }
    }
    final dark = await StorageService.isDarkMode();
    _themeMode = dark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }

  Future<bool> login(String username, String password) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await ApiService.login(username, password);
      _token = result['token'] as String;
      _admin = Admin.fromJson(result['admin'] as Map<String, dynamic>);
      await StorageService.saveToken(_token!);
      await StorageService.saveAdmin(_admin!.toJson());
      _loading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      _loading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    _token = null;
    _admin = null;
    await StorageService.clear();
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    await StorageService.saveDarkMode(_themeMode == ThemeMode.dark);
    notifyListeners();
  }
}
