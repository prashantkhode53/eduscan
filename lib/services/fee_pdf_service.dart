import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Generates a professional fee statement PDF and opens it.
class FeePdfService {
  static final _money = NumberFormat('#,##0', 'en_IN');

  static String _fmt(double v) => '${_money.format(v)}';
  static String _money2(dynamic v) => '${_money.format((double.tryParse(v?.toString() ?? '') ?? 0))}';

  static String _fmtDate(dynamic raw) {
    final s = raw?.toString() ?? '';
    final clean = s.contains('T') ? s.split('T')[0] : s;
    if (clean.isEmpty || clean == 'null') return '-';
    try {
      final d = DateTime.parse(clean);
      return DateFormat('dd MMM yyyy').format(d);
    } catch (_) {
      return clean;
    }
  }

  static String _parseMode(String? remarks) {
    if (remarks == null || remarks.isEmpty) return '-';
    final m = RegExp(r'Mode:\s*([a-zA-Z_ ]+)').firstMatch(remarks);
    if (m == null) return '-';
    switch (m.group(1)!.trim().toLowerCase()) {
      case 'cash':          return 'Cash';
      case 'upi':           return 'UPI';
      case 'bank_transfer': return 'Bank Transfer';
      case 'cheque':        return 'Cheque';
      default:              return m.group(1)!.trim();
    }
  }

  static String _statusLabel(String s) {
    switch (s.toLowerCase()) {
      case 'paid':    return 'Paid';
      case 'partial': return 'Partial';
      case 'overdue': return 'Overdue';
      default:        return 'Pending';
    }
  }

  static PdfColor _statusColor(String s) {
    switch (s.toLowerCase()) {
      case 'paid':    return PdfColors.green700;
      case 'overdue': return PdfColors.red700;
      case 'partial': return PdfColors.blue700;
      default:        return PdfColors.orange700;
    }
  }

  /// Generate and open the fee statement PDF.
  ///
  /// [studentName], [studentId], [mobile], [courseName] — student info.
  /// [academyName] — header branding.
  /// [records] — sorted list of fee_records from getStudentFees API.
  static Future<void> generate({
    required BuildContext context,
    required String academyName,
    required String studentName,
    required String studentId,
    required String mobile,
    required String courseName,
    required List<Map<String, dynamic>> records,
  }) async {
    // Derive summary totals
    double totalDue  = 0, totalPaid = 0;
    for (final r in records) {
      totalDue  += double.tryParse(r['amount_due']?.toString()  ?? '') ?? 0;
      totalPaid += double.tryParse(r['amount_paid']?.toString() ?? '') ?? 0;
    }
    final pending = (totalDue - totalPaid).clamp(0.0, double.infinity);
    final progress = totalDue > 0 ? (totalPaid / totalDue).clamp(0.0, 1.0) : 0.0;

    String overallStatus = 'Pending';
    if (pending <= 0)                        overallStatus = 'Paid';
    else if (records.any((r) => r['status'] == 'overdue')) overallStatus = 'Overdue';
    else if (totalPaid > 0)                  overallStatus = 'Partial';

    final nextDue = records.firstWhere(
      (r) => r['status'] != 'paid',
      orElse: () => const {},
    );

    final pdf = pw.Document();
    final primary = PdfColor.fromHex('#1A56DB');
    final lightBg = PdfColor.fromHex('#F1F5F9');
    final divider = PdfColor.fromHex('#CBD5E1');
    final grey    = PdfColor.fromHex('#64748B');
    final dark    = PdfColor.fromHex('#1E293B');

    final headerStyle    = pw.TextStyle(fontSize: 9,  color: grey);
    final valueStyle     = pw.TextStyle(fontSize: 9,  color: dark, fontWeight: pw.FontWeight.bold);
    final tableHeader    = pw.TextStyle(fontSize: 8,  color: PdfColors.white, fontWeight: pw.FontWeight.bold);
    final tableCell      = pw.TextStyle(fontSize: 8,  color: dark);
    final tableCellBold  = pw.TextStyle(fontSize: 8,  color: dark, fontWeight: pw.FontWeight.bold);

    // ── Column widths for installment table ──────────────────────────────────
    const colWidths = [
      0.05, // #
      0.10, // Due Date
      0.10, // Amount Due
      0.10, // Amount Paid
      0.10, // Payment Date
      0.10, // Mode
      0.10, // Balance
      0.12, // Outstanding
      0.08, // Status
    ];

    pw.Widget tableHeaderRow() => pw.Container(
          color: primary,
          child: pw.Row(
            children: [
              ...[
                '#', 'Due Date', 'Amt Due', 'Amt Paid', 'Paid On', 'Mode', 'Balance', 'Outstanding', 'Status'
              ].asMap().entries.map((e) => pw.Expanded(
                    flex: (colWidths[e.key] * 100).round(),
                    child: pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                      child: pw.Text(e.value, style: tableHeader),
                    ),
                  )).toList(),
            ],
          ),
        );

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            // ── Branded header ───────────────────────────────────────────────
            pw.Container(
              padding: const pw.EdgeInsets.all(14),
              decoration: pw.BoxDecoration(
                color: primary,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(academyName,
                          style: pw.TextStyle(
                              fontSize: 14,
                              color: PdfColors.white,
                              fontWeight: pw.FontWeight.bold)),
                      pw.SizedBox(height: 2),
                      pw.Text('Fee Statement',
                          style: pw.TextStyle(fontSize: 10, color: PdfColors.white)),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text(
                        'Generated: ${DateFormat('dd MMM yyyy').format(DateTime.now())}',
                        style: pw.TextStyle(fontSize: 8, color: PdfColors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 12),
          ],
        ),
        build: (context) => [
          // ── Student info box ─────────────────────────────────────────────
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              color: lightBg,
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
              border: pw.Border.all(color: divider),
            ),
            child: pw.Row(
              children: [
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('Student Name',  style: headerStyle),
                      pw.Text(studentName.isNotEmpty ? studentName : '-', style: valueStyle),
                      pw.SizedBox(height: 6),
                      pw.Text('Registration No.', style: headerStyle),
                      pw.Text(studentId.isNotEmpty ? studentId : '-', style: valueStyle),
                    ],
                  ),
                ),
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('Course / Batch', style: headerStyle),
                      pw.Text(courseName.isNotEmpty ? courseName : '-', style: valueStyle),
                      pw.SizedBox(height: 6),
                      pw.Text('Mobile', style: headerStyle),
                      pw.Text(mobile.isNotEmpty ? mobile : '-', style: valueStyle),
                    ],
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),

          // ── Fee summary ──────────────────────────────────────────────────
          pw.Text('Fee Summary',
              style: pw.TextStyle(
                  fontSize: 11, fontWeight: pw.FontWeight.bold, color: dark)),
          pw.SizedBox(height: 6),
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: divider),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
            ),
            child: pw.Column(
              children: [
                pw.Row(
                  children: [
                    _summaryCell('Total Course Fee', '${_fmt(totalDue)}', dark),
                    _summaryCell('Total Paid', '${_fmt(totalPaid)}', PdfColors.green700),
                    _summaryCell('Pending', '${_fmt(pending)}',
                        pending > 0 ? PdfColors.orange700 : PdfColors.green700),
                    _summaryCell('Status', overallStatus, _statusColor(overallStatus)),
                  ],
                ),
                pw.SizedBox(height: 10),
                // Progress bar (FractionallySizedBox not in pdf package; use Row flex instead)
                pw.Row(
                  children: [
                    pw.Expanded(
                      flex: (progress * 100).round().clamp(1, 100),
                      child: pw.Container(
                        height: 7,
                        decoration: pw.BoxDecoration(
                          color: pending <= 0 ? PdfColors.green700 : primary,
                          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                        ),
                      ),
                    ),
                    if (progress < 0.99)
                      pw.Expanded(
                        flex: ((1 - progress) * 100).round().clamp(1, 100),
                        child: pw.Container(
                          height: 7,
                          decoration: const pw.BoxDecoration(
                            color: PdfColors.grey300,
                            borderRadius: pw.BorderRadius.all(pw.Radius.circular(4)),
                          ),
                        ),
                      ),
                  ],
                ),
                pw.SizedBox(height: 6),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Payment Progress: ${(progress * 100).toStringAsFixed(0)}%',
                      style: pw.TextStyle(fontSize: 8, color: grey),
                    ),
                    if (nextDue.isNotEmpty)
                      pw.Text(
                        'Next Due: ${_fmtDate(nextDue['due_date'])}',
                        style: pw.TextStyle(fontSize: 8, color: PdfColors.orange700),
                      ),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 16),

          // ── Installment history ──────────────────────────────────────────
          pw.Text('Installment History',
              style: pw.TextStyle(
                  fontSize: 11, fontWeight: pw.FontWeight.bold, color: dark)),
          pw.SizedBox(height: 6),
          tableHeaderRow(),

          // Data rows
          ...records.asMap().entries.map((entry) {
            final i = entry.key;
            final r = entry.value;
            final due     = double.tryParse(r['amount_due']?.toString()  ?? '') ?? 0;
            final paid    = double.tryParse(r['amount_paid']?.toString() ?? '') ?? 0;
            final bal     = (due - paid).clamp(0.0, double.infinity);
            // Running outstanding = sum of balances from this record onwards
            double outstanding = 0;
            for (var j = i; j < records.length; j++) {
              final rd = double.tryParse(records[j]['amount_due']?.toString()  ?? '') ?? 0;
              final rp = double.tryParse(records[j]['amount_paid']?.toString() ?? '') ?? 0;
              outstanding += (rd - rp).clamp(0.0, double.infinity);
            }
            final status    = r['status'] as String? ?? 'pending';
            final rowBg     = i.isEven ? PdfColors.white : lightBg;
            final cells = [
              '${i + 1}',
              _fmtDate(r['due_date']),
              _money2(r['amount_due']),
              paid > 0 ? _money2(r['amount_paid']) : '-',
              _fmtDate(r['paid_date']),
              _parseMode(r['remarks'] as String?),
              _fmt(bal),
              _fmt(outstanding),
              _statusLabel(status),
            ];
            return pw.Container(
              color: rowBg,
              child: pw.Row(
                children: cells.asMap().entries.map((e) {
                  final isStatus = e.key == 8;
                  return pw.Expanded(
                    flex: (colWidths[e.key] * 100).round(),
                    child: pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(
                          horizontal: 4, vertical: 5),
                      child: isStatus
                          ? pw.Text(e.value,
                              style: pw.TextStyle(
                                  fontSize: 8,
                                  color: _statusColor(status),
                                  fontWeight: pw.FontWeight.bold))
                          : pw.Text(e.value,
                              style: e.key == 0 ? tableCellBold : tableCell),
                    ),
                  );
                }).toList(),
              ),
            );
          }),
          pw.Container(height: 1, color: divider),
          pw.SizedBox(height: 16),

          // ── Footer note ──────────────────────────────────────────────────
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: lightBg,
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
            ),
            child: pw.Text(
              'This is a system-generated document from $academyName. '
              'For queries, contact the academy office.',
              style: pw.TextStyle(fontSize: 7, color: grey),
            ),
          ),
        ],
      ),
    );

    // Save and open
    final dir  = await getApplicationDocumentsDirectory();
    final safe = studentName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final date = DateFormat('yyyyMMdd').format(DateTime.now());
    final file = File('${dir.path}/${safe}_Fees_Receipt_$date.pdf');
    await file.writeAsBytes(await pdf.save());

    if (context.mounted) {
      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('PDF saved to ${file.path}'),
            action: SnackBarAction(label: 'OK', onPressed: () {}),
          ),
        );
      }
    }
  }

  static pw.Expanded _summaryCell(String label, String value, PdfColor valueColor) =>
      pw.Expanded(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(label,
                style: pw.TextStyle(fontSize: 7.5, color: PdfColor.fromHex('#64748B'))),
            pw.SizedBox(height: 2),
            pw.Text(value,
                style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    color: valueColor)),
          ],
        ),
      );
}
