import 'package:flutter/material.dart';
import '../models/admin.dart';
import '../models/academy_user.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';

class AuthProvider extends ChangeNotifier {
  // ── Superadmin state ───────────────────────────────────────────────────────
  Admin? _admin;

  // ── Academy user state ─────────────────────────────────────────────────────
  AcademyUser? _academyUser;

  // ── Shared ─────────────────────────────────────────────────────────────────
  String? _token;
  bool _loading = false;
  String? _error;
  ThemeMode _themeMode = ThemeMode.system;

  // ── Getters ────────────────────────────────────────────────────────────────
  Admin?       get admin       => _admin;
  AcademyUser? get academyUser => _academyUser;
  String?      get token       => _token;
  bool         get loading     => _loading;
  String?      get error       => _error;
  ThemeMode    get themeMode   => _themeMode;

  bool get isLoggedIn    => _token != null && (_admin != null || _academyUser != null);
  bool get isSuperAdmin  => _admin != null;
  bool get isAcademyUser => _academyUser != null;

  AuthProvider() {
    _loadFromStorage();
  }

  Future<void> _loadFromStorage() async {
    _token = await StorageService.getToken();
    _themeMode = await StorageService.isDarkMode() ? ThemeMode.dark : ThemeMode.light;

    // Try to restore academy user first; fall back to superadmin
    final academyJson = await StorageService.getAcademyUser();
    if (academyJson != null) {
      try {
        _academyUser = AcademyUser.fromJson(academyJson);
      } catch (_) {
        _academyUser = null;
      }
    }

    if (_academyUser == null) {
      final adminJson = await StorageService.getAdmin();
      if (adminJson != null) {
        try {
          _admin = Admin.fromJson(adminJson);
        } catch (_) {
          _admin = null;
        }
      }
    }

    notifyListeners();
  }

  // ── Superadmin login ───────────────────────────────────────────────────────
  Future<bool> login(String username, String password) async {
    _setLoading(true);
    try {
      final result = await ApiService.login(username, password);
      _token = result['token'] as String;
      _admin = Admin.fromJson(result['admin'] as Map<String, dynamic>);
      _academyUser = null;
      await StorageService.saveToken(_token!);
      await StorageService.saveAdmin(_admin!.toJson());
      _setLoading(false);
      return true;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      _setLoading(false);
      return false;
    }
  }

  // ── Academy user login ─────────────────────────────────────────────────────
  Future<bool> loginAcademy(String email, String password, String slug) async {
    _setLoading(true);
    try {
      final result = await ApiService.loginAcademy(
        email: email,
        password: password,
        academySlug: slug.toLowerCase().trim(),
      );
      _token = result['token'] as String;

      final userMap    = result['user']    as Map<String, dynamic>;
      final academyMap = result['academy'] as Map<String, dynamic>;

      _academyUser = AcademyUser(
        userId:      userMap['id']      as String,
        academyId:   academyMap['id']   as String,
        academyName: academyMap['name'] as String,
        role:        userMap['role']    as String,
        name:        userMap['name']    as String,
        email:       userMap['email']   as String,
      );
      _admin = null;

      await StorageService.saveToken(_token!);
      await StorageService.saveAcademyUser(_academyUser!.toJson());
      await StorageService.saveAcademySlug(academyMap['slug'] as String);

      _setLoading(false);
      return true;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      _setLoading(false);
      return false;
    }
  }

  // ── Logout ─────────────────────────────────────────────────────────────────
  Future<void> logout() async {
    _token       = null;
    _admin       = null;
    _academyUser = null;
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

  void _setLoading(bool v) {
    _loading = v;
    if (v) _error = null;
    notifyListeners();
  }
}
