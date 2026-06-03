import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';

class AcademicYearMasterScreen extends StatefulWidget {
  const AcademicYearMasterScreen({super.key});

  @override
  State<AcademicYearMasterScreen> createState() =>
      _AcademicYearMasterScreenState();
}

class _AcademicYearMasterScreenState extends State<AcademicYearMasterScreen> {
  List<Map<String, dynamic>> _years = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final data = await AcademyApiService.getAcademicYears();
      if (!mounted) return;
      setState(() {
        _years   = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _showForm({Map<String, dynamic>? year}) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _AcademicYearForm(year: year),
    );
    if (result == true) _load();
  }

  Future<void> _delete(Map<String, dynamic> year) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Academic Year'),
        content: Text(
            'Delete "${year['academic_year_name']}"?\n\n'
            'This will mark it inactive. All associated courses and student '
            'records are preserved.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await AcademyApiService.deleteAcademicYear(year['id'] as String);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')),
                backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Academic Year Master'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: () => _showForm()),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _years.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.calendar_today_outlined,
                          size: 64,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.3)),
                      const SizedBox(height: 12),
                      const Text('No academic years yet'),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: () => _showForm(),
                        icon: const Icon(Icons.add),
                        label: const Text('Add Academic Year'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _years.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final y = _years[i];
                      final isCurrent = y['is_current_year'] == true;
                      final isActive  = y['status'] == 'active';
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isCurrent
                                ? theme.colorScheme.primary.withValues(alpha: 0.15)
                                : theme.colorScheme.onSurface.withValues(alpha: 0.07),
                            child: Icon(
                              isCurrent
                                  ? Icons.star_rounded
                                  : Icons.calendar_today_outlined,
                              color: isCurrent
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface
                                      .withValues(alpha: 0.5),
                            ),
                          ),
                          title: Row(
                            children: [
                              Text(y['academic_year_name'] as String,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              if (isCurrent) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text('Current',
                                      style: TextStyle(
                                          color: Colors.white, fontSize: 10,
                                          fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ],
                          ),
                          subtitle: Text(
                            '${_fmtDate(y['start_date'])} – ${_fmtDate(y['end_date'])}'
                            '${isActive ? '' : '  •  Inactive'}',
                            style: TextStyle(
                                fontSize: 12,
                                color: isActive
                                    ? null
                                    : theme.colorScheme.onSurface
                                        .withValues(alpha: 0.45)),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _showForm(year: y)),
                              IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.red),
                                  onPressed: () => _delete(y)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
      floatingActionButton: _years.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () => _showForm(),
              icon: const Icon(Icons.add),
              label: const Text('Add Year'),
            )
          : null,
    );
  }

  String _fmtDate(dynamic raw) {
    if (raw == null) return '';
    final s = raw.toString();
    if (s.length >= 10) {
      final parts = s.substring(0, 10).split('-');
      if (parts.length == 3) return '${parts[2]}/${parts[1]}/${parts[0]}';
    }
    return s;
  }
}

// ── Academic year form (create / edit) ────────────────────────────────────────

class _AcademicYearForm extends StatefulWidget {
  final Map<String, dynamic>? year;
  const _AcademicYearForm({this.year});

  @override
  State<_AcademicYearForm> createState() => _AcademicYearFormState();
}

class _AcademicYearFormState extends State<_AcademicYearForm> {
  final _formKey   = GlobalKey<FormState>();
  final _nameCtrl  = TextEditingController();
  final _startCtrl = TextEditingController();
  final _endCtrl   = TextEditingController();
  bool _isCurrentYear = false;
  String _status      = 'active';
  bool _saving        = false;

  bool get _isEdit => widget.year != null;

  @override
  void initState() {
    super.initState();
    final y = widget.year;
    if (y != null) {
      _nameCtrl.text    = y['academic_year_name'] ?? '';
      _startCtrl.text   = _toDisplay(y['start_date']);
      _endCtrl.text     = _toDisplay(y['end_date']);
      _isCurrentYear    = y['is_current_year'] == true;
      _status           = y['status'] ?? 'active';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _startCtrl.dispose(); _endCtrl.dispose();
    super.dispose();
  }

  // dd/MM/yyyy ← yyyy-MM-dd
  String _toDisplay(dynamic raw) {
    if (raw == null) return '';
    final s = raw.toString();
    if (s.length >= 10) {
      final p = s.substring(0, 10).split('-');
      if (p.length == 3) return '${p[2]}/${p[1]}/${p[0]}';
    }
    return s;
  }

  // yyyy-MM-dd ← dd/MM/yyyy
  String? _toIso(String display) {
    final p = display.trim().split('/');
    if (p.length == 3 && p[0].length == 2 && p[1].length == 2 && p[2].length == 4) {
      return '${p[2]}-${p[1]}-${p[0]}';
    }
    return null;
  }

  Future<void> _pickDate(TextEditingController ctrl) async {
    final initial = _toIso(ctrl.text) != null
        ? DateTime.tryParse(_toIso(ctrl.text)!) ?? DateTime.now()
        : DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      ctrl.text =
          '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final startIso = _toIso(_startCtrl.text);
    final endIso   = _toIso(_endCtrl.text);
    if (startIso == null || endIso == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dates must be in DD/MM/YYYY format')));
      return;
    }

    setState(() => _saving = true);
    try {
      final body = {
        'academic_year_name': _nameCtrl.text.trim(),
        'start_date':         startIso,
        'end_date':           endIso,
        'status':             _status,
        'is_current_year':    _isCurrentYear,
      };
      if (_isEdit) {
        await AcademyApiService.updateAcademicYear(
            widget.year!['id'] as String, body);
      } else {
        await AcademyApiService.createAcademicYear(body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.red));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_isEdit ? 'Edit Academic Year' : 'New Academic Year',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                  labelText: 'Academic Year Name *',
                  hintText: 'e.g. 2025-2026',
                  border: OutlineInputBorder()),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _startCtrl,
                    readOnly: true,
                    decoration: const InputDecoration(
                        labelText: 'Start Date *',
                        hintText: 'DD/MM/YYYY',
                        border: OutlineInputBorder(),
                        suffixIcon: Icon(Icons.calendar_today, size: 18)),
                    onTap: () => _pickDate(_startCtrl),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _endCtrl,
                    readOnly: true,
                    decoration: const InputDecoration(
                        labelText: 'End Date *',
                        hintText: 'DD/MM/YYYY',
                        border: OutlineInputBorder(),
                        suffixIcon: Icon(Icons.calendar_today, size: 18)),
                    onTap: () => _pickDate(_endCtrl),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _status,
              decoration: const InputDecoration(
                  labelText: 'Status', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'active',   child: Text('Active')),
                DropdownMenuItem(value: 'inactive', child: Text('Inactive')),
              ],
              onChanged: (v) => setState(() => _status = v!),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mark as Current Year'),
              subtitle: const Text(
                  'Only one year can be current at a time.',
                  style: TextStyle(fontSize: 12)),
              value: _isCurrentYear,
              onChanged: (v) => setState(() => _isCurrentYear = v),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(_isEdit ? 'Save Changes' : 'Create Academic Year'),
            ),
          ],
        ),
      ),
    );
  }
}
