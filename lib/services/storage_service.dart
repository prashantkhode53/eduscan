import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const _keyToken        = 'jwt_token';
  static const _keyAdmin        = 'admin_data';
  static const _keyKioskKey     = 'kiosk_api_key';
  static const _keyLastSync     = 'last_sync_time';
  static const _keyDarkMode     = 'dark_mode';
  static const _keyApiBaseUrl   = 'api_base_url';
  static const _keyAcademySlug  = 'academy_slug';
  static const _keyAcademyUser  = 'academy_user';

  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyToken, token);
  }

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyToken);
  }

  static Future<void> saveAdmin(Map<String, dynamic> admin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAdmin, jsonEncode(admin));
  }

  static Future<Map<String, dynamic>?> getAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyAdmin);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveKioskKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyKioskKey, key);
  }

  static Future<String?> getKioskKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyKioskKey);
  }

  static Future<void> saveLastSyncTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastSync, time.toIso8601String());
  }

  static Future<DateTime?> getLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyLastSync);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  static Future<void> saveDarkMode(bool isDark) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDarkMode, isDark);
  }

  static Future<bool> isDarkMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDarkMode) ?? false;
  }

  static Future<void> saveApiBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyApiBaseUrl, url);
  }

  static Future<String?> getApiBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyApiBaseUrl);
  }

  static Future<void> saveAcademySlug(String slug) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAcademySlug, slug);
  }

  static Future<String?> getAcademySlug() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyAcademySlug);
  }

  static Future<void> saveAcademyUser(Map<String, dynamic> user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAcademyUser, jsonEncode(user));
  }

  static Future<Map<String, dynamic>?> getAcademyUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyAcademyUser);
    if (raw == null) return null;
    try { return jsonDecode(raw) as Map<String, dynamic>; } catch (_) { return null; }
  }

  // ── Parent ────────────────────────────────────────────────────────────────

  static const _keyParentToken = 'parent_token';
  static const _keyParentUser  = 'parent_user';

  static Future<void> saveParentToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyParentToken, token);
  }

  static Future<String?> getParentToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyParentToken);
  }

  static Future<void> saveParentUser(Map<String, dynamic> user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyParentUser, jsonEncode(user));
  }

  static Future<Map<String, dynamic>?> getParentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyParentUser);
    if (raw == null) return null;
    try { return jsonDecode(raw) as Map<String, dynamic>; } catch (_) { return null; }
  }

  static Future<void> clearParent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyParentToken);
    await prefs.remove(_keyParentUser);
  }

  // ─────────────────────────────────────────────────────────────────────────

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyToken);
    await prefs.remove(_keyAdmin);
  }

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }
}
