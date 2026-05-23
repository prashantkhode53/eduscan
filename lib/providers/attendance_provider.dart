import 'package:flutter/foundation.dart';
import '../models/attendance.dart';
import '../services/api_service.dart';

class AttendanceProvider extends ChangeNotifier {
  List<Attendance> _records = [];
  bool _loading = false;
  String? _error;
  int _total = 0;

  List<Attendance> get records => _records;
  bool get loading => _loading;
  String? get error => _error;
  int get total => _total;

  Map<String, dynamic>? _dashboardStats;
  Map<String, dynamic>? get dashboardStats => _dashboardStats;

  List<Map<String, dynamic>> _weeklyStats = [];
  List<Map<String, dynamic>> get weeklyStats => _weeklyStats;

  List<dynamic> _recentActivity = [];
  List<dynamic> get recentActivity => _recentActivity;

  Future<void> fetchAttendance({
    String? date,
    String? dateFrom,
    String? dateTo,
    String? classGrade,
    String? division,
    String? studentId,
    int page = 1,
    int limit = 100,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await ApiService.getAttendance(
        date: date,
        dateFrom: dateFrom,
        dateTo: dateTo,
        classGrade: classGrade,
        division: division,
        studentId: studentId,
        page: page,
        limit: limit,
      );
      _records = (result['records'] as List)
          .map((e) => Attendance.fromJson(e as Map<String, dynamic>))
          .toList();
      final pagination = result['pagination'] as Map<String, dynamic>;
      _total = (pagination['total'] as num).toInt();
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
    }
    _loading = false;
    notifyListeners();
  }

  Future<void> fetchDashboardStats() async {
    try {
      _dashboardStats = await ApiService.getDashboardStats();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> fetchWeeklyStats() async {
    try {
      final data = await ApiService.getWeeklyStats();
      _weeklyStats = List<Map<String, dynamic>>.from(data);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> fetchRecentActivity() async {
    try {
      final data = await ApiService.getRecentActivity();
      _recentActivity = data;
      notifyListeners();
    } catch (_) {}
  }

  Future<bool> updateAttendance(String id, Map<String, dynamic> fields) async {
    try {
      final data = await ApiService.updateAttendance(id, fields);
      final updated = Attendance.fromJson(data as Map<String, dynamic>);
      final idx = _records.indexWhere((r) => r.id == id);
      if (idx >= 0) _records[idx] = updated;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      return false;
    }
  }

  Future<bool> bulkMarkAbsent(String date, {String? classGrade, String? division}) async {
    _loading = true;
    notifyListeners();
    try {
      await ApiService.bulkMarkAbsent(date, classGrade: classGrade, division: division);
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
