import 'package:flutter/foundation.dart';
import '../models/student.dart';
import '../services/api_service.dart';

class StudentProvider extends ChangeNotifier {
  List<Student> _students = [];
  bool _loading = false;
  String? _error;
  int _total = 0;
  int _page = 1;
  final int _limit = 50;

  List<Student> get students => _students;
  bool get loading => _loading;
  String? get error => _error;
  int get total => _total;
  bool get hasMore => _students.length < _total;

  Future<void> fetchStudents({
    String? classGrade,
    String? division,
    String? search,
    String status = 'active',
    bool refresh = false,
  }) async {
    if (refresh) {
      _page = 1;
      _students = [];
    }
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await ApiService.getStudents(
        classGrade: classGrade,
        division: division,
        search: search,
        status: status,
        page: _page,
        limit: _limit,
      );
      final newStudents = (result['students'] as List)
          .map((e) => Student.fromJson(e as Map<String, dynamic>))
          .toList();
      final pagination = result['pagination'] as Map<String, dynamic>;
      _total = (pagination['total'] as num).toInt();
      if (refresh) {
        _students = newStudents;
      } else {
        _students = [..._students, ...newStudents];
      }
      _page++;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
    }
    _loading = false;
    notifyListeners();
  }

  Future<Student?> getStudent(String id) async {
    try {
      final data = await ApiService.getStudentById(id);
      return Student.fromJson(data['student'] as Map<String, dynamic>);
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      return null;
    }
  }

  Future<Student?> createStudent(StudentRegistration reg) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final data = await ApiService.createStudent(reg.toJson());
      final student = Student.fromJson(data as Map<String, dynamic>);
      _students = [student, ..._students];
      _total++;
      _loading = false;
      notifyListeners();
      return student;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      _loading = false;
      notifyListeners();
      return null;
    }
  }

  Future<Student?> updateStudent(String id, Map<String, dynamic> fields) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final data = await ApiService.updateStudent(id, fields);
      final updated = Student.fromJson(data as Map<String, dynamic>);
      final idx = _students.indexWhere((s) => s.id == id);
      if (idx >= 0) _students[idx] = updated;
      _loading = false;
      notifyListeners();
      return updated;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      _loading = false;
      notifyListeners();
      return null;
    }
  }

  Future<bool> deleteStudent(String id) async {
    _loading = true;
    notifyListeners();
    try {
      await ApiService.deleteStudent(id);
      _students.removeWhere((s) => s.id == id);
      _total--;
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

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
