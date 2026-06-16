import 'dart:io';
import 'package:excel/excel.dart' hide Border;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// Builds the installment-wise fee-collection ledger (.xlsx) from the
/// `getFeesExportData` payload and opens it.
///
/// Columns: Sr No | Student ID | Student Name | Course (Subjects) |
/// Mobile Number | <12 month columns> | Total Fees Received
/// Plus a bold GRAND TOTAL row summing each month and the overall total.
class FeeExcelService {
  FeeExcelService._();

  static const _monthNames = [
    'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
  ];

  /// [data] is the `data` map returned by AcademyApiService.getFeesExportData.
  /// Returns the saved file path. Throws on failure (caller shows the error).
  static Future<String> generate(Map<String, dynamic> data) async {
    final yearName    = (data['academic_year_name'] as String?) ?? '';
    final courseLabel = (data['course_label'] as String?) ?? '';
    final startMonth  = (data['start_month'] as String?); // 'YYYY-MM' fallback
    final students    = (data['students'] as List? ?? [])
        .cast<Map<String, dynamic>>();

    // ── Determine the 12-month column sequence ────────────────────────────────
    // Start at the earliest payment month across all students; fall back to the
    // academic-year start month when there are no payments at all.
    final orderedMonths = _buildMonthSequence(students, startMonth);

    final excel = Excel.createExcel();
    // Rename the default sheet to a friendly name and drop any extras.
    final defaultSheet = excel.getDefaultSheet() ?? 'Sheet1';
    excel.rename(defaultSheet, 'Fee Collection');
    final sheet = excel['Fee Collection'];

    // ── Styles ────────────────────────────────────────────────────────────────
    final headerStyle = CellStyle(
      bold: true,
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
    );
    final totalStyle = CellStyle(bold: true);

    // ── Header row ────────────────────────────────────────────────────────────
    final headers = <String>[
      'Sr No', 'Student ID', 'Student Name', 'Course (Subjects)',
      'Mobile Number',
      ...orderedMonths.map(_monthLabel),
      'Total Fees Received',
    ];
    for (var c = 0; c < headers.length; c++) {
      final cell = sheet.cell(
          CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0));
      cell.value = TextCellValue(headers[c]);
      cell.cellStyle = headerStyle;
    }

    // ── Data rows ─────────────────────────────────────────────────────────────
    final monthTotals = List<double>.filled(orderedMonths.length, 0);
    double grandTotal = 0;

    for (var i = 0; i < students.length; i++) {
      final s        = students[i];
      final monthly  = (s['monthly'] as Map?)?.cast<String, dynamic>() ?? {};
      final rowTotal = (s['total'] as num?)?.toDouble() ?? 0;
      grandTotal    += rowTotal;
      final r = i + 1; // row 0 is the header

      var col = 0;
      void put(CellValue v) {
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: r))
            .value = v;
        col++;
      }

      put(IntCellValue(i + 1));                                   // Sr No
      put(TextCellValue(s['student_id'] as String? ?? ''));       // Student ID
      put(TextCellValue(s['name'] as String? ?? ''));             // Student Name
      put(TextCellValue(s['course_label'] as String? ?? ''));     // Course (Subjects)
      put(TextCellValue(s['mobile'] as String? ?? ''));           // Mobile

      for (var m = 0; m < orderedMonths.length; m++) {
        final amt = (monthly[orderedMonths[m]] as num?)?.toDouble() ?? 0;
        monthTotals[m] += amt;
        // Blank cell when nothing was collected that month (keeps the sheet clean).
        put(amt == 0 ? TextCellValue('') : DoubleCellValue(amt));
      }
      put(DoubleCellValue(rowTotal));                             // Total
    }

    // ── Grand total row (bold) ────────────────────────────────────────────────
    final gtRow = students.length + 1;
    // Label spans the leading identity columns; put the label in the
    // "Student Name" column for readability, matching the spec's layout.
    final labelCol = 2;
    final gtLabel = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: labelCol, rowIndex: gtRow));
    gtLabel.value = TextCellValue('GRAND TOTAL');
    gtLabel.cellStyle = totalStyle;

    final firstMonthCol = 5; // after Sr No, ID, Name, Course, Mobile
    for (var m = 0; m < orderedMonths.length; m++) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(
          columnIndex: firstMonthCol + m, rowIndex: gtRow));
      cell.value = DoubleCellValue(monthTotals[m]);
      cell.cellStyle = totalStyle;
    }
    final finalCell = sheet.cell(CellIndex.indexByColumnRow(
        columnIndex: firstMonthCol + orderedMonths.length, rowIndex: gtRow));
    finalCell.value = DoubleCellValue(grandTotal);
    finalCell.cellStyle = totalStyle;

    // ── Formatting: freeze header + column widths ─────────────────────────────
    _applyColumnWidths(sheet, orderedMonths.length);
    _freezeHeader(excel, 'Fee Collection');

    // ── Save + open ───────────────────────────────────────────────────────────
    final bytes = excel.encode();
    if (bytes == null) {
      throw Exception('Failed to encode the Excel workbook.');
    }

    final dir = await getApplicationDocumentsDirectory();
    final fileName = _fileName(yearName, courseLabel);
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes);
    await OpenFilex.open(file.path);
    return file.path;
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// 12 sequential 'YYYY-MM' keys starting at the earliest payment month across
  /// all students (fallback: [startMonthFallback], else current month).
  static List<String> _buildMonthSequence(
      List<Map<String, dynamic>> students, String? startMonthFallback) {
    String? earliest;
    for (final s in students) {
      final monthly = (s['monthly'] as Map?)?.cast<String, dynamic>() ?? {};
      for (final k in monthly.keys) {
        if (earliest == null || k.compareTo(earliest) < 0) earliest = k;
      }
    }
    final start = earliest ?? startMonthFallback ?? _ym(DateTime.now());

    final parts = start.split('-');
    var year  = int.tryParse(parts[0]) ?? DateTime.now().year;
    var month = int.tryParse(parts.length > 1 ? parts[1] : '1') ?? 1;

    final months = <String>[];
    for (var i = 0; i < 12; i++) {
      months.add('${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}');
      month++;
      if (month > 12) { month = 1; year++; }
    }
    return months;
  }

  static String _ym(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  /// 'YYYY-MM' → short month label ('May'). Includes the year when the sequence
  /// crosses into a new calendar year would be ambiguous; kept short per spec.
  static String _monthLabel(String ym) {
    final m = int.tryParse(ym.split('-').last) ?? 1;
    return _monthNames[(m - 1).clamp(0, 11)];
  }

  static void _applyColumnWidths(Sheet sheet, int monthCount) {
    // Sr No, Student ID, Student Name, Course (Subjects), Mobile
    const baseWidths = [6.0, 16.0, 22.0, 28.0, 15.0];
    for (var c = 0; c < baseWidths.length; c++) {
      sheet.setColumnWidth(c, baseWidths[c]);
    }
    for (var m = 0; m < monthCount; m++) {
      sheet.setColumnWidth(baseWidths.length + m, 9.0);
    }
    sheet.setColumnWidth(baseWidths.length + monthCount, 18.0); // Total
  }

  static void _freezeHeader(Excel excel, String sheetName) {
    // excel 4.x exposes setSheetFreeze on some builds; guard so a missing API
    // never breaks the export (the data is correct regardless of freeze).
    try {
      // ignore: avoid_dynamic_calls
      (excel as dynamic).setSheetFreeze(sheetName, rows: 1);
    } catch (_) {}
  }

  /// Fees_Collection_{Year}_{Course}_{YYYYMMDD_HHMMSS}.xlsx (IST timestamp).
  static String _fileName(String yearName, String courseLabel) {
    final ist = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    final ts = '${ist.year.toString().padLeft(4, '0')}'
        '${ist.month.toString().padLeft(2, '0')}'
        '${ist.day.toString().padLeft(2, '0')}_'
        '${ist.hour.toString().padLeft(2, '0')}'
        '${ist.minute.toString().padLeft(2, '0')}'
        '${ist.second.toString().padLeft(2, '0')}';
    final y = _sanitize(yearName.isEmpty ? 'Year' : yearName);
    final c = _sanitize(courseLabel.isEmpty ? 'Course' : courseLabel);
    return 'Fees_Collection_${y}_${c}_$ts.xlsx';
  }

  static String _sanitize(String s) => s
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
}
