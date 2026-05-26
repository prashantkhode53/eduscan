import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../constants/app_colors.dart';
import '../providers/whatsapp_provider.dart';
import '../widgets/offline_banner.dart';

class WhatsAppScreen extends StatefulWidget {
  const WhatsAppScreen({super.key});

  @override
  State<WhatsAppScreen> createState() => _WhatsAppScreenState();
}

class _WhatsAppScreenState extends State<WhatsAppScreen> {
  Timer? _pollTimer;
  final _testPhoneCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<WhatsAppProvider>().refresh();
      _startPolling();
    });
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) context.read<WhatsAppProvider>().refresh();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _testPhoneCtrl.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WhatsAppProvider>();
    final theme    = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'WhatsApp Notifications',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (provider.loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: () => context.read<WhatsAppProvider>().refresh(),
            ),
        ],
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => context.read<WhatsAppProvider>().refresh(),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildConnectionCard(context, provider, theme),
                    const SizedBox(height: 16),
                    if (!provider.isConnected) ...[
                      _buildQrSection(context, provider, theme),
                      const SizedBox(height: 16),
                    ],
                    _buildDashboardSection(context, provider, theme),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Section 1 – Connection Status ─────────────────────────────────────────

  Widget _buildConnectionCard(
    BuildContext context, WhatsAppProvider provider, ThemeData theme) {
    final status = provider.status;

    final (stateColor, stateIcon, stateBg) = switch (status.status) {
      'connected'    => (AppColors.success, Icons.check_circle,  AppColors.success.withValues(alpha: 0.1)),
      'qr_pending'   => (AppColors.warning, Icons.qr_code,        AppColors.warning.withValues(alpha: 0.1)),
      'reconnecting' => (AppColors.info,    Icons.sync,           AppColors.info.withValues(alpha: 0.1)),
      'initializing' => (AppColors.info,    Icons.hourglass_top,  AppColors.info.withValues(alpha: 0.1)),
      _              => (AppColors.error,   Icons.cancel_outlined, AppColors.error.withValues(alpha: 0.1)),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: stateBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(stateIcon, color: stateColor, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'WhatsApp Status',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Container(
                            width: 8, height: 8,
                            decoration: BoxDecoration(
                              color: stateColor, shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            status.displayStatus,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: stateColor,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (status.lastConnectedAt != null) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.history, size: 14,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                  const SizedBox(width: 6),
                  Text(
                    'Last connected: ${_formatDateTime(status.lastConnectedAt!)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ],
            if (!provider.serviceReachable && provider.error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber, color: AppColors.error, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        provider.error!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Refresh'),
                    onPressed: provider.loading
                        ? null
                        : () => context.read<WhatsAppProvider>().refresh(),
                  ),
                ),
                if (!status.connected) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('Reconnect'),
                      onPressed: provider.loading
                          ? null
                          : () => context.read<WhatsAppProvider>().reconnect(),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Section 2 – QR Pairing ────────────────────────────────────────────────

  Widget _buildQrSection(
    BuildContext context, WhatsAppProvider provider, ThemeData theme) {
    final qrData = provider.status.qrData;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.qr_code_scanner,
                  color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 10),
                Text(
                  'Scan QR to Connect',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Center(
              child: qrData != null && qrData.isNotEmpty
                  ? _buildQrWidget(qrData)
                  : _buildQrPlaceholder(provider, theme),
            ),
            const SizedBox(height: 20),
            _buildPairingInstructions(theme),
            const SizedBox(height: 12),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.autorenew, size: 14,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                  const SizedBox(width: 4),
                  Text(
                    'Auto-refreshes every 6 seconds',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQrWidget(String qrData) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8, offset: const Offset(0, 2),
          ),
        ],
      ),
      child: QrImageView(
        data: qrData,
        version: QrVersions.auto,
        size: 220,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
        backgroundColor: Colors.white,
      ),
    );
  }

  Widget _buildQrPlaceholder(WhatsAppProvider provider, ThemeData theme) {
    return Container(
      width: 220, height: 220,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant, width: 1.5,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (provider.loading)
            CircularProgressIndicator(
              color: theme.colorScheme.primary, strokeWidth: 2)
          else
            Icon(Icons.qr_code, size: 64,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 12),
          Text(
            provider.loading ? 'Loading QR...' : 'QR not available',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          if (!provider.loading) ...[
            const SizedBox(height: 6),
            Text(
              'Service may still be starting up',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPairingInstructions(ThemeData theme) {
    const steps = [
      'Open WhatsApp on your phone',
      'Tap  ⋮  Menu  →  Linked Devices',
      'Tap Link a Device',
      'Scan this QR code',
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: steps.asMap().entries.map((e) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 20, height: 20,
                  decoration: const BoxDecoration(
                    color: AppColors.info, shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${e.key + 1}',
                    style: const TextStyle(
                      color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(e.value, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Section 3 – Dashboard ─────────────────────────────────────────────────

  Widget _buildDashboardSection(
    BuildContext context, WhatsAppProvider provider, ThemeData theme) {
    final s = provider.status;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bar_chart_outlined,
                  color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 10),
                Text(
                  'Service Dashboard',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _buildStatChip(theme,
                  label: 'Sent Today', value: '${s.sentToday}',
                  color: AppColors.success, icon: Icons.check_circle_outline),
                const SizedBox(width: 10),
                _buildStatChip(theme,
                  label: 'Failed', value: '${s.failedToday}',
                  color: s.failedToday > 0 ? AppColors.error : AppColors.success,
                  icon: s.failedToday > 0
                      ? Icons.error_outline : Icons.check_circle_outline),
                const SizedBox(width: 10),
                _buildStatChip(theme,
                  label: 'Total', value: '${s.totalToday}',
                  color: AppColors.primary, icon: Icons.mail_outline),
              ],
            ),
            if (s.lastSentAt != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.schedule, size: 14,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                  const SizedBox(width: 6),
                  Text(
                    'Last sent: ${_formatDateTime(s.lastSentAt!)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Text('Send Test Message', style: theme.textTheme.labelLarge),
            const SizedBox(height: 10),
            TextFormField(
              controller: _testPhoneCtrl,
              decoration: const InputDecoration(
                labelText: 'Phone Number',
                hintText: '+91XXXXXXXXXX or 10-digit',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.send_outlined, size: 18),
                label: const Text('Send Test'),
                onPressed: !s.connected
                    ? null
                    : () async {
                        final phone = _testPhoneCtrl.text.trim();
                        if (phone.isEmpty) {
                          _showSnack('Enter a phone number', isError: true);
                          return;
                        }
                        final ok = await context
                            .read<WhatsAppProvider>()
                            .sendTestMessage(phone);
                        _showSnack(
                          ok ? 'Test message sent!' : 'Failed — is WhatsApp connected?',
                          isError: !ok,
                        );
                      },
              ),
            ),
            if (!s.connected)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Center(
                  child: Text(
                    'Connect WhatsApp first to send messages',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatChip(
    ThemeData theme, {
    required String label,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    if (now.difference(dt).inMinutes < 1) return 'Just now';
    if (DateFormat('yyyyMMdd').format(dt) == DateFormat('yyyyMMdd').format(now)) {
      return DateFormat('h:mm a').format(dt);
    }
    return DateFormat('d MMM, h:mm a').format(dt);
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppColors.error : AppColors.success,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }
}
