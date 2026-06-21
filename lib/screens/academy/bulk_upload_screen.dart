import 'dart:io';
import 'dart:typed_data';
import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../utils/file_opener.dart';
import '../../providers/academic_year_provider.dart';
import '../../services/academy_api_service.dart';

enum _Step { initial, parsing, preview, uploading, done }

class BulkUploadScreen extends StatefulWidget {
  const BulkUploadScreen({super.key});

  @override
  State<BulkUploadScreen> createState() => _BulkUploadScreenState();
}

class _BulkUploadScreenState extends State<BulkUploadScreen> {
  _Step _step = _Step.initial;
  String? _fileName;

  // Parsed rows from the file (all rows, including invalid)
  List<Map<String, String>> _parsedRows = [];

  // Client-side validation results
  List<_RowError> _clientErrors = [];
  int _validCount      = 0;
  int _intraFileCount  = 0; // duplicates within the file itself

  // Server results
  Map<String, dynamic>? _serverResult;
  String? _parseError;

  static const _columns = [
    'first_name', 'last_name', 'gender', 'dob',
    'mobile', 'email', 'parent_name', 'parent_mobile', 'address', 'courses',
  ];

  // ── Template ──────────────────────────────────────────────────────────────

  // CSV is used for the template: it is 100% reliable (no xlsx package
  // quirks), opens in Excel / Google Sheets / Numbers, and the admin can
  // save it back as .xlsx or keep it as .csv for upload.
  // Courses column is populated with actual course names from the selected
  // academic year so admins see real values rather than generic placeholders.
  Future<void> _downloadTemplate() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
        const SnackBar(content: Text('Preparing template…')));
    try {
      // Fetch up to 5 active courses for the selected academic year.
      final yearId = context.read<AcademicYearProvider>().selectedId;
      List<String> names = [];
      try {
        final courses =
            await AcademyApiService.getCourses(academicYearId: yearId);
        names = courses
            .take(5)
            .map((c) => (c['name'] as String? ?? '').trim())
            .where((n) => n.isNotEmpty)
            .toList();
      } catch (_) {
        // Non-fatal: proceed with empty courses column if API fails.
      }

      if (!mounted) return;

      // First course name for the single sample row (empty if none).
      final firstCourse = names.isNotEmpty ? names.first : '';

      final lines = [
        // Header — column order must match _columns list.
        // The 7th column (key parent_name) is surfaced to admins as "Middle
        // Name"; the backend storage key stays parent_name for compatibility.
        'First Name*,Last Name*,Gender (Male/Female/Other),'
            'Date Of Birth* (DD/MM/YYYY),Mobile* (10 digits),'
            'Email,Middle Name*,Parent Mobile* (10 digits),Address,'
            'Courses (comma-separated)',
        // Single sample row.
        'Rahul,Sharma,Male,15/05/2010,9876543210,'
            'rahul@example.com,Ramesh,9876543211,Pune,$firstCourse',
      ];

      final content = lines.join('\n');
      final dir  = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/EduScan_Student_Template.csv');
      await file.writeAsString(content);

      messenger.hideCurrentSnackBar();
      await FileOpener.open(file.path);
    } catch (e) {
      if (mounted) {
        messenger.hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Template download error: $e'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  // ── File picking & parsing ────────────────────────────────────────────────

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls', 'csv'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (!mounted) return;

    setState(() { _step = _Step.parsing; _parseError = null; _fileName = file.name; });

    try {
      List<Map<String, String>> rows;
      if (file.name.toLowerCase().endsWith('.csv')) {
        final content = String.fromCharCodes(file.bytes!);
        rows = _parseCsv(content);
      } else {
        rows = _parseExcel(file.bytes!);
      }

      if (rows.isEmpty) {
        setState(() {
          _parseError = 'No data rows found. Make sure the file has a header row and at least one data row.';
          _step = _Step.initial;
        });
        return;
      }

      final errors     = _validate(rows);
      final intraCount = _countIntraFileDups(rows);
      final validRows  = rows.where((r) => !errors.any((e) => e.index == rows.indexOf(r))).toList();

      setState(() {
        _parsedRows      = rows;
        _clientErrors    = errors;
        _validCount      = validRows.length - intraCount;
        _intraFileCount  = intraCount;
        _step = _Step.preview;
      });
    } catch (e) {
      setState(() {
        _parseError = 'Could not read file: $e';
        _step = _Step.initial;
      });
    }
  }

  // Extracts a plain string from any Excel CellValue type.
  // Calling .toString() on the CellValue object returns the class name
  // ("TextCellValue(Priya)") not the inner value — so we branch explicitly.
  // Phone numbers entered as numbers in Excel come back as DoubleCellValue;
  // we strip the decimal so "9876543210.0" becomes "9876543210".
  String _cellStr(Data? cell) {
    if (cell == null || cell.value == null) return '';
    final v = cell.value!;
    // In excel 4.x, TextCellValue.value is the package's own TextSpan class
    // (not Flutter's). It has String? text + List<TextSpan>? children.
    // Its toString() recursively concatenates text + all children — that is
    // exactly the plain-text content of the cell, even for rich-text cells.
    if (v is TextCellValue) return v.value.toString().trim();
    if (v is IntCellValue)  return v.value.toString();
    if (v is DoubleCellValue) {
      final d = v.value;
      if (!d.isNaN && !d.isInfinite && d == d.truncateToDouble()) {
        return d.toInt().toString(); // 9876543210.0 → "9876543210"
      }
      return d.toString();
    }
    if (v is DateCellValue) {
      // Convert Excel date cell to DD/MM/YYYY (our accepted DOB format)
      return '${v.day.toString().padLeft(2, '0')}/'
             '${v.month.toString().padLeft(2, '0')}/${v.year}';
    }
    if (v is DateTimeCellValue) {
      return '${v.day.toString().padLeft(2, '0')}/'
             '${v.month.toString().padLeft(2, '0')}/${v.year}';
    }
    if (v is BoolCellValue) return v.value.toString();
    return v.toString().trim();
  }

  List<Map<String, String>> _parseExcel(Uint8List bytes) {
    final excel = Excel.decodeBytes(bytes);
    final sheet = excel.tables.values.first;
    final rows  = <Map<String, String>>[];

    for (var i = 1; i < sheet.rows.length; i++) {
      final row = sheet.rows[i];
      // Skip completely empty rows
      if (row.every((c) => _cellStr(c).isEmpty)) continue;
      final record = <String, String>{};
      for (var j = 0; j < _columns.length && j < row.length; j++) {
        record[_columns[j]] = _cellStr(row[j]);
      }
      rows.add(record);
    }
    return rows;
  }

  List<Map<String, String>> _parseCsv(String content) {
    final lines = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) return [];

    final rows = <Map<String, String>>[];
    for (final line in lines.skip(1)) {
      final cols   = _splitCsvLine(line);
      final record = <String, String>{};
      for (var j = 0; j < _columns.length && j < cols.length; j++) {
        record[_columns[j]] = cols[j].trim();
      }
      rows.add(record);
    }
    return rows;
  }

  List<String> _splitCsvLine(String line) {
    final fields  = <String>[];
    final field   = StringBuffer();
    var inQuotes  = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          field.write('"'); i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (c == ',' && !inQuotes) {
        fields.add(field.toString().trim());
        field.clear();
      } else {
        field.write(c);
      }
    }
    fields.add(field.toString().trim());
    return fields;
  }

  // ── Client-side validation ───────────────────────────────────────────────

  List<_RowError> _validate(List<Map<String, String>> rows) {
    final errors = <_RowError>[];
    for (var i = 0; i < rows.length; i++) {
      final r    = rows[i];
      final errs = <String>[];
      final fn   = r['first_name'] ?? '';
      final ln   = r['last_name']  ?? '';

      if (fn.isEmpty)        errs.add('First Name required');
      else if (fn.length > 50) errs.add('First Name > 50 chars');
      if (ln.isEmpty)        errs.add('Last Name required');
      else if (ln.length > 50) errs.add('Last Name > 50 chars');

      final mob = r['mobile'] ?? '';
      if (mob.isEmpty || !RegExp(r'^\d{10}$').hasMatch(mob)) {
        errs.add('Mobile: 10 digits');
      }

      final dob = r['dob'] ?? '';
      if (dob.isEmpty) {
        errs.add('DOB required');
      } else if (!RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(dob) &&
                 !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dob)) {
        errs.add('DOB: DD/MM/YYYY');
      }

      final email = r['email'] ?? '';
      if (email.isNotEmpty && !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
        errs.add('Invalid email');
      }

      if ((r['parent_name'] ?? '').isEmpty) errs.add('Middle Name required');

      final pMob = r['parent_mobile'] ?? '';
      if (pMob.isEmpty || !RegExp(r'^\d{10}$').hasMatch(pMob)) {
        errs.add('Parent Mobile: 10 digits');
      }

      if (errs.isNotEmpty) {
        errors.add(_RowError(
          index: i,
          rowNum: i + 2,
          name: '$fn $ln'.trim(),
          reason: errs.join('; '),
        ));
      }
    }
    return errors;
  }

  int _countIntraFileDups(List<Map<String, String>> rows) {
    final seen = <String>{};
    var count  = 0;
    for (final r in rows) {
      final fn  = (r['first_name'] ?? '').toLowerCase().trim();
      final ln  = (r['last_name']  ?? '').toLowerCase().trim();
      final dob = (r['dob'] ?? '').trim();
      if (fn.isEmpty || ln.isEmpty || dob.isEmpty) continue;
      final key = '$fn|$ln|$dob';
      if (!seen.add(key)) count++;
    }
    return count;
  }

  // ── Upload ───────────────────────────────────────────────────────────────

  Future<void> _import() async {
    final invalidIndices = _clientErrors.map((e) => e.index).toSet();
    final validRows = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (var i = 0; i < _parsedRows.length; i++) {
      if (invalidIndices.contains(i)) continue;
      final r  = _parsedRows[i];
      final fn = (r['first_name'] ?? '').toLowerCase().trim();
      final ln = (r['last_name']  ?? '').toLowerCase().trim();
      final dob = (r['dob'] ?? '').trim();
      if (!seen.add('$fn|$ln|$dob')) continue; // skip intra-file dups
      validRows.add(Map<String, dynamic>.from(r));
    }

    if (validRows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No valid records to import.'),
      ));
      return;
    }

    setState(() => _step = _Step.uploading);
    try {
      final yearId = context.read<AcademicYearProvider>().selectedId;
      final result = await AcademyApiService.bulkUploadStudents(
          validRows, academicYearId: yearId);
      setState(() { _serverResult = result; _step = _Step.done; });
    } catch (e) {
      if (mounted) {
        setState(() => _step = _Step.preview);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  // ── Error report download ─────────────────────────────────────────────────

  Future<void> _downloadErrorReport() async {
    final result = _serverResult;
    if (result == null) return;

    final errors = (result['errors'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    if (errors.isEmpty) return;

    final buf = StringBuffer('Row,Name,Reason\n');
    for (final e in errors) {
      final row    = e['row']    as int?    ?? 0;
      final name   = e['name']   as String? ?? '';
      final reason = e['reason'] as String? ?? '';
      buf.writeln('$row,"$name","$reason"');
    }

    final dir  = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/EduScan_Import_Errors.csv');
    await file.writeAsString(buf.toString());
    await FileOpener.open(file.path);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bulk Student Upload'),
        bottom: _step == _Step.uploading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(3),
                child: LinearProgressIndicator())
            : null,
      ),
      body: switch (_step) {
        _Step.initial   => _buildInitial(),
        _Step.parsing   => _buildLoading('Reading file...'),
        _Step.preview   => _buildPreview(),
        _Step.uploading => _buildLoading('Importing students...'),
        _Step.done      => _buildDone(),
      },
    );
  }

  Widget _buildInitial() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Step 1
        _SectionHeader(number: '1', title: 'Download Sample Template'),
        const SizedBox(height: 10),
        Text(
          'Download the template, fill in student details, and save as .xlsx or .csv.',
          style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _downloadTemplate,
          icon: const Icon(Icons.download_outlined),
          label: const Text('Download Sample Template (.csv)'),
          style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48)),
        ),

        const SizedBox(height: 28),

        // Step 2
        _SectionHeader(number: '2', title: 'Upload Filled File'),
        const SizedBox(height: 10),
        Text(
          'Supported formats: .xlsx  ·  .csv\n'
          'Required: First Name, Last Name, DOB, Mobile, Middle Name, Parent Mobile\n'
          'Optional: Courses (comma-separated names, e.g. "NEET,JEE")\n'
          'Maximum: 1,000 students per upload.',
          style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
        ),
        const SizedBox(height: 14),
        if (_parseError != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(children: [
              Icon(Icons.error_outline, color: Colors.red.shade700, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_parseError!,
                    style: TextStyle(fontSize: 12, color: Colors.red.shade800)),
              ),
            ]),
          ),
        InkWell(
          onTap: _pickFile,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: 140,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.4),
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignCenter),
              color: theme.colorScheme.primary.withValues(alpha: 0.04),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.upload_file_outlined,
                    size: 40,
                    color: theme.colorScheme.primary.withValues(alpha: 0.7)),
                const SizedBox(height: 10),
                Text('Tap to select Excel or CSV file',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary)),
                const SizedBox(height: 4),
                Text('.xlsx  ·  .csv',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoading(String message) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(message,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ],
        ),
      );

  Widget _buildPreview() {
    final theme     = Theme.of(context);
    final totalRows = _parsedRows.length;
    final invalid   = _clientErrors.length;
    final valid     = _validCount;
    final intra     = _intraFileCount;
    final canImport = valid > 0;

    return Column(
      children: [
        // Summary card
        Padding(
          padding: const EdgeInsets.all(16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.insert_drive_file_outlined,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_fileName ?? 'Uploaded file',
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 13),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  Row(
                    children: [
                      _StatChip('Total', '$totalRows', Colors.blue),
                      const SizedBox(width: 8),
                      _StatChip('Valid', '$valid', Colors.green),
                      const SizedBox(width: 8),
                      _StatChip('Dupl.', '$intra', Colors.orange),
                      const SizedBox(width: 8),
                      _StatChip('Invalid', '$invalid', Colors.red),
                    ],
                  ),
                  if (!canImport) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(children: [
                        Icon(Icons.warning_amber_rounded,
                            color: Colors.orange, size: 16),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'No valid records to import. Fix the errors and re-upload.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ]),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),

        // Error list
        if (_clientErrors.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Icon(Icons.error_outline, size: 16, color: Colors.red),
              const SizedBox(width: 6),
              Text('${_clientErrors.length} invalid row(s)',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, color: Colors.red,
                      fontSize: 13)),
            ]),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _clientErrors.length,
              itemBuilder: (_, i) {
                final e = _clientErrors[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('Row ${e.rowNum}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.red.shade700,
                                  fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (e.name.isNotEmpty)
                                Text(e.name,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                              Text(e.reason,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.65))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ] else
          const Expanded(
            child: Center(
              child: Text('All rows passed validation.',
                  style: TextStyle(color: Colors.green,
                      fontWeight: FontWeight.w600)),
            ),
          ),

        // Action buttons
        Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16,
              MediaQuery.of(context).padding.bottom + 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    _step = _Step.initial;
                    _parsedRows.clear();
                    _clientErrors.clear();
                  }),
                  child: const Text('Choose Different File'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: canImport ? _import : null,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: Text('Import $valid Student${valid == 1 ? '' : 's'}'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDone() {
    final r                = _serverResult!;
    final imported         = r['imported']           as int? ?? 0;
    final dups             = r['duplicates']         as int? ?? 0;
    final failed           = r['failed']             as int? ?? 0;
    final total            = r['total']              as int? ?? 0;
    final courseAssignments = r['course_assignments'] as int? ?? 0;
    final ignoredCourses   = (r['ignored_courses']   as List? ?? [])
        .cast<String>();
    final errors     = (r['errors']           as List? ?? []).cast<Map<String, dynamic>>();
    final dupDetails = (r['duplicate_details'] as List? ?? []).cast<Map<String, dynamic>>();

    return ListView(
      padding: EdgeInsets.fromLTRB(20, 20, 20,
          MediaQuery.of(context).padding.bottom + 20),
      children: [
        // Success header
        Center(
          child: Column(
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: imported > 0
                    ? Colors.green.shade100
                    : Colors.orange.shade100,
                child: Icon(
                  imported > 0 ? Icons.check_circle : Icons.warning_amber_rounded,
                  size: 36,
                  color: imported > 0 ? Colors.green.shade700 : Colors.orange.shade700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                imported > 0 ? 'Import Completed' : 'Import Finished',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Total records processed: $total',
                style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // Student import stat cards
        Row(children: [
          Expanded(child: _ResultCard(
            icon: Icons.check_circle_outline,
            label: 'Imported',
            value: '$imported',
            color: Colors.green,
          )),
          const SizedBox(width: 12),
          Expanded(child: _ResultCard(
            icon: Icons.skip_next_outlined,
            label: 'Skipped',
            value: '$dups',
            color: Colors.orange,
          )),
          const SizedBox(width: 12),
          Expanded(child: _ResultCard(
            icon: Icons.cancel_outlined,
            label: 'Failed',
            value: '$failed',
            color: Colors.red,
          )),
        ]),
        const SizedBox(height: 12),

        // Course assignment stat cards
        Row(children: [
          Expanded(child: _ResultCard(
            icon: Icons.menu_book_outlined,
            label: 'Enrollments',
            value: '$courseAssignments',
            color: Colors.blue,
          )),
          const SizedBox(width: 12),
          Expanded(child: _ResultCard(
            icon: Icons.block_outlined,
            label: 'Ignored Courses',
            value: '${ignoredCourses.length}',
            color: Colors.grey,
          )),
          const SizedBox(width: 12),
          const Expanded(child: SizedBox()), // spacer to keep alignment
        ]),
        const SizedBox(height: 12),

        // Ignored course names (if any)
        if (ignoredCourses.isNotEmpty) ...[
          const Text('Ignored Course Names',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14,
                  color: Colors.grey)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6, runSpacing: 4,
            children: ignoredCourses
                .map((c) => Chip(
                      label: Text(c, style: const TextStyle(fontSize: 11)),
                      backgroundColor: Colors.grey.shade100,
                      padding: EdgeInsets.zero,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ))
                .toList(),
          ),
          const SizedBox(height: 16),
        ],

        const SizedBox(height: 8),

        // Duplicate details
        if (dupDetails.isNotEmpty) ...[
          const Text('Skipped Duplicates',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          ...dupDetails.take(10).map((d) => Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.person_outline, size: 20),
                  title: Text(d['name'] as String? ?? '',
                      style: const TextStyle(fontSize: 13)),
                  subtitle: Text(
                    d['existing_id'] == '(same file)'
                        ? 'Duplicate within uploaded file'
                        : 'Already in DB — ID: ${d['existing_id']}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              )),
          if (dupDetails.length > 10)
            Text('  ... and ${dupDetails.length - 10} more',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.5))),
          const SizedBox(height: 16),
        ],

        // Error details
        if (errors.isNotEmpty) ...[
          const Text('Failed Records',
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 14, color: Colors.red)),
          const SizedBox(height: 8),
          ...errors.take(10).map((e) => Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.error_outline,
                      color: Colors.red, size: 20),
                  title: Text(
                    e['row'] != null && (e['row'] as int) > 0
                        ? 'Row ${e['row']} — ${e['name'] ?? ''}'
                        : (e['name'] as String? ?? ''),
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(e['reason'] as String? ?? '',
                      style: const TextStyle(fontSize: 11)),
                ),
              )),
          const SizedBox(height: 8),
          if (errors.isNotEmpty)
            OutlinedButton.icon(
              onPressed: _downloadErrorReport,
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Download Error Report (.csv)'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44)),
            ),
          const SizedBox(height: 16),
        ],

        FilledButton(
          onPressed: () => Navigator.pop(context, imported > 0),
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48)),
          child: const Text('Done'),
        ),
        if (imported == 0) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() {
              _step = _Step.initial;
              _serverResult = null;
              _parsedRows.clear();
              _clientErrors.clear();
            }),
            child: const Text('Upload Another File'),
          ),
        ],
      ],
    );
  }
}

// ── Small helpers ──────────────────────────────────────────────────────────────

class _RowError {
  final int index;
  final int rowNum;
  final String name;
  final String reason;
  const _RowError({
    required this.index, required this.rowNum,
    required this.name,  required this.reason,
  });
}

class _SectionHeader extends StatelessWidget {
  final String number;
  final String title;
  const _SectionHeader({required this.number, required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        CircleAvatar(
          radius: 12,
          backgroundColor: theme.colorScheme.primary,
          child: Text(number,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 10),
        Text(title,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatChip(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: color)),
              Text(label,
                  style: TextStyle(
                      fontSize: 10,
                      color: color.withValues(alpha: 0.8))),
            ],
          ),
        ),
      );
}

class _ResultCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _ResultCard({
    required this.icon, required this.label,
    required this.value, required this.color,
  });

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 6),
              Text(value,
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: color)),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6))),
            ],
          ),
        ),
      );
}
