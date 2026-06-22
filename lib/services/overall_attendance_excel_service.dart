import 'dart:io';
import 'package:excel/excel.dart' hide Border;
import 'package:path_provider/path_provider.dart';
import '../utils/file_opener.dart';

/// Builds the "Overall Attendance Data" report (.xlsx) from the list of record
/// maps returned by `AcademyApiService.getOverallAttendance`, then opens it.
///
/// Columns (in the spec's exact order):
///   Student ID | Student Name | Academic Year | Course Name | Present Date |
///   Day | First Check-In | Last Check-Out | Total Time Spent | Attendance Status |
///   Attendance Percentage | Remarks
///
/// The caller passes the already-filtered records, so the export mirrors exactly
/// what the grid shows (filters are applied server-side before this runs).
class OverallAttendanceExcelService {
  OverallAttendanceExcelService._();

  static const _headers = <String>[
    'Student ID',
    'Student Name',
    'Academic Year',
    'Course Name',
    'Present Date',
    'Day',
    'First Check-In',
    'Last Check-Out',
    'Total Time Spent',
    'Attendance Status',
    'Attendance Percentage',
    'Remarks',
  ];

  /// [records] is the list returned by getOverallAttendance.
  /// Returns the saved file path. Throws on failure (caller shows the error).
  static Future<String> generate(List<Map<String, dynamic>> records) async {
    final excel = Excel.createExcel();
    final defaultSheet = excel.getDefaultSheet() ?? 'Sheet1';
    excel.rename(defaultSheet, 'Attendance');
    final sheet = excel['Attendance'];

    final headerStyle = CellStyle(
      bold: true,
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
    );

    // ── Header row ──────────────────────────────────────────────────────────
    for (var c = 0; c < _headers.length; c++) {
      final cell = sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0));
      cell.value = TextCellValue(_headers[c]);
      cell.cellStyle = headerStyle;
    }

    // ── Data rows ───────────────────────────────────────────────────────────
    for (var i = 0; i < records.length; i++) {
      final m = records[i];
      final r = i + 1; // row 0 is the header
      var col = 0;
      void put(CellValue v) {
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: r))
            .value = v;
        col++;
      }

      final pct = (m['attendance_pct'] as num?)?.toDouble() ?? 0;

      put(TextCellValue(m['student_id'] as String? ?? ''));      // Student ID
      put(TextCellValue(m['name'] as String? ?? ''));            // Student Name
      put(TextCellValue(m['academic_year'] as String? ?? ''));   // Academic Year
      put(TextCellValue(m['course_name'] as String? ?? ''));     // Course Name
      put(TextCellValue(m['date'] as String? ?? ''));            // Present Date
      put(TextCellValue(m['day'] as String? ?? ''));             // Day
      put(TextCellValue(m['first_check_in'] as String? ?? ''));  // First Check-In
      put(TextCellValue(m['last_check_out'] as String? ?? ''));  // Last Check-Out
      put(TextCellValue(formatDuration(m['total_mins'])));       // Total Time Spent
      put(TextCellValue(statusLabel(m['status'] as String?)));   // Attendance Status
      put(TextCellValue('${pct.toStringAsFixed(2)}%'));          // Attendance %
      put(TextCellValue(m['remarks'] as String? ?? ''));         // Remarks
    }

    _applyColumnWidths(sheet);
    _freezeHeader(excel, 'Attendance');

    final bytes = excel.encode();
    if (bytes == null) {
      throw Exception('Failed to encode the Excel workbook.');
    }

    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/${_fileName()}');
    await file.writeAsBytes(bytes);
    await FileOpener.open(file.path);
    return file.path;
  }

  // ── Shared formatters (also used by the on-screen grid) ────────────────────

  /// Minutes → 'HH:MM' (e.g. 465 → '07:45'). Empty when null/zero.
  static String formatDuration(dynamic mins) {
    final m = (mins as num?)?.toInt() ?? 0;
    if (m <= 0) return '';
    final h = m ~/ 60;
    final r = m % 60;
    return '${h.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  /// DB status → display label. A 'late' row counts as present (the student
  /// did attend), so it shows "Present" — we no longer surface late-arrival
  /// separately to avoid confusion over an unreliable flag.
  static String statusLabel(String? status) {
    switch (status) {
      case 'present': return 'Present';
      case 'late':    return 'Present';
      case 'absent':  return 'Absent';
      default:        return status ?? '';
    }
  }

  // ── Layout helpers ─────────────────────────────────────────────────────────

  static void _applyColumnWidths(Sheet sheet) {
    const widths = [
      16.0, // Student ID
      22.0, // Student Name
      14.0, // Academic Year
      20.0, // Course Name
      13.0, // Present Date
      11.0, // Day
      13.0, // First Check-In
      14.0, // Last Check-Out
      15.0, // Total Time Spent
      16.0, // Attendance Status
      18.0, // Attendance Percentage
      24.0, // Remarks
    ];
    for (var c = 0; c < widths.length; c++) {
      sheet.setColumnWidth(c, widths[c]);
    }
  }

  static void _freezeHeader(Excel excel, String sheetName) {
    try {
      // ignore: avoid_dynamic_calls
      (excel as dynamic).setSheetFreeze(sheetName, rows: 1);
    } catch (_) {}
  }

  /// Overall_Attendance_{YYYYMMDD_HHMMSS}.xlsx (IST timestamp).
  static String _fileName() {
    final ist = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    final ts = '${ist.year.toString().padLeft(4, '0')}'
        '${ist.month.toString().padLeft(2, '0')}'
        '${ist.day.toString().padLeft(2, '0')}_'
        '${ist.hour.toString().padLeft(2, '0')}'
        '${ist.minute.toString().padLeft(2, '0')}'
        '${ist.second.toString().padLeft(2, '0')}';
    return 'Overall_Attendance_$ts.xlsx';
  }
}
