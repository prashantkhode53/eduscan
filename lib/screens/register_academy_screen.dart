import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';

class RegisterAcademyScreen extends StatefulWidget {
  const RegisterAcademyScreen({super.key});

  @override
  State<RegisterAcademyScreen> createState() => _RegisterAcademyScreenState();
}

class _RegisterAcademyScreenState extends State<RegisterAcademyScreen> {
  final _formKey = GlobalKey<FormState>();
  final _academyNameCtrl = TextEditingController();
  final _adminNameCtrl   = TextEditingController();
  final _emailCtrl       = TextEditingController();
  final _phoneCtrl       = TextEditingController();
  final _addressCtrl     = TextEditingController();
  final _passwordCtrl    = TextEditingController();
  final _confirmCtrl     = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirm  = true;
  bool _loading         = false;
  int  _step            = 0; // 0 = academy info, 1 = admin info

  @override
  void dispose() {
    _academyNameCtrl.dispose();
    _adminNameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final data = await ApiService.registerAcademy(
        academyName: _academyNameCtrl.text.trim(),
        adminName:   _adminNameCtrl.text.trim(),
        email:       _emailCtrl.text.trim(),
        phone:       _phoneCtrl.text.trim(),
        password:    _passwordCtrl.text,
        address:     _addressCtrl.text.trim(),
      );
      final token   = data['token'] as String;
      final academy = data['academy'] as Map<String, dynamic>;
      await StorageService.saveToken(token);
      await StorageService.saveAcademySlug(academy['slug'] as String);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Welcome to ${academy['name']}!'),
            backgroundColor: Colors.green,
          ),
        );
        // TODO Phase 2: Navigate to academy admin dashboard
        Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register Academy'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: (_step + 1) / 2,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Icon(Icons.school_outlined,
                    size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 12),
                Text(
                  _step == 0 ? 'Academy Details' : 'Admin Account',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                Text(
                  _step == 0
                      ? 'Tell us about your tuition academy'
                      : 'Set up your admin credentials',
                  style: TextStyle(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),

                if (_step == 0) ..._academyFields(theme),
                if (_step == 1) ..._adminFields(theme),

                const SizedBox(height: 24),

                // Navigation buttons
                if (_step == 0)
                  FilledButton(
                    onPressed: () {
                      if (_formKey.currentState!.validate()) {
                        setState(() => _step = 1);
                      }
                    },
                    child: const Text('Next'),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _loading
                              ? null
                              : () => setState(() => _step = 0),
                          child: const Text('Back'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton(
                          onPressed: _loading ? null : _submit,
                          child: _loading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Text('Create Academy'),
                        ),
                      ),
                    ],
                  ),

                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Already have an account? Login'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _academyFields(ThemeData theme) => [
        // Academy Name: slug-style — spaces auto-convert to underscores,
        // disallowed chars are silently blocked, max 17 characters.
        TextFormField(
          controller: _academyNameCtrl,
          maxLength: 17,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          inputFormatters: [_AcademyNameFormatter()],
          decoration: const InputDecoration(
            labelText: 'Academy Name',
            hintText: 'Eg. Demo_Academy',
            prefixIcon: Icon(Icons.business_outlined),
            border: OutlineInputBorder(),
            helperText: 'Spaces convert to underscores. Letters, numbers, _ only.',
            helperMaxLines: 2,
            counterStyle: TextStyle(fontSize: 11),
          ),
          validator: (v) {
            final val = v?.trim() ?? '';
            if (val.length < 3) return 'Minimum 3 characters required';
            if (val.length > 17) return 'Academy Name cannot exceed 17 characters';
            if (val.endsWith('_')) return 'Name cannot end with an underscore';
            if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(val)) {
              return 'Only letters, numbers, and underscores are allowed';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        _field(
          controller: _phoneCtrl,
          label: 'Academy Phone',
          hint: '9876543210',
          icon: Icons.phone_outlined,
          keyboardType: TextInputType.phone,
          maxLength: 10,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          validator: (v) => v == null || v.trim().length != 10
              ? 'Enter a valid 10-digit phone number'
              : null,
        ),
        const SizedBox(height: 16),
        _field(
          controller: _addressCtrl,
          label: 'Address (optional)',
          hint: 'Building, Street, City',
          icon: Icons.location_on_outlined,
          maxLines: 2,
        ),
      ];

  List<Widget> _adminFields(ThemeData theme) => [
        _field(
          controller: _adminNameCtrl,
          label: 'Your Full Name',
          hint: 'e.g. Rajesh Sharma',
          icon: Icons.person_outlined,
          validator: (v) =>
              v == null || v.trim().isEmpty ? 'Name is required' : null,
        ),
        const SizedBox(height: 16),
        _field(
          controller: _emailCtrl,
          label: 'Email Address',
          hint: 'admin@youracademy.com',
          icon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
          validator: (v) {
            if (v == null || v.trim().isEmpty) return 'Email is required';
            if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim())) {
              return 'Enter a valid email';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _passwordCtrl,
          obscureText: _obscurePassword,
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outlined),
            suffixIcon: IconButton(
              icon: Icon(_obscurePassword
                  ? Icons.visibility_off
                  : Icons.visibility),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
            border: const OutlineInputBorder(),
          ),
          validator: (v) =>
              v == null || v.length < 8 ? 'Minimum 8 characters' : null,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _confirmCtrl,
          obscureText: _obscureConfirm,
          decoration: InputDecoration(
            labelText: 'Confirm Password',
            prefixIcon: const Icon(Icons.lock_outlined),
            suffixIcon: IconButton(
              icon: Icon(_obscureConfirm
                  ? Icons.visibility_off
                  : Icons.visibility),
              onPressed: () =>
                  setState(() => _obscureConfirm = !_obscureConfirm),
            ),
            border: const OutlineInputBorder(),
          ),
          validator: (v) =>
              v != _passwordCtrl.text ? 'Passwords do not match' : null,
        ),
      ];

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
    int? maxLength,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      maxLength: maxLength,
      inputFormatters: inputFormatters,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
        counterText: maxLength != null ? '' : null,
      ),
      validator: validator,
    );
  }
}

// Real-time formatter for the Academy Name field:
// • spaces → underscores
// • disallowed chars (not [a-zA-Z0-9_]) silently removed
// • consecutive underscores collapsed to one
// • leading underscores stripped (name cannot start with _)
// • hard cap at 17 characters
class _AcademyNameFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    String text = newValue.text
        .replaceAll(' ', '_')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+'), '');

    if (text.length > 17) text = text.substring(0, 17);

    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
