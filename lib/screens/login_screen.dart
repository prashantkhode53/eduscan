import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../widgets/custom_button.dart';
import 'register_academy_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey      = GlobalKey<FormState>();
  final _slugCtrl     = TextEditingController();
  final _emailCtrl    = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure = true;

  // 5-tap logo easter egg — counter resets if no tap within 2 s
  int    _tapCount = 0;
  Timer? _tapResetTimer;

  @override
  void dispose() {
    _slugCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _tapResetTimer?.cancel();
    super.dispose();
  }

  // ── 5-tap detection ───────────────────────────────────────────────────────

  void _onLogoTap() {
    _tapResetTimer?.cancel();
    _tapCount++;

    if (_tapCount >= 5) {
      _tapCount = 0;
      HapticFeedback.mediumImpact();
      _showAdminSheet();
      return;
    }

    // Subtle haptic on each tap — no visual feedback (keeps it invisible)
    HapticFeedback.lightImpact();

    // Reset count if user stops tapping for 2 s
    _tapResetTimer = Timer(const Duration(seconds: 2), () {
      _tapCount = 0;
    });
  }

  void _showAdminSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const _AdminLoginSheet(),
    );
  }

  // ── Academy login ─────────────────────────────────────────────────────────

  String _routeForRole(String role) {
    switch (role) {
      case 'teacher': return '/academy/teacher';
      case 'student': return '/academy/student';
      case 'parent':  return '/academy/parent';
      default:        return '/academy/dashboard';
    }
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<AuthProvider>();
    final ok = await auth.loginAcademy(
      _emailCtrl.text.trim(),
      _passwordCtrl.text,
      _slugCtrl.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      final role = auth.academyUser?.role ?? 'admin';
      Navigator.of(context)
          .pushNamedAndRemoveUntil(_routeForRole(role), (_) => false);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(auth.error ?? 'Login failed'),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final auth   = context.watch<AuthProvider>();
    final theme  = Theme.of(context);
    final bottom = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, 0, 24, bottom + 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 56),

              // ── Logo — tap 5× to reveal admin panel ───────────────────────
              Center(
                child: GestureDetector(
                  onTap: _onLogoTap,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary
                              .withValues(alpha: 0.35),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.face_retouching_natural,
                        size: 46, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // ── App name & tagline ─────────────────────────────────────────
              Text(
                'EduScan',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Smart Attendance for Academies',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                    fontSize: 14),
              ),
              const SizedBox(height: 44),

              // ── Academy login form ─────────────────────────────────────────
              Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Academy Code
                    TextFormField(
                      controller: _slugCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Academy Code',
                        hintText: 'e.g. sunshine_tuition',
                        prefixIcon: Icon(Icons.business_outlined),
                        helperText: 'Provided by your academy admin',
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      textCapitalization: TextCapitalization.none,
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'Academy code is required'
                          : null,
                    ),
                    const SizedBox(height: 16),

                    // Email
                    TextFormField(
                      controller: _emailCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.email_outlined),
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'Email is required'
                          : null,
                    ),
                    const SizedBox(height: 16),

                    // Password
                    TextFormField(
                      controller: _passwordCtrl,
                      obscureText: _obscure,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined),
                          onPressed: () =>
                              setState(() => _obscure = !_obscure),
                        ),
                      ),
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _login(),
                      validator: (v) => v == null || v.isEmpty
                          ? 'Password is required'
                          : null,
                    ),
                    const SizedBox(height: 28),

                    // Sign In button
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
                          minimumSize: const Size.fromHeight(52)),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 36),
              const Divider(),
              const SizedBox(height: 20),

              // ── Parent login ───────────────────────────────────────────────
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    Navigator.pushNamed(context, '/parent/login'),
                icon: const Icon(Icons.family_restroom_outlined),
                label: const Text('Parent / Guardian Login'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),

              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 20),

              // ── Register academy ───────────────────────────────────────────
              Text(
                "Don't have an academy yet?",
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                    fontSize: 13),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const RegisterAcademyScreen()),
                ),
                icon: const Icon(Icons.add_business_outlined),
                label: const Text('Register New Academy'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Super Admin login sheet ───────────────────────────────────────────────────
// Revealed only by tapping the logo 5 times. No visible entry point.

class _AdminLoginSheet extends StatefulWidget {
  const _AdminLoginSheet();

  @override
  State<_AdminLoginSheet> createState() => _AdminLoginSheetState();
}

class _AdminLoginSheetState extends State<_AdminLoginSheet> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool   _obscure        = true;
  int    _failedAttempts = 0;
  int    _lockSeconds    = 0;
  Timer? _lockTimer;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _lockTimer?.cancel();
    super.dispose();
  }

  void _startLockTimer() {
    _lockSeconds = 60;
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        _lockSeconds--;
        if (_lockSeconds <= 0) {
          t.cancel();
          _failedAttempts = 0;
        }
      });
    });
  }

  Future<void> _login() async {
    if (_lockSeconds > 0) return;
    if (_usernameCtrl.text.trim().isEmpty || _passwordCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Username and password are required'),
            behavior: SnackBarBehavior.floating));
      return;
    }

    final auth = context.read<AuthProvider>();
    final ok   = await auth.login(
        _usernameCtrl.text.trim(), _passwordCtrl.text);

    if (!mounted) return;
    if (ok) {
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/dashboard', (_) => false);
    } else {
      setState(() => _failedAttempts++);
      if (_failedAttempts >= 5) _startLockTimer();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(auth.error ?? 'Login failed'),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  void _showForgotPassword() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const _ForgotPasswordSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth  = context.watch<AuthProvider>();
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),

          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.admin_panel_settings_outlined,
                    color: theme.colorScheme.error, size: 22),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('System Administrator',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  Text('Restricted access',
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.5))),
                ],
              ),
            ],
          ),
          const SizedBox(height: 28),

          // Username
          TextFormField(
            controller: _usernameCtrl,
            decoration: const InputDecoration(
              labelText: 'Username',
              prefixIcon: Icon(Icons.person_outline),
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.next,
            autocorrect: false,
            textCapitalization: TextCapitalization.none,
          ),
          const SizedBox(height: 16),

          // Password
          TextFormField(
            controller: _passwordCtrl,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(Icons.lock_outline),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _login(),
          ),
          const SizedBox(height: 16),

          // Lock warning
          if (_lockSeconds > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                const Icon(Icons.lock, color: Colors.red, size: 16),
                const SizedBox(width: 8),
                Text('Too many attempts. Try again in ${_lockSeconds}s',
                    style: const TextStyle(color: Colors.red, fontSize: 13)),
              ]),
            ),

          // Sign In button
          FilledButton.icon(
            onPressed: (_lockSeconds > 0 || auth.loading) ? null : _login,
            icon: auth.loading
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.login),
            label: const Text('Sign In'),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50)),
          ),
          const SizedBox(height: 4),

          // Forgot password
          TextButton(
            onPressed: _showForgotPassword,
            child: const Text('Forgot password?'),
          ),
        ],
      ),
    );
  }
}

// ── Forgot password sheet (SuperAdmin only) ───────────────────────────────────

class _ForgotPasswordSheet extends StatefulWidget {
  const _ForgotPasswordSheet();

  @override
  State<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  int    _step       = 0; // 0=email  1=otp  2=new password
  bool   _loading    = false;
  String? _resetToken;

  final _emailCtrl   = TextEditingController();
  final _otpCtrl     = TextEditingController();
  final _newPassCtrl = TextEditingController();

  @override
  void dispose() {
    _emailCtrl.dispose();
    _otpCtrl.dispose();
    _newPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    if (_emailCtrl.text.trim().isEmpty) return;
    setState(() => _loading = true);
    try {
      await ApiService.forgotPassword(_emailCtrl.text.trim());
      setState(() { _step = 1; _loading = false; });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            behavior: SnackBarBehavior.floating));
      }
    }
  }

  Future<void> _verifyOtp() async {
    if (_otpCtrl.text.trim().length != 6) return;
    setState(() => _loading = true);
    try {
      _resetToken = await ApiService.verifyOtp(
          _emailCtrl.text.trim(), _otpCtrl.text.trim());
      setState(() { _step = 2; _loading = false; });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            behavior: SnackBarBehavior.floating));
      }
    }
  }

  Future<void> _resetPassword() async {
    if (_newPassCtrl.text.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password must be at least 8 characters'),
            behavior: SnackBarBehavior.floating));
      return;
    }
    setState(() => _loading = true);
    try {
      await ApiService.resetPassword(_resetToken!, _newPassCtrl.text);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Password reset successful. Please sign in.'),
              backgroundColor: Colors.green,
              behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            behavior: SnackBarBehavior.floating));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),

          Text('Reset Password',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            ['Enter your registered email',
             'Enter the OTP sent to your email',
             'Set your new password'][_step],
            style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontSize: 13),
          ),
          const SizedBox(height: 24),

          // Step indicator
          Row(
            children: List.generate(3, (i) {
              final done   = i < _step;
              final active = i == _step;
              return Expanded(
                child: Container(
                  margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
                  height: 4,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: done || active
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 24),

          if (_step == 0) ...[
            TextFormField(
              controller: _emailCtrl,
              decoration: const InputDecoration(
                labelText: 'Registered Email',
                prefixIcon: Icon(Icons.email_outlined),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 20),
            CustomButton(label: 'Send OTP', onPressed: _sendOtp, loading: _loading),
          ] else if (_step == 1) ...[
            Text('OTP sent to ${_emailCtrl.text}',
                style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 12),
            TextFormField(
              controller: _otpCtrl,
              decoration: const InputDecoration(
                labelText: '6-digit OTP',
                prefixIcon: Icon(Icons.pin_outlined),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              maxLength: 6,
            ),
            const SizedBox(height: 8),
            CustomButton(label: 'Verify OTP', onPressed: _verifyOtp, loading: _loading),
            TextButton(
              onPressed: _loading ? null : () => setState(() => _step = 0),
              child: const Text('Change email'),
            ),
          ] else ...[
            TextFormField(
              controller: _newPassCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New Password (min 8 characters)',
                prefixIcon: Icon(Icons.lock_outline),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            CustomButton(
                label: 'Set New Password',
                onPressed: _resetPassword,
                loading: _loading),
          ],
        ],
      ),
    );
  }
}
