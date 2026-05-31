import 'package:flutter/material.dart';
import '../models/parent_user.dart';
import '../services/parent_api_service.dart';
import '../services/storage_service.dart';

class ParentAuthProvider extends ChangeNotifier {
  ParentUser? _user;
  String?     _token;
  bool        _loading = false;
  String?     _error;

  ParentUser? get user      => _user;
  String?     get token     => _token;
  bool        get loading   => _loading;
  String?     get error     => _error;
  bool        get isLoggedIn => _token != null && _user != null;

  ParentAuthProvider() {
    _restore();
  }

  Future<void> _restore() async {
    _token = await StorageService.getParentToken();
    final json = await StorageService.getParentUser();
    if (_token != null && json != null) {
      try { _user = ParentUser.fromJson(json); } catch (_) {}
    }
    notifyListeners();
  }

  Future<bool> login({
    required String academySlug,
    required String studentId,
    required String mobile,
  }) async {
    _loading = true;
    _error   = null;
    notifyListeners();
    try {
      final data    = await ParentApiService.login(
        academySlug: academySlug,
        studentId:   studentId,
        mobile:      mobile,
      );
      _token = data['token'] as String;

      final s = data['student'] as Map<String, dynamic>;
      final a = data['academy'] as Map<String, dynamic>;
      _user = ParentUser(
        studentId:        s['id']          as String,
        studentFirstName: s['first_name']  as String,
        studentLastName:  s['last_name']   as String,
        parentName:       s['parent_name'] as String? ?? '',
        academySlug:      a['slug']        as String,
        academyName:      a['name']        as String,
      );

      await StorageService.saveParentToken(_token!);
      await StorageService.saveParentUser(_user!.toJson());

      _loading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error   = e.toString().replaceFirst('Exception: ', '');
      _loading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    _token = null;
    _user  = null;
    await StorageService.clearParent();
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
