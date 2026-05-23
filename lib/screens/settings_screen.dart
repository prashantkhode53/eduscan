import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loadingSettings = true;
  bool _savingUrl = false;
  bool _regenLoading = false;

  final _urlCtrl = TextEditingController();
  final _currentPwCtrl = TextEditingController();
  final _newPwCtrl = TextEditingController();
  final _confirmPwCtrl = TextEditingController();

  Map<String, String> _serverSettings = {};
  String? _kioskKey;
  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _currentPwCtrl.dispose();
    _newPwCtrl.dispose();
    _confirmPwCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadingSettings = true);
    final savedUrl = await StorageService.getApiBaseUrl();
    _urlCtrl.text = savedUrl ?? 'http://localhost:3000';
    try {
      final data = await ApiService.getSettings();
      _serverSettings = Map<String, String>.fromEntries(
        (data['settings'] as List? ?? []).map((s) =>
            MapEntry(s['key'] as String, s['value'] as String)),
      );
      _kioskKey = _serverSettings['kiosk_api_key'];
    } catch (_) {}
    setState(() => _loadingSettings = false);
  }

  Future<void> _saveUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() => _savingUrl = true);
    await StorageService.saveApiBaseUrl(url);
    setState(() => _savingUrl = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('API URL saved. Restart app to apply.'),
            backgroundColor: Colors.green),
      );
    }
  }

  Future<void> _regenKioskKey() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Regenerate Kiosk Key'),
        content: const Text(
            'The current kiosk key will be invalidated. All kiosk devices will need to be reconfigured.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.orange),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Regenerate')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _regenLoading = true);
    try {
      final newKey = await ApiService.regenKioskKey();
      await StorageService.saveKioskKey(newKey);
      setState(() => _kioskKey = newKey);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Kiosk key regenerated'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
    setState(() => _regenLoading = false);
  }

  Future<void> _changePassword() async {
    final current = _currentPwCtrl.text.trim();
    final newPw = _newPwCtrl.text.trim();
    final confirm = _confirmPwCtrl.text.trim();

    if (current.isEmpty || newPw.isEmpty || confirm.isEmpty) {
      _showError('All password fields are required');
      return;
    }
    if (newPw != confirm) {
      _showError('New passwords do not match');
      return;
    }
    if (newPw.length < 8) {
      _showError('Password must be at least 8 characters');
      return;
    }

    try {
      await ApiService.changePassword(current, newPw);
      _currentPwCtrl.clear();
      _newPwCtrl.clear();
      _confirmPwCtrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Password changed successfully'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      _showError(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  void _showQrDialog() {
    if (_kioskKey == null) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Kiosk QR Code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(
              data: _kioskKey!,
              version: QrVersions.auto,
              size: 220,
            ),
            const SizedBox(height: 8),
            const Text(
              'Scan this QR code with a kiosk device to configure it automatically.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loadingSettings
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Profile
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor:
                              theme.colorScheme.primary.withOpacity(0.15),
                          child: Text(
                            (auth.admin?.displayName ?? 'A').substring(0, 1).toUpperCase(),
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(auth.admin?.displayName ?? 'Admin',
                                  style: theme.textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.bold)),
                              Text(auth.admin?.email ?? '',
                                  style: TextStyle(
                                      color: theme.colorScheme.onSurface
                                          .withOpacity(0.6),
                                      fontSize: 13)),
                              Text('Role: ${auth.admin?.role ?? 'admin'}',
                                  style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      fontSize: 12)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Appearance
                _sectionHeader('Appearance', theme),
                Card(
                  child: SwitchListTile(
                    title: const Text('Dark Mode'),
                    subtitle: const Text('Toggle dark/light theme'),
                    secondary: Icon(
                      auth.themeMode == ThemeMode.dark
                          ? Icons.dark_mode
                          : Icons.light_mode,
                    ),
                    value: auth.themeMode == ThemeMode.dark,
                    onChanged: (_) => auth.toggleTheme(),
                  ),
                ),
                const SizedBox(height: 16),

                // API connection
                _sectionHeader('API Connection', theme),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _urlCtrl,
                          decoration: const InputDecoration(
                            labelText: 'API Base URL',
                            hintText: 'http://192.168.1.100:3000',
                            prefixIcon: Icon(Icons.link),
                          ),
                          keyboardType: TextInputType.url,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _savingUrl ? null : _saveUrl,
                          icon: _savingUrl
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.save),
                          label: const Text('Save URL'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Kiosk
                _sectionHeader('Kiosk Configuration', theme),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_kioskKey != null) ...[
                          Text('Current Kiosk Key',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.6))),
                          const SizedBox(height: 4),
                          SelectableText(
                            _kioskKey!,
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: theme.colorScheme.primary),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              OutlinedButton.icon(
                                onPressed: _showQrDialog,
                                icon: const Icon(Icons.qr_code, size: 18),
                                label: const Text('Show QR'),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton.icon(
                                onPressed: _regenLoading ? null : _regenKioskKey,
                                icon: _regenLoading
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.refresh, size: 18),
                                label: const Text('Regenerate'),
                                style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.orange),
                              ),
                            ],
                          ),
                        ] else
                          Text('Kiosk key not available',
                              style: TextStyle(
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.5))),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Change password
                _sectionHeader('Change Password', theme),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        TextField(
                          controller: _currentPwCtrl,
                          obscureText: _obscureCurrent,
                          decoration: InputDecoration(
                            labelText: 'Current Password',
                            suffixIcon: IconButton(
                              icon: Icon(_obscureCurrent
                                  ? Icons.visibility_off
                                  : Icons.visibility),
                              onPressed: () => setState(
                                  () => _obscureCurrent = !_obscureCurrent),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _newPwCtrl,
                          obscureText: _obscureNew,
                          decoration: InputDecoration(
                            labelText: 'New Password',
                            suffixIcon: IconButton(
                              icon: Icon(_obscureNew
                                  ? Icons.visibility_off
                                  : Icons.visibility),
                              onPressed: () =>
                                  setState(() => _obscureNew = !_obscureNew),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _confirmPwCtrl,
                          obscureText: _obscureConfirm,
                          decoration: InputDecoration(
                            labelText: 'Confirm New Password',
                            suffixIcon: IconButton(
                              icon: Icon(_obscureConfirm
                                  ? Icons.visibility_off
                                  : Icons.visibility),
                              onPressed: () => setState(
                                  () => _obscureConfirm = !_obscureConfirm),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _changePassword,
                          icon: const Icon(Icons.lock_reset),
                          label: const Text('Change Password'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Logout
                _sectionHeader('Account', theme),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.logout, color: Colors.red),
                    title: const Text('Log Out',
                        style: TextStyle(color: Colors.red)),
                    onTap: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Log Out'),
                          content:
                              const Text('Are you sure you want to log out?'),
                          actions: [
                            TextButton(
                                onPressed: () =>
                                    Navigator.pop(context, false),
                                child: const Text('Cancel')),
                            FilledButton(
                                style: FilledButton.styleFrom(
                                    backgroundColor: Colors.red),
                                onPressed: () =>
                                    Navigator.pop(context, true),
                                child: const Text('Log Out')),
                          ],
                        ),
                      );
                      if (confirm == true && mounted) {
                        await context.read<AuthProvider>().logout();
                        Navigator.of(context)
                            .pushNamedAndRemoveUntil('/login', (_) => false);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 32),

                Center(
                  child: Text(
                    'EduScan v1.0.0',
                    style: TextStyle(
                        color: theme.colorScheme.onSurface.withOpacity(0.4),
                        fontSize: 12),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionHeader(String title, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
