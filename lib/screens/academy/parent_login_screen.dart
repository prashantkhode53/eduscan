import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/parent_auth_provider.dart';
import '../../services/fcm_service.dart';

class ParentLoginScreen extends StatefulWidget {
  const ParentLoginScreen({super.key});

  @override
  State<ParentLoginScreen> createState() => _ParentLoginScreenState();
}

class _ParentLoginScreenState extends State<ParentLoginScreen> {
  final _formKey    = GlobalKey<FormState>();
  final _slugCtrl   = TextEditingController();
  final _idCtrl     = TextEditingController();
  final _mobileCtrl = TextEditingController();

  @override
  void dispose() {
    _slugCtrl.dispose();
    _idCtrl.dispose();
    _mobileCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<ParentAuthProvider>();
    final ok = await auth.login(
      academySlug: _slugCtrl.text.trim(),
      studentId:   _idCtrl.text.trim(),
      mobile:      _mobileCtrl.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      // Upload FCM token in the background after login
      FcmService.uploadTokenIfParent();
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/parent/dashboard', (_) => false);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(auth.error ?? 'Login failed'),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth  = context.watch<ParentAuthProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Parent Login'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(context).padding.bottom + 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Icon
                Center(
                  child: Container(
                    width: 80, height: 80,
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.family_restroom,
                        size: 44, color: Colors.green),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Parent / Guardian',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  'Track your child\'s attendance & fees',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 14,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                ),
                const SizedBox(height: 40),

                // ── Academy Code ───────────────────────────────────────────
                TextFormField(
                  controller: _slugCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Academy Code',
                    hintText:  'e.g. sunshine_tuition',
                    prefixIcon: Icon(Icons.school_outlined),
                    helperText: 'Provided by your academy admin',
                    border: OutlineInputBorder(),
                  ),
                  textCapitalization: TextCapitalization.none,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Academy code is required' : null,
                ),
                const SizedBox(height: 16),

                // ── Student ID ─────────────────────────────────────────────
                TextFormField(
                  controller: _idCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Student ID',
                    hintText:  'e.g. ACF-2026-00001',
                    prefixIcon: Icon(Icons.badge_outlined),
                    helperText: 'Found on your enrollment receipt',
                    border: OutlineInputBorder(),
                  ),
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Student ID is required' : null,
                ),
                const SizedBox(height: 16),

                // ── Parent Mobile ──────────────────────────────────────────
                TextFormField(
                  controller: _mobileCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Your Mobile Number',
                    hintText:  '10-digit mobile number',
                    prefixIcon: Icon(Icons.phone_outlined),
                    helperText: 'The number registered with the academy',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _login(),
                  validator: (v) =>
                      v == null || v.trim().replaceAll(RegExp(r'\D'), '').length < 10
                          ? 'Enter a valid 10-digit mobile number'
                          : null,
                ),
                const SizedBox(height: 32),

                FilledButton.icon(
                  onPressed: auth.loading ? null : _login,
                  icon: auth.loading
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.login),
                  label: const Text('Sign In'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: Colors.green,
                  ),
                ),
                const SizedBox(height: 24),

                // Help text
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: theme.colorScheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(Icons.info_outline, size: 16,
                            color: theme.colorScheme.primary),
                        const SizedBox(width: 6),
                        Text('Where do I find these?',
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                color: theme.colorScheme.primary)),
                      ]),
                      const SizedBox(height: 8),
                      _infoRow('Academy Code',
                          'Shared by your academy admin (e.g. on the fee receipt)'),
                      _infoRow('Student ID',
                          'Printed on your enrollment receipt (e.g. ACF-2026-00001)'),
                      _infoRow('Mobile Number',
                          'The parent number you gave at the time of enrollment'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String detail) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('• ', style: TextStyle(fontSize: 12)),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                  children: [
                    TextSpan(
                        text: '$label: ',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(text: detail),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}
