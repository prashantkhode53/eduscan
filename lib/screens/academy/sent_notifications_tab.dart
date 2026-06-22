import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';
import '../../services/notification_excel_service.dart';
import '../../utils/date_utils.dart' as du;

/// Admin → Send Notifications → "Sent" tab.
/// Shows only the LATEST 10 broadcasts in-app to keep the list light, and
/// offers an Excel download of the FULL history for when there are more.
/// Each row shows the message, when it was sent + by whom, and a delivery
/// breakdown (recipients / delivered / failed) with a status chip.
///
/// Exposes a [refresh] via the GlobalKey<SentNotificationsTabState> so the
/// Send tab can reload this list after a successful broadcast.
class SentNotificationsTab extends StatefulWidget {
  const SentNotificationsTab({super.key});

  @override
  State<SentNotificationsTab> createState() => SentNotificationsTabState();
}

class SentNotificationsTabState extends State<SentNotificationsTab>
    with AutomaticKeepAliveClientMixin {
  // Cap the in-app list to the latest few so a large history never loads a
  // heavy list into memory; the full set is available via Excel download.
  static const int _previewLimit = 10;

  final List<Map<String, dynamic>> _items = [];

  bool _loading     = true;   // first load
  bool _downloading = false;
  String? _error;

  // Keep the list alive while the user is on the Send tab so switching back
  // doesn't trigger a full reload.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Public entry point — reload. Called by the parent after a send.
  Future<void> refresh() => _load();

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.getSentNotifications(
          page: 1, limit: _previewLimit);
      if (!mounted) return;
      final list = (data['notifications'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error   = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _downloadExcel() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final rows = await AcademyApiService.getAllSentNotifications();
      if (rows.isEmpty) {
        if (mounted) {
          messenger.showSnackBar(const SnackBar(
            content: Text('No notifications to export yet.'),
          ));
        }
        return;
      }
      final path = await NotificationExcelService.generate(rows);
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text('Exported ${rows.length} notification(s) • '
              '${path.split(RegExp(r'[\\/]')).last}'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text('Export failed: '
              '${e.toString().replaceFirst('Exception: ', '')}'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // for AutomaticKeepAliveClientMixin
    return Column(
      children: [
        _downloadBar(),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: _buildBody(),
          ),
        ),
      ],
    );
  }

  Widget _downloadBar() {
    // Stacked (text over a full-width button) rather than a side-by-side Row:
    // on narrow phones a Row pits the long helper text against the wide button
    // for horizontal space, starving the text to ~zero width and wrapping it
    // one character per line. A Column gives each its own full-width line.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Showing the latest $_previewLimit. '
            'Download for the full history.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: _downloading ? null : _downloadExcel,
            icon: _downloading
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined, size: 18),
            label: Text(_downloading ? 'Exporting…' : 'Download Excel'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 100),
          const Icon(Icons.error_outline, size: 40, color: Colors.red),
          const SizedBox(height: 12),
          Center(child: Text(_error!, textAlign: TextAlign.center)),
          const SizedBox(height: 16),
          Center(
            child: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ),
        ],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Icon(Icons.campaign_outlined, size: 48, color: Colors.grey),
          SizedBox(height: 12),
          Center(child: Text('No notifications sent yet.',
              style: TextStyle(color: Colors.grey))),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) => _tile(_items[index]),
    );
  }

  Widget _tile(Map<String, dynamic> item) {
    final message = item['message']?.toString() ?? '';
    final created = item['created_at']?.toString();
    final sentBy  = item['sent_by_name']?.toString();
    final total   = (item['recipient_count'] as num?)?.toInt() ?? 0;
    final ok      = (item['success_count']   as num?)?.toInt() ?? 0;
    final failed  = (item['failed_count']    as num?)?.toInt() ?? 0;
    final status  = (item['status'] ?? 'sent').toString();

    return ListTile(
      isThreeLine: true,
      leading: const CircleAvatar(
        child: Icon(Icons.campaign_outlined),
      ),
      title: Text(
        message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              du.fmtDateTime(created) +
                  (sentBy != null && sentBy.isNotEmpty ? '  •  $sentBy' : ''),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _statusChip(status),
                _countChip(Icons.people_outline, '$total', Colors.blue),
                _countChip(Icons.check_circle_outline, '$ok', Colors.green),
                if (failed > 0)
                  _countChip(Icons.error_outline, '$failed', Colors.orange),
              ],
            ),
          ],
        ),
      ),
      onTap: () => _showDetail(item),
    );
  }

  Widget _statusChip(String status) {
    final (Color color, String label) = switch (status) {
      'sent'    => (Colors.green,  'Sent'),
      'partial' => (Colors.orange, 'Partial'),
      'failed'  => (Colors.red,    'Failed'),
      _         => (Colors.grey,   status),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }

  Widget _countChip(IconData icon, String value, Color color) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 2),
          Text(value,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      );

  Future<void> _showDetail(Map<String, dynamic> item) async {
    final message = item['message']?.toString() ?? '';
    final created = item['created_at']?.toString();
    final sentBy  = item['sent_by_name']?.toString();
    final total   = (item['recipient_count'] as num?)?.toInt() ?? 0;
    final ok      = (item['success_count']   as num?)?.toInt() ?? 0;
    final failed  = (item['failed_count']    as num?)?.toInt() ?? 0;

    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(du.fmtDateTime(created)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const Divider(height: 24),
              if (sentBy != null && sentBy.isNotEmpty) ...[
                _detailRow('Sent by', sentBy),
                const SizedBox(height: 6),
              ],
              _detailRow('Recipients', '$total'),
              const SizedBox(height: 6),
              _detailRow('Delivered', '$ok'),
              if (failed > 0) ...[
                const SizedBox(height: 6),
                _detailRow('Failed', '$failed'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      );
}
