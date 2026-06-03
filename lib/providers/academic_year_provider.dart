import 'package:flutter/material.dart';
import '../services/academy_api_service.dart';

/// Holds the academic year the admin has selected on the Dashboard header.
/// All dependent modules (stats, courses, registration, CSV upload) read from
/// this provider so that changing the year propagates everywhere automatically.
class AcademicYearProvider extends ChangeNotifier {
  List<Map<String, dynamic>> _years = [];
  String? _selectedId;
  String  _selectedName = '';
  bool    _initialized  = false;
  bool    _loading      = false;

  List<Map<String, dynamic>> get years        => _years;
  String?                    get selectedId   => _selectedId;
  String                     get selectedName => _selectedName;
  bool                       get initialized  => _initialized;
  bool                       get loading      => _loading;

  /// Load years from the API and pre-select the current academic year.
  /// Safe to call multiple times — skips if already loaded.
  Future<void> init({bool force = false}) async {
    if (_initialized && !force) return;
    _loading = true;
    notifyListeners();
    try {
      final data = await AcademyApiService.getAcademicYears();
      _years = data.where((y) => y['status'] == 'active').toList();
      // Pre-select the year marked as current; fall back to first active year.
      final current = _years.firstWhere(
        (y) => y['is_current_year'] == true,
        orElse: () => _years.isNotEmpty ? _years.first : {},
      );
      if (current.isNotEmpty) {
        _selectedId   = current['id']                 as String?;
        _selectedName = current['academic_year_name'] as String? ?? '';
      }
      _initialized = true;
    } catch (_) {
      // Non-fatal — leave current selection unchanged.
    }
    _loading = false;
    notifyListeners();
  }

  /// Select a specific academic year.
  void select(String? id, String name) {
    if (_selectedId == id) return;
    _selectedId   = id;
    _selectedName = name;
    notifyListeners();
  }

  /// Clear state on logout so the next academy login starts fresh.
  void reset() {
    _years       = [];
    _selectedId  = null;
    _selectedName = '';
    _initialized = false;
    _loading     = false;
    notifyListeners();
  }
}
