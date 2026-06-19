import 'dart:io';
import 'package:excel/excel.dart' hide Border;
import 'package:path_provider/path_provider.dart';
import '../utils/file_opener.dart';
import '../utils/date_utils.dart' as du;

/// Builds a child's attendance record (.xlsx) from the parent attendance
/// endpoint rows and opens it. Generated entirely on-device — no backend
/// file-serving endpoint.
///
/// Columns: Sr No | Date | Day | Status | Time In | Time Out | Duration
/// Plus a summary block (Present / Late / Absent / Attendance %).
class ParentAttendanceExcelService {
  ParentAttendanceExcelService._();

  static const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// [records] are the rows returned by ParentApiService.getAttendance.
  /// [periodLabel] is shown in the title and filename (e.g. 'Jun 2026' or a range).
  /// Returns the saved file path. Throws on failure (caller shows the error).
  static Future<String> generate({
    required List<Map<String, dynamic>> records,
    required String childName,
    required String academyName,
    required String periodLabel,
  }) async {
    final excel = Excel.createExcel();
    final defaultSheet = excel.getDefaultSheet() ?? 'Sheet1';
    excel.rename(defaultSheet, 'Attendance');
    final sheet = excel['Attendance'];

    final titleStyle = CellStyle(bold: true, fontSize: 14);
    final headerStyle = CellStyle(
      bold: true,
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
    );
    final summaryStyle = CellStyle(bold: true);

    var row = 0;
    void titleRow(String text, CellStyle style) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row));
      cell.value = TextCellValue(text);
      cell.cellStyle = style;
      row++;
    }

    // ── Title block ──────────────────────────────────────────────────────────
    titleRow(academyName.isEmpty ? 'Attendance Record' : academyName, titleStyle);
    titleRow('Attendance Record — $childName', summaryStyle);
    titleRow('Period: $periodLabel', CellStyle());
    row++; // blank spacer

    // ── Header row ───────────────────────────────────────────────────────────
    const headers = ['Sr No', 'Date', 'Day', 'Status', 'Time In', 'Time Out', 'Duration'];
    for (var c = 0; c < headers.length; c++) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row));
      cell.value = TextCellValue(headers[c]);
      cell.cellStyle = headerStyle;
    }
    row++;

    // ── Data rows (oldest→newest for a natural reading order) ─────────────────
    final ordered = [...records]..sort((a, b) =>
        (a['date']?.toString() ?? '').compareTo(b['date']?.toString() ?? ''));

    var present = 0, late = 0, absent = 0;
    for (var i = 0; i < ordered.length; i++) {
      final r = ordered[i];
      final status = (r['status'] as String? ?? '').toLowerCase();
      if (status == 'present') {
        present++;
      } else if (status == 'late') {
        late++;
      } else if (status == 'absent') {
        absent++;
      }

      final dateStr = du.fmtDate(r['date']?.toString());
      var col = 0;
      void put(CellValue v) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row)).value = v;
        col++;
      }

      put(IntCellValue(i + 1));
      put(TextCellValue(dateStr));
      put(TextCellValue(_dayLabel(r['date']?.toString())));
      put(TextCellValue(status.isEmpty ? '-' : _cap(status)));
      put(TextCellValue(du.fmtTimeOfDay(r['time_in'] as String?)));
      put(TextCellValue(du.fmtTimeOfDay(r['time_out'] as String?)));
      put(TextCellValue(_durationLabel(r['duration_mins'])));
      row++;
    }

    // ── Summary block ────────────────────────────────────────────────────────
    row++; // blank spacer
    final attended = present + late;
    final totalMarked = attended + absent;
    final pct = totalMarked > 0 ? (attended / totalMarked * 100) : 0;

    void summary(String label, String value) {
      final l = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row));
      l.value = TextCellValue(label);
      l.cellStyle = summaryStyle;
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value =
          TextCellValue(value);
      row++;
    }

    summary('Present', '$present');
    summary('Late', '$late');
    summary('Absent', '$absent');
    summary('Attendance %', '${pct.toStringAsFixed(0)}%');

    // ── Column widths ─────────────────────────────────────────────────────────
    const widths = [6.0, 14.0, 8.0, 10.0, 11.0, 11.0, 12.0];
    for (var c = 0; c < widths.length; c++) {
      sheet.setColumnWidth(c, widths[c]);
    }

    // ── Save + open ───────────────────────────────────────────────────────────
    final bytes = excel.encode();
    if (bytes == null) throw Exception('Failed to encode the Excel workbook.');

    final dir = await getApplicationDocumentsDirectory();
    final fileName = _fileName(childName, periodLabel);
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes);
    await FileOpener.open(file.path);
    return file.path;
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static String _dayLabel(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final d = DateTime.parse(dateStr);
      return _dayNames[d.weekday - 1];
    } catch (_) { return ''; }
  }

  static String _durationLabel(dynamic mins) {
    final m = (mins as num?)?.toInt() ?? 0;
    if (m <= 0) return '-';
    final h = m ~/ 60;
    final r = m % 60;
    return h > 0 ? '${h}h ${r}m' : '${r}m';
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String _fileName(String childName, String periodLabel) {
    final name = _sanitize(childName.isEmpty ? 'Student' : childName);
    final period = _sanitize(periodLabel.isEmpty ? 'Records' : periodLabel);
    return 'Attendance_${name}_$period.xlsx';
  }

  static String _sanitize(String s) => s
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
}
