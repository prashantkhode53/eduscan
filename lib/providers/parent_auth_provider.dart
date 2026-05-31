import 'package:flutter/material.dart';
import '../models/parent_user.dart';
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

  /// Called after successful face verification — stores JWT and user.
  Future<void> completeLogin({
    required String token,
    required Map<String, dynamic> studentData,
    required Map<String, dynamic> academyData,
  }) async {
    _token = token;
    _user = ParentUser(
      studentId:        studentData['id']          as String,
      studentFirstName: studentData['first_name']  as String,
      studentLastName:  studentData['last_name']   as String,
      parentName:       studentData['parent_name'] as String? ?? '',
      academySlug:      academyData['slug']        as String,
      academyName:      academyData['name']        as String,
    );
    await StorageService.saveParentToken(_token!);
    await StorageService.saveParentUser(_user!.toJson());
    notifyListeners();
  }

  Future<void> logout() async {
    _token = null;
    _user  = null;
    _error = null;
    await StorageService.clearParent();
    notifyListeners();
  }

  void setLoading(bool v) {
    _loading = v;
    if (v) _error = null;
    notifyListeners();
  }

  void setError(String? e) {
    _error   = e;
    _loading = false;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
