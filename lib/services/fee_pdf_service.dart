import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Generates professional fee PDF documents and opens them.
///
/// Font strategy: Noto Sans (via PdfGoogleFonts) is loaded async before each
/// PDF build. It supports the ₹ glyph (U+20B9). If the download fails (offline
/// first run), we fall back to the built-in PDF Helvetica font — ₹ will render
/// as a box in that case but the PDF is still usable.
class FeePdfService {
  // ── Formatters ──────────────────────────────────────────────────────────────

  // Indian locale, 2 decimal places: 10000 → "10,000.00"
  static final _money = NumberFormat('#,##,##0.00', 'en_IN');

  /// Formats a double as ₹ + Indian-comma amount with 2 decimals.
  static String _fmt(double v) => '₹${_money.format(v)}';

  /// Same as [_fmt] but accepts any dynamic value (parses to double first).
  static String _m(dynamic v) =>
      _fmt(double.tryParse(v?.toString() ?? '') ?? 0);

  static String _fmtDate(dynamic raw) {
    final s     = raw?.toString() ?? '';
    final clean = s.contains('T') ? s.split('T')[0] : s;
    if (clean.isEmpty || clean == 'null') return '-';
    try {
      return DateFormat('dd MMM yyyy').format(DateTime.parse(clean));
    } catch (_) {
      return clean;
    }
  }

  /// Accepts either a raw mode string ("cash", "upi") or the old embedded
  /// remarks format ("Mode: cash") used by the legacy fee_records controller.
  static String _parseMode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '-';
    final embedded = RegExp(r'Mode:\s*([a-zA-Z_ ]+)').firstMatch(raw);
    final mode     = embedded != null ? (embedded.group(1) ?? raw.trim()).trim() : raw.trim();
    switch (mode.toLowerCase()) {
      case 'cash':          return 'Cash';
      case 'upi':           return 'UPI';
      case 'bank_transfer': return 'Bank Transfer';
      case 'cheque':        return 'Cheque';
      default:              return mode;
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

  // ── Font loading ─────────────────────────────────────────────────────────────

  /// Returns a [pw.ThemeData] using bundled Noto Sans fonts.
  /// Noto Sans covers U+20B9 (₹) and virtually all Unicode scripts.
  /// Falls back to built-in Helvetica only if the asset load fails.
  static Future<pw.ThemeData> _theme() async {
    try {
      final regularData = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
      final boldData    = await rootBundle.load('assets/fonts/NotoSans-Bold.ttf');
      final base = pw.Font.ttf(regularData);
      final bold = pw.Font.ttf(boldData);
      debugPrint('[PDF] fonts loaded: regular=${regularData.lengthInBytes}b bold=${boldData.lengthInBytes}b');
      return pw.ThemeData.withFont(base: base, bold: bold);
    } catch (e) {
      debugPrint('[PDF] font load failed, falling back to Helvetica: $e');
      return pw.ThemeData();
    }
  }

  // ── Fee Statement (multi-instalment) ─────────────────────────────────────────

  /// Generates a full fee statement PDF with instalment history and opens it.
  static Future<void> generate({
    required BuildContext context,
    required String academyName,
    required String studentName,
    required String studentId,
    required String mobile,
    required String courseName,
    required List<Map<String, dynamic>> records,
    String? qrImageData,
    String? qrName,
    String? qrDescription,
  }) async {
    double totalDue = 0, totalPaid = 0;
    for (final r in records) {
      totalDue  += double.tryParse(r['amount_due']?.toString()  ?? '') ?? 0;
      totalPaid += double.tryParse(r['amount_paid']?.toString() ?? '') ?? 0;
    }
    final pending  = (totalDue - totalPaid).clamp(0.0, double.infinity);
    final progress = totalDue > 0 ? (totalPaid / totalDue).clamp(0.0, 1.0) : 0.0;

    String overallStatus = 'Pending';
    if (pending <= 0)                                         overallStatus = 'Paid';
    else if (records.any((r) => r['status'] == 'overdue'))   overallStatus = 'Overdue';
    else if (totalPaid > 0)                                  overallStatus = 'Partial';

    final nextDue = records.firstWhere(
      (r) => r['status'] != 'paid',
      orElse: () => const {},
    );

    Uint8List? qrBytes;
    if (qrImageData != null && qrImageData.isNotEmpty) {
      try {
        final b64 = qrImageData.contains(',') ? qrImageData.split(',').last : qrImageData;
        qrBytes = base64Decode(b64);
      } catch (_) {}
    }

    final theme   = await _theme();
    final pdf     = pw.Document();
    final primary = PdfColor.fromHex('#1A56DB');
    final lightBg = PdfColor.fromHex('#F1F5F9');
    final divider = PdfColor.fromHex('#CBD5E1');
    final grey    = PdfColor.fromHex('#64748B');
    final dark    = PdfColor.fromHex('#1E293B');

    final headerStyle   = pw.TextStyle(fontSize: 9,  color: grey);
    final valueStyle    = pw.TextStyle(fontSize: 9,  color: dark, fontWeight: pw.FontWeight.bold);
    final tableHeader   = pw.TextStyle(fontSize: 8,  color: PdfColors.white, fontWeight: pw.FontWeight.bold);
    final tableCell     = pw.TextStyle(fontSize: 8,  color: dark);
    final tableCellBold = pw.TextStyle(fontSize: 8,  color: dark, fontWeight: pw.FontWeight.bold);

    const colWidths = [0.05, 0.10, 0.10, 0.10, 0.10, 0.10, 0.10, 0.12, 0.08];

    pw.Widget tableHeaderRow() => pw.Container(
      color: primary,
      child: pw.Row(
        children: [
          ...['#', 'Due Date', 'Amt Due', 'Amt Paid', 'Paid On', 'Mode', 'Balance', 'Outstanding', 'Status']
              .asMap()
              .entries
              .map((e) => pw.Expanded(
                    flex: (colWidths[e.key] * 100).round(),
                    child: pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                      child: pw.Text(e.value, style: tableHeader),
                    ),
                  )),
        ],
      ),
    );

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin:     const pw.EdgeInsets.all(28),
        theme:      theme,
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Container(
              padding: const pw.EdgeInsets.all(14),
              decoration: pw.BoxDecoration(
                color:        primary,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(academyName,
                          style: pw.TextStyle(fontSize: 14, color: PdfColors.white, fontWeight: pw.FontWeight.bold)),
                      pw.SizedBox(height: 2),
                      pw.Text('Fee Statement',
                          style: pw.TextStyle(fontSize: 10, color: PdfColors.white)),
                    ],
                  ),
                  pw.Text(
                    'Generated: ${DateFormat('dd MMM yyyy').format(DateTime.now())}',
                    style: pw.TextStyle(fontSize: 8, color: PdfColors.white),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 12),
          ],
        ),
        build: (context) => [
          // ── Student info ─────────────────────────────────────────────────
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              color:        lightBg,
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
              border:       pw.Border.all(color: divider),
            ),
            child: pw.Row(
              children: [
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('Student Name',     style: headerStyle),
                      pw.Text(studentName.isNotEmpty ? studentName : '-', style: valueStyle),
                      pw.SizedBox(height: 6),
                      pw.Text('Registration No.', style: headerStyle),
                      pw.Text(studentId.isNotEmpty ? studentId : '-',     style: valueStyle),
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
                      pw.Text(mobile.isNotEmpty ? mobile : '-',         style: valueStyle),
                    ],
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),

          // ── Fee summary ──────────────────────────────────────────────────
          pw.Text('Fee Summary',
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: dark)),
          pw.SizedBox(height: 6),
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              border:       pw.Border.all(color: divider),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
            ),
            child: pw.Column(
              children: [
                pw.Row(
                  children: [
                    _summaryCell('Total Course Fee', _fmt(totalDue),  dark),
                    _summaryCell('Total Paid',       _fmt(totalPaid), PdfColors.green700),
                    _summaryCell('Pending',          _fmt(pending),
                        pending > 0 ? PdfColors.orange700 : PdfColors.green700),
                    _summaryCell('Status', overallStatus, _statusColor(overallStatus)),
                  ],
                ),
                pw.SizedBox(height: 10),
                pw.Row(
                  children: [
                    pw.Expanded(
                      flex: (progress * 100).round().clamp(1, 100),
                      child: pw.Container(
                        height: 7,
                        decoration: pw.BoxDecoration(
                          color:        pending <= 0 ? PdfColors.green700 : primary,
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
                            color:        PdfColors.grey300,
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

          // ── Instalment history ───────────────────────────────────────────
          pw.Text('Installment History',
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: dark)),
          pw.SizedBox(height: 6),
          tableHeaderRow(),

          ...records.asMap().entries.map((entry) {
            final i   = entry.key;
            final r   = entry.value;
            final due  = double.tryParse(r['amount_due']?.toString()  ?? '') ?? 0;
            final paid = double.tryParse(r['amount_paid']?.toString() ?? '') ?? 0;
            final bal  = (due - paid).clamp(0.0, double.infinity);
            double outstanding = 0;
            for (var j = i; j < records.length; j++) {
              final rd = double.tryParse(records[j]['amount_due']?.toString()  ?? '') ?? 0;
              final rp = double.tryParse(records[j]['amount_paid']?.toString() ?? '') ?? 0;
              outstanding += (rd - rp).clamp(0.0, double.infinity);
            }
            final status = r['status'] as String? ?? 'pending';
            final rowBg  = i.isEven ? PdfColors.white : lightBg;
            final cells  = [
              '${i + 1}',
              _fmtDate(r['due_date']),
              _m(r['amount_due']),
              paid > 0 ? _m(r['amount_paid']) : '-',
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
                      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
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

          // ── QR Code ──────────────────────────────────────────────────────
          if (qrBytes != null) ...[
            pw.Text('Payment QR Code',
                style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: dark)),
            pw.SizedBox(height: 8),
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color:        lightBg,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
                border:       pw.Border.all(color: divider),
              ),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Image(pw.MemoryImage(qrBytes), width: 110, height: 110),
                  pw.SizedBox(width: 16),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('Scan to Pay', style: pw.TextStyle(fontSize: 9, color: grey)),
                        pw.SizedBox(height: 4),
                        pw.Text(qrName ?? 'Academy QR',
                            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: dark)),
                        if (qrDescription != null && qrDescription.isNotEmpty) ...[
                          pw.SizedBox(height: 4),
                          pw.Text(qrDescription, style: pw.TextStyle(fontSize: 8, color: grey)),
                        ],
                        pw.SizedBox(height: 8),
                        pw.Text(
                          'Use any UPI app to scan and pay your fee installment.',
                          style: pw.TextStyle(fontSize: 7.5, color: grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
          ],

          // ── Footer ───────────────────────────────────────────────────────
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color:        lightBg,
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

    final dir  = await getApplicationDocumentsDirectory();
    final safe = studentName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final date = DateFormat('yyyyMMdd').format(DateTime.now());
    final file = File('${dir.path}/${safe}_Fees_Statement_$date.pdf');
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

  // ── Single Receipt PDF ────────────────────────────────────────────────────────

  /// Generates a single-payment receipt PDF and opens it.
  /// File name: Receipt_RCP_2026_000001.pdf
  static Future<void> generateReceiptPdf({
    required BuildContext context,
    required String academyName,
    required Map<String, dynamic> receipt,
  }) async {
    debugPrint('[PDF] generateReceiptPdf start');
    final theme    = await _theme();
    final primary  = PdfColor.fromHex('#1A56DB');
    final lightBg  = PdfColor.fromHex('#F1F5F9');
    final divider  = PdfColor.fromHex('#CBD5E1');
    final grey     = PdfColor.fromHex('#64748B');
    final dark     = PdfColor.fromHex('#1E293B');

    final labelStyle = pw.TextStyle(fontSize: 8,  color: grey);
    final valueStyle = pw.TextStyle(fontSize: 10, color: dark, fontWeight: pw.FontWeight.bold);

    final receiptNumber = receipt['receipt_number'] as String? ?? '—';
    final studentName   = '${receipt['first_name'] ?? ''} ${receipt['last_name'] ?? ''}'.trim();
    final studentId     = receipt['student_id']  as String? ?? '';
    final mobile        = receipt['mobile']      as String? ?? '—';
    final courseName    = receipt['course_name'] as String? ?? '';
    final subjectName   = receipt['subject_name'] as String?;
    final amountPaid    = double.tryParse(receipt['amount_paid']?.toString() ?? '') ?? 0;
    final amountDue     = double.tryParse(receipt['amount_due']?.toString()  ?? '') ?? 0;
    final balance       = double.tryParse(receipt['balance']?.toString() ?? '')
        ?? (amountDue - amountPaid).clamp(0.0, double.infinity);
    final paymentMode = _parseMode(receipt['payment_mode'] as String?);
    final generatedAt = _fmtDate(receipt['generated_at']);

    // Multi-subject items (null means legacy single-record receipt)
    final rawItems = receipt['items'];
    final items = rawItems is List
        ? rawItems.cast<Map<String, dynamic>>()
        : null;

    debugPrint('[PDF] receipt=$receiptNumber student=$studentName '
        'paid=$amountPaid due=$amountDue balance=$balance mode=$paymentMode');
    final dueDate     = _fmtDate(receipt['due_date']);

    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin:     const pw.EdgeInsets.all(40),
        theme:      theme,
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            pw.Container(
              padding: const pw.EdgeInsets.all(16),
              decoration: pw.BoxDecoration(
                color:        primary,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(academyName,
                          style: pw.TextStyle(fontSize: 16, color: PdfColors.white, fontWeight: pw.FontWeight.bold)),
                      pw.SizedBox(height: 3),
                      pw.Text('Fee Receipt',
                          style: pw.TextStyle(fontSize: 10, color: PdfColor(1, 1, 1, 0.7))),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text(receiptNumber,
                          style: pw.TextStyle(fontSize: 13, color: PdfColors.white, fontWeight: pw.FontWeight.bold)),
                      pw.SizedBox(height: 3),
                      pw.Text('Date: $generatedAt',
                          style: pw.TextStyle(fontSize: 8, color: PdfColor(1, 1, 1, 0.7))),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 20),

            // ── Student details ──────────────────────────────────────────────
            pw.Container(
              padding: const pw.EdgeInsets.all(14),
              decoration: pw.BoxDecoration(
                color:        lightBg,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
                border:       pw.Border.all(color: divider),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('Student Details',
                      style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: dark)),
                  pw.SizedBox(height: 10),
                  pw.Row(
                    children: [
                      pw.Expanded(
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text('Student Name', style: labelStyle),
                            pw.Text(studentName.isNotEmpty ? studentName : '—', style: valueStyle),
                            pw.SizedBox(height: 8),
                            pw.Text('Student ID', style: labelStyle),
                            pw.Text(studentId.isNotEmpty ? studentId : '—', style: valueStyle),
                          ],
                        ),
                      ),
                      pw.Expanded(
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text('Mobile', style: labelStyle),
                            pw.Text(mobile, style: valueStyle),
                          ],
                        ),
                      ),
                      if (items == null) // legacy single-subject: show course/subject
                        pw.Expanded(
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text('Course', style: labelStyle),
                              pw.Text(courseName.isNotEmpty ? courseName : '—', style: valueStyle),
                              if (subjectName != null && subjectName.isNotEmpty) ...[
                                pw.SizedBox(height: 8),
                                pw.Text('Subject', style: labelStyle),
                                pw.Text(subjectName, style: valueStyle),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),

            // ── Payment details ──────────────────────────────────────────────
            pw.Text('Payment Details',
                style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: dark)),
            pw.SizedBox(height: 8),

            if (items != null) ...[
              // Multi-subject: subjects breakdown table
              _subjectsTable(items, amountPaid, primary, dark, divider, lightBg,
                  labelStyle, valueStyle),
              pw.SizedBox(height: 12),
              _receiptRow('Payment Mode', paymentMode, dark),
              _receiptRow('Date',         generatedAt, dark),
            ] else ...[
              // Legacy single-subject: existing layout
              pw.Container(
                decoration: pw.BoxDecoration(
                  border:       pw.Border.all(color: divider),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
                ),
                child: pw.Column(
                  children: [
                    _receiptRow('Total Fee',    _fmt(amountDue),  primary,  isHeader: true),
                    _receiptRow('Amount Paid',  _fmt(amountPaid), PdfColors.green700),
                    _receiptRow('Balance Due',  _fmt(balance),
                        balance > 0 ? PdfColors.orange700 : PdfColors.green700),
                    _receiptRow('Payment Mode', paymentMode,      dark),
                    _receiptRow('Due Date',     dueDate,          dark),
                  ],
                ),
              ),
            ],
            pw.SizedBox(height: 20),

            // ── Status banner ────────────────────────────────────────────────
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: pw.BoxDecoration(
                color: PdfColors.green50,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
                border: pw.Border.all(color: PdfColors.green700),
              ),
              child: pw.Center(
                child: pw.Text(
                  items != null
                      ? 'Payment of ${_fmt(amountPaid)} recorded. Thank you!'
                      : (balance <= 0
                          ? 'All fees cleared. Thank you!'
                          : 'Remaining balance: ${_fmt(balance)}'),
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.green800,
                  ),
                ),
              ),
            ),
            pw.SizedBox(height: 20),

            // ── Footer ───────────────────────────────────────────────────────
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color:        lightBg,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
              ),
              child: pw.Column(
                children: [
                  pw.Text(
                    'This is a computer-generated receipt from $academyName.',
                    style:     pw.TextStyle(fontSize: 7, color: grey),
                    textAlign: pw.TextAlign.center,
                  ),
                  pw.SizedBox(height: 3),
                  pw.Text(
                    'Receipt No: $receiptNumber  |  Generated: $generatedAt',
                    style:     pw.TextStyle(fontSize: 7, color: grey),
                    textAlign: pw.TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // File: Receipt_RCP_2026_000001.pdf
    final dir      = await getApplicationDocumentsDirectory();
    final safeRcpt = receiptNumber.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final file     = File('${dir.path}/Receipt_$safeRcpt.pdf');

    debugPrint('[PDF] Saving to ${file.path}');
    late final Uint8List bytes;
    try {
      bytes = await pdf.save();
    } catch (e, st) {
      debugPrint('[PDF] pdf.save() failed: $e\n$st');
      throw Exception('PDF generation failed: $e');
    }
    await file.writeAsBytes(bytes);
    debugPrint('[PDF] Wrote ${bytes.length} bytes');

    if (context.mounted) {
      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF saved to ${file.path}')),
        );
      }
    }
  }

  // ── Shared widgets ────────────────────────────────────────────────────────────

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
                    fontSize: 11, fontWeight: pw.FontWeight.bold, color: valueColor)),
          ],
        ),
      );

  static pw.Widget _subjectsTable(
    List<Map<String, dynamic>> items,
    double totalPaid,
    PdfColor primary,
    PdfColor dark,
    PdfColor divider,
    PdfColor lightBg,
    pw.TextStyle labelStyle,
    pw.TextStyle valueStyle,
  ) {
    // Group items by course
    final coursesMap = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final c = (item['course_name'] as String?) ?? 'Course';
      coursesMap.putIfAbsent(c, () => []).add(item);
    }

    final rows = <pw.Widget>[];
    coursesMap.forEach((courseName, subjects) {
      // Course header row
      rows.add(pw.Container(
        color: PdfColor.fromHex('#EFF6FF'),
        padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: pw.Row(
          children: [
            pw.Expanded(
              child: pw.Text(courseName,
                  style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                      color: primary)),
            ),
          ],
        ),
      ));
      for (final s in subjects) {
        final subjectName = (s['subject_name'] as String?) ?? 'Subject';
        final paid = double.tryParse(s['amount_paid']?.toString() ?? '') ?? 0;
        rows.add(pw.Container(
          color: PdfColors.white,
          padding: const pw.EdgeInsets.symmetric(horizontal: 20, vertical: 7),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(subjectName,
                  style: pw.TextStyle(fontSize: 9, color: dark)),
              pw.Text(_fmt(paid),
                  style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.green700)),
            ],
          ),
        ));
        rows.add(pw.Container(height: 0.5, color: divider));
      }
    });

    // Total row
    rows.add(pw.Container(
      color: lightBg,
      padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('TOTAL RECEIVED',
              style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: dark)),
          pw.Text(_fmt(totalPaid),
              style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.green700)),
        ],
      ),
    ));

    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: divider),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Column(children: rows),
    );
  }

  static pw.Widget _receiptRow(
    String label,
    String value,
    PdfColor valueColor, {
    bool isHeader = false,
  }) {
    final bg = isHeader ? PdfColor.fromHex('#EFF6FF') : PdfColors.white;
    return pw.Container(
      color:   bg,
      padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label,
              style: pw.TextStyle(fontSize: 9, color: PdfColor.fromHex('#64748B'))),
          pw.Text(value,
              style: pw.TextStyle(
                  fontSize:   10,
                  fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal,
                  color:      valueColor)),
        ],
      ),
    );
  }
}
