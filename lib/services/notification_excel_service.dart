import 'dart:io';
import 'package:excel/excel.dart' hide Border;
import 'package:path_provider/path_provider.dart';
import '../utils/file_opener.dart';
import '../utils/date_utils.dart' as du;

/// Builds the sent-notifications history (.xlsx) from the full broadcast list
/// returned by AcademyApiService.getAllSentNotifications, and opens it.
///
/// Columns: Sr No | Date & Time | Message | Sent By |
///          Recipients | Delivered | Failed | Status
class NotificationExcelService {
  NotificationExcelService._();

  /// [rows] is the full list of `parent_notifications` rows (newest-first).
  /// Returns the saved file path. Throws on failure (caller shows the error).
  static Future<String> generate(List<Map<String, dynamic>> rows) async {
    final excel = Excel.createExcel();
    final defaultSheet = excel.getDefaultSheet() ?? 'Sheet1';
    excel.rename(defaultSheet, 'Notifications');
    final sheet = excel['Notifications'];

    final headerStyle = CellStyle(
      bold: true,
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
    );

    // ── Header row ────────────────────────────────────────────────────────────
    const headers = <String>[
      'Sr No', 'Date & Time', 'Message', 'Sent By',
      'Recipients', 'Delivered', 'Failed', 'Status',
    ];
    for (var c = 0; c < headers.length; c++) {
      final cell = sheet.cell(
          CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0));
      cell.value = TextCellValue(headers[c]);
      cell.cellStyle = headerStyle;
    }

    // ── Data rows ─────────────────────────────────────────────────────────────
    for (var i = 0; i < rows.length; i++) {
      final n      = rows[i];
      final total  = (n['recipient_count'] as num?)?.toInt() ?? 0;
      final ok     = (n['success_count']   as num?)?.toInt() ?? 0;
      final failed = (n['failed_count']    as num?)?.toInt() ?? 0;
      final r = i + 1; // row 0 is the header

      var col = 0;
      void put(CellValue v) {
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: r))
            .value = v;
        col++;
      }

      put(IntCellValue(i + 1));                                     // Sr No
      put(TextCellValue(du.fmtDateTime(n['created_at']?.toString()))); // Date & Time
      put(TextCellValue(n['message']?.toString() ?? ''));          // Message
      put(TextCellValue(n['sent_by_name']?.toString() ?? ''));     // Sent By
      put(IntCellValue(total));                                    // Recipients
      put(IntCellValue(ok));                                       // Delivered
      put(IntCellValue(failed));                                   // Failed
      put(TextCellValue(_statusLabel(n['status']?.toString())));   // Status
    }

    _applyColumnWidths(sheet);
    _freezeHeader(excel, 'Notifications');

    // ── Save + open ───────────────────────────────────────────────────────────
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

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static String _statusLabel(String? status) => switch (status) {
        'sent'    => 'Sent',
        'partial' => 'Partial',
        'failed'  => 'Failed',
        _         => status ?? '',
      };

  static void _applyColumnWidths(Sheet sheet) {
    // Sr No, Date & Time, Message, Sent By, Recipients, Delivered, Failed, Status
    const widths = [6.0, 22.0, 50.0, 20.0, 12.0, 11.0, 9.0, 10.0];
    for (var c = 0; c < widths.length; c++) {
      sheet.setColumnWidth(c, widths[c]);
    }
  }

  static void _freezeHeader(Excel excel, String sheetName) {
    // excel 4.x exposes setSheetFreeze on some builds; guard so a missing API
    // never breaks the export (the data is correct regardless of freeze).
    try {
      // ignore: avoid_dynamic_calls
      (excel as dynamic).setSheetFreeze(sheetName, rows: 1);
    } catch (_) {}
  }

  /// Sent_Notifications_{YYYYMMDD_HHMMSS}.xlsx (IST timestamp).
  static String _fileName() {
    final ist = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    final ts = '${ist.year.toString().padLeft(4, '0')}'
        '${ist.month.toString().padLeft(2, '0')}'
        '${ist.day.toString().padLeft(2, '0')}_'
        '${ist.hour.toString().padLeft(2, '0')}'
        '${ist.minute.toString().padLeft(2, '0')}'
        '${ist.second.toString().padLeft(2, '0')}';
    return 'Sent_Notifications_$ts.xlsx';
  }
}
