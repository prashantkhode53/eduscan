import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/academy_api_service.dart';

class QrCodeScreen extends StatefulWidget {
  const QrCodeScreen({super.key});

  @override
  State<QrCodeScreen> createState() => _QrCodeScreenState();
}

class _QrCodeScreenState extends State<QrCodeScreen> {
  List<Map<String, dynamic>> _codes = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.listQrCodes();
      if (!mounted) return;
      setState(() { _codes = data; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; });
    }
  }

  Future<void> _activate(String id) async {
    try {
      await AcademyApiService.activateQrCode(id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> qr) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete QR Code'),
        content: Text('Delete "${qr['name']}"? This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await AcademyApiService.deleteQrCode(qr['id'] as String);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')), backgroundColor: Colors.red));
      }
    }
  }

  void _openEditor({Map<String, dynamic>? existing}) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => QrCodeEditorScreen(existing: existing)),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('QR Code Management'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load)
              : _codes.isEmpty
                  ? _EmptyState(onAdd: () => _openEditor())
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _codes.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _QrCard(
                          qr: _codes[i],
                          onActivate: () => _activate(_codes[i]['id'] as String),
                          onEdit: () => _openEditor(existing: _codes[i]),
                          onDelete: () => _delete(_codes[i]),
                        ),
                      ),
                    ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('Add QR Code'),
      ),
    );
  }
}

// ── QR card ──────────────────────────────────────────────────────────────────

class _QrCard extends StatelessWidget {
  final Map<String, dynamic> qr;
  final VoidCallback onActivate, onEdit, onDelete;
  const _QrCard({required this.qr, required this.onActivate, required this.onEdit, required this.onDelete});

  Uint8List? _imageBytes() {
    final data = qr['image_data'] as String? ?? '';
    try {
      final b64 = data.contains(',') ? data.split(',').last : data;
      return base64Decode(b64);
    } catch (_) { return null; }
  }

  @override
  Widget build(BuildContext context) {
    final theme    = Theme.of(context);
    final isActive = qr['is_active'] as bool? ?? false;
    final bytes    = _imageBytes();

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isActive
            ? BorderSide(color: theme.colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            // QR preview
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: bytes != null
                  ? Image.memory(bytes, width: 80, height: 80, fit: BoxFit.cover)
                  : Container(
                      width: 80, height: 80,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(Icons.qr_code_2, size: 40,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.4))),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(qr['name'] as String? ?? 'QR Code',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (isActive)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text('ACTIVE',
                              style: TextStyle(
                                  fontSize: 10, fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary)),
                        ),
                    ],
                  ),
                  if ((qr['description'] as String?)?.isNotEmpty ?? false) ...[
                    const SizedBox(height: 4),
                    Text(qr['description'] as String,
                        style: TextStyle(fontSize: 12,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (!isActive)
                        OutlinedButton.icon(
                          onPressed: onActivate,
                          icon: const Icon(Icons.check_circle_outline, size: 16),
                          label: const Text('Set Active'),
                          style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              visualDensity: VisualDensity.compact),
                        )
                      else
                        Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 18),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        onPressed: onEdit, tooltip: 'Edit',
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                        onPressed: onDelete, tooltip: 'Delete',
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── QR Code editor (Add / Edit) ───────────────────────────────────────────────

class QrCodeEditorScreen extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const QrCodeEditorScreen({super.key, this.existing});

  @override
  State<QrCodeEditorScreen> createState() => _QrCodeEditorScreenState();
}

class _QrCodeEditorScreenState extends State<QrCodeEditorScreen> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String? _imageData;  // base64 data URI
  Uint8List? _imageBytes;
  bool _isActive = false;
  bool _saving   = false;
  String? _pickError;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      final e = widget.existing!;
      _nameCtrl.text = e['name'] as String? ?? '';
      _descCtrl.text = e['description'] as String? ?? '';
      _isActive = e['is_active'] as bool? ?? false;
      final data = e['image_data'] as String? ?? '';
      if (data.isNotEmpty) {
        _imageData = data;
        try {
          final b64 = data.contains(',') ? data.split(',').last : data;
          _imageBytes = base64Decode(b64);
        } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    setState(() => _pickError = null);
    final picker = ImagePicker();
    final file   = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1024,
      maxHeight: 1024,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > 2 * 1024 * 1024) {
      setState(() => _pickError = 'Image is too large. Please choose an image under 2 MB.');
      return;
    }
    final b64  = base64Encode(bytes);
    final mime = file.name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    setState(() {
      _imageData  = 'data:$mime;base64,$b64';
      _imageBytes = bytes;
    });
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('QR name is required')));
      return;
    }
    if (!_isEdit && _imageData == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select a QR code image')));
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isEdit) {
        final body = <String, dynamic>{
          'name':        _nameCtrl.text.trim(),
          'description': _descCtrl.text.trim().isNotEmpty ? _descCtrl.text.trim() : null,
          'is_active':   _isActive,
          if (_imageData != null) 'image_data': _imageData,
        };
        await AcademyApiService.updateQrCode(widget.existing!['id'] as String, body);
      } else {
        await AcademyApiService.createQrCode({
          'name':        _nameCtrl.text.trim(),
          'description': _descCtrl.text.trim().isNotEmpty ? _descCtrl.text.trim() : null,
          'image_data':  _imageData!,
          'is_active':   _isActive,
        });
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit QR Code' : 'Add QR Code')),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Image picker ─────────────────────────────────────────────
            GestureDetector(
              onTap: _pickImage,
              child: Container(
                height: 200,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _pickError != null
                        ? theme.colorScheme.error
                        : theme.colorScheme.outlineVariant,
                    style: BorderStyle.solid,
                  ),
                ),
                child: _imageBytes != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(_imageBytes!, fit: BoxFit.contain))
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.qr_code_scanner,
                              size: 56,
                              color: theme.colorScheme.primary.withValues(alpha: 0.5)),
                          const SizedBox(height: 10),
                          Text('Tap to select QR code image',
                              style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                          const SizedBox(height: 4),
                          Text('JPG or PNG, max 2 MB',
                              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.4))),
                        ],
                      ),
              ),
            ),
            if (_imageBytes != null) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.swap_horiz, size: 16),
                label: const Text('Change Image'),
              ),
            ],
            if (_pickError != null) ...[
              const SizedBox(height: 4),
              Text(_pickError!, style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
            ],
            const SizedBox(height: 20),

            // ── Name ─────────────────────────────────────────────────────
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'QR Name / Label *',
                hintText: 'e.g. Academy UPI QR',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),

            // ── Description ──────────────────────────────────────────────
            TextFormField(
              controller: _descCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Payment Instructions / Description (optional)',
                hintText: 'e.g. Scan to pay via UPI. Add student ID in remarks.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),

            // ── Active toggle ─────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                children: [
                  Icon(Icons.circle, size: 10,
                      color: _isActive ? Colors.green : Colors.grey),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Set as Active QR Code',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        Text('Only one QR code can be active at a time. Enabling this will deactivate the current active QR.',
                            style: TextStyle(fontSize: 11,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                      ],
                    ),
                  ),
                  Switch(value: _isActive, onChanged: (v) => setState(() => _isActive = v)),
                ],
              ),
            ),
            const SizedBox(height: 24),

            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save_outlined),
              label: Text(_saving ? 'Saving...' : (_isEdit ? 'Update QR Code' : 'Save QR Code')),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.qr_code_2_outlined, size: 72,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.25)),
            const SizedBox(height: 16),
            const Text('No QR Codes Added',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Add your academy payment QR code so students can scan and pay directly.',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add QR Code'),
              style: FilledButton.styleFrom(minimumSize: const Size(200, 48)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 56, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 12),
          const Text('Could not load QR codes', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
        ],
      ),
    ),
  );
}
