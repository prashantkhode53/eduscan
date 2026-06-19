import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';
import 'sent_notifications_tab.dart';

/// Admin → Quick Actions → Send Notifications.
/// Two tabs: "Send" (broadcast a message to parents filtered by Academic
/// Year(s) + Course(s)) and "Sent" (history of past broadcasts).
class SendNotificationScreen extends StatefulWidget {
  const SendNotificationScreen({super.key});

  @override
  State<SendNotificationScreen> createState() => _SendNotificationScreenState();
}

class _SendNotificationScreenState extends State<SendNotificationScreen> {
  // Max message length. The backend (settings.notification_max_chars) is the
  // source of truth and re-validates; this mirrors its seeded default of 500.
  static const int _maxChars = 500;

  List<Map<String, dynamic>> _years   = [];
  List<Map<String, dynamic>> _courses = [];      // active courses only
  final Set<String> _selectedYearIds   = {};
  final Set<String> _selectedCourseIds = {};
  final _messageCtrl = TextEditingController();

  bool    _loading = true;
  String? _loadError;
  bool    _sending = false;

  // Lets the Send tab reload the Sent-history tab after a successful broadcast.
  final _sentTabKey = GlobalKey<SentNotificationsTabState>();

  @override
  void initState() {
    super.initState();
    _load();
    _messageCtrl.addListener(() => setState(() {})); // live char counter
  }

  @override
  void dispose() {
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _loadError = null; });
    try {
      final results = await Future.wait([
        AcademyApiService.getAcademicYears(),
        AcademyApiService.getCourses(),
      ]);
      if (!mounted) return;
      final years   = results[0].cast<Map<String, dynamic>>();
      final courses = results[1]
          .cast<Map<String, dynamic>>()
          .where((c) => c['is_active'] == true)   // active courses only
          .toList();
      setState(() {
        _years    = years;
        _courses  = courses;
        _loading  = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading   = false;
        _loadError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  String _yearName(Map<String, dynamic> y) =>
      (y['academic_year_name'] ?? y['name'] ?? '').toString();

  Future<void> _send() async {
    final message = _messageCtrl.text.trim();

    // Validate mandatory fields.
    if (_selectedYearIds.isEmpty) {
      _snack('Please select at least one academic year.');
      return;
    }
    if (_selectedCourseIds.isEmpty) {
      _snack('Please select at least one course.');
      return;
    }
    if (message.isEmpty) {
      _snack('Please enter a notification message.');
      return;
    }
    if (message.length > _maxChars) {
      _snack('Message exceeds the $_maxChars-character limit.');
      return;
    }

    // Confirmation before sending.
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Send Notification'),
        content: Text(
          'Send this notification to all parents in '
          '${_selectedYearIds.length} academic year(s) and '
          '${_selectedCourseIds.length} course(s)?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Send')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _sending = true);
    try {
      final result = await AcademyApiService.sendParentNotification(
        academicYearIds: _selectedYearIds.toList(),
        courseIds:       _selectedCourseIds.toList(),
        message:         message,
      );
      if (!mounted) return;
      setState(() => _sending = false);
      // Reload the Sent-history tab so the new broadcast shows up immediately.
      _sentTabKey.currentState?.refresh();
      await _showSummary(result);
      if (!mounted) return;
      // Clear the message after a successful send; keep filters for convenience.
      _messageCtrl.clear();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _snack(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _snack(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _showSummary(Map<String, dynamic> r) async {
    final total   = (r['total_recipients'] as num?)?.toInt() ?? 0;
    final success = (r['success_count']    as num?)?.toInt() ?? 0;
    final failed  = (r['failed_count']     as num?)?.toInt() ?? 0;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 8),
            Text('Notification Sent'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _summaryRow('Total recipients', '$total', Colors.blue),
            const SizedBox(height: 6),
            _summaryRow('Delivered', '$success', Colors.green),
            if (failed > 0) ...[
              const SizedBox(height: 6),
              _summaryRow('Failed deliveries', '$failed', Colors.orange),
            ],
          ],
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK')),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value, Color color) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value,
              style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        ],
      );

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Send Notifications'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.campaign_outlined), text: 'Send'),
              Tab(icon: Icon(Icons.history),           text: 'Sent'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // ── Send tab ──
            _loading
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null
                    ? _buildError()
                    : _buildForm(theme),
            // ── Sent-history tab ──
            SentNotificationsTab(key: _sentTabKey),
          ],
        ),
      ),
    );
  }

  Widget _buildError() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40, color: Colors.red),
              const SizedBox(height: 12),
              Text(_loadError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );

  Widget _buildForm(ThemeData theme) {
    final remaining = _maxChars - _messageCtrl.text.length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionLabel('Academic Year *', theme),
        const SizedBox(height: 8),
        _buildChips(
          items: _years,
          idOf:  (y) => y['id'].toString(),
          labelOf: _yearName,
          selected: _selectedYearIds,
          emptyText: 'No academic years found.',
        ),
        const SizedBox(height: 20),

        _sectionLabel('Course *', theme),
        const SizedBox(height: 8),
        _buildChips(
          items: _courses,
          idOf:  (c) => c['id'].toString(),
          labelOf: (c) => (c['name'] ?? '').toString(),
          selected: _selectedCourseIds,
          emptyText: 'No active courses found.',
        ),
        const SizedBox(height: 20),

        _sectionLabel('Message *', theme),
        const SizedBox(height: 8),
        TextField(
          controller: _messageCtrl,
          maxLines: 5,
          maxLength: _maxChars,
          decoration: InputDecoration(
            hintText: 'Type your announcement…',
            border: const OutlineInputBorder(),
            counterText: '$remaining characters left',
          ),
        ),
        const SizedBox(height: 24),

        FilledButton.icon(
          onPressed: _sending ? null : _send,
          icon: _sending
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.campaign_outlined),
          label: Text(_sending ? 'Sending…' : 'Send Notification'),
          style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48)),
        ),
      ],
    );
  }

  Widget _sectionLabel(String text, ThemeData theme) => Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
      );

  Widget _buildChips({
    required List<Map<String, dynamic>> items,
    required String Function(Map<String, dynamic>) idOf,
    required String Function(Map<String, dynamic>) labelOf,
    required Set<String> selected,
    required String emptyText,
  }) {
    if (items.isEmpty) {
      return Text(emptyText, style: const TextStyle(color: Colors.grey));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items.map((item) {
        final id = idOf(item);
        final isSel = selected.contains(id);
        return FilterChip(
          label: Text(labelOf(item)),
          selected: isSel,
          onSelected: (v) => setState(() {
            if (v) {
              selected.add(id);
            } else {
              selected.remove(id);
            }
          }),
        );
      }).toList(),
    );
  }
}
