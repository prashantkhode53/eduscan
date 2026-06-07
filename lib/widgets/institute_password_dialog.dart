import 'package:flutter/material.dart';
import '../services/parent_api_service.dart';
import '../providers/parent_auth_provider.dart';
import '../services/fcm_service.dart';
import 'package:provider/provider.dart';

/// Dialog shown on the face-scan step when the admin has enabled a fallback
/// institute password for this student.  On success it completes the parent
/// login exactly like a face scan would.
class InstitutePasswordDialog extends StatefulWidget {
  final String sessionToken;

  const InstitutePasswordDialog({super.key, required this.sessionToken});

  @override
  State<InstitutePasswordDialog> createState() =>
      _InstitutePasswordDialogState();
}

class _InstitutePasswordDialogState extends State<InstitutePasswordDialog> {
  final _formKey   = GlobalKey<FormState>();
  final _passCtrl  = TextEditingController();
  bool _obscure    = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _submitting = true; _error = null; });

    try {
      final data = await ParentApiService.verifyPassword(
        sessionToken: widget.sessionToken,
        password:     _passCtrl.text,
      );

      if (!mounted) return;

      final auth = context.read<ParentAuthProvider>();
      await auth.completeLogin(
        token:       data['token']   as String,
        studentData: data['student'] as Map<String, dynamic>,
        academyData: data['academy'] as Map<String, dynamic>,
      );

      FcmService.uploadTokenIfParent();

      if (mounted) {
        Navigator.of(context).pop(); // close dialog
        Navigator.of(context)
            .pushNamedAndRemoveUntil('/parent/dashboard', (_) => false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.lock_outline, color: theme.colorScheme.primary, size: 22),
          const SizedBox(width: 8),
          const Text('Institute Password'),
        ],
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Enter the password provided by your institute.',
              style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller:    _passCtrl,
              obscureText:   _obscure,
              autofocus:     true,
              decoration: InputDecoration(
                labelText:  'Password',
                prefixIcon: const Icon(Icons.vpn_key_outlined),
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscure ? Icons.visibility_outlined
                               : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                border: const OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              validator: (v) =>
                  v == null || v.isEmpty ? 'Password is required' : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        color: Colors.red.shade700, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_error!,
                          style: TextStyle(
                              fontSize: 12, color: Colors.red.shade700)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Login'),
        ),
      ],
    );
  }
}
