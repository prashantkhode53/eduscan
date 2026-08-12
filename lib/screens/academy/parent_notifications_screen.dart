import 'package:flutter/material.dart';
import '../../services/parent_api_service.dart';
import '../../utils/date_utils.dart' as du;

/// Parent → Notifications. Full inbox of broadcasts received by this parent.
/// Newest-first, unread highlighted, tap-to-read, pull-to-refresh, paginated.
class ParentNotificationsScreen extends StatefulWidget {
  const ParentNotificationsScreen({super.key});

  @override
  State<ParentNotificationsScreen> createState() =>
      _ParentNotificationsScreenState();
}

class _ParentNotificationsScreenState extends State<ParentNotificationsScreen> {
  static const int _pageSize = 20;

  final List<Map<String, dynamic>> _items = [];
  final _scrollCtrl = ScrollController();

  int  _page        = 1;
  bool _loading     = true;   // first load
  bool _loadingMore = false;
  bool _hasMore     = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _loadFirst();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >=
            _scrollCtrl.position.maxScrollExtent - 200 &&
        !_loadingMore &&
        _hasMore) {
      _loadMore();
    }
  }

  Future<void> _loadFirst() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await ParentApiService.getNotifications(
          page: 1, limit: _pageSize);
      if (!mounted) return;
      final list = (data['notifications'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _page    = 1;
        _hasMore = list.length == _pageSize;
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

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final data = await ParentApiService.getNotifications(
          page: next, limit: _pageSize);
      if (!mounted) return;
      final list = (data['notifications'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      setState(() {
        _items.addAll(list);
        _page    = next;
        _hasMore = list.length == _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _open(int index) async {
    final item = _items[index];
    final id = item['id']?.toString();
    final wasUnread = item['is_read'] != true;

    // Optimistically mark read in the UI.
    if (wasUnread) {
      setState(() => _items[index] = {...item, 'is_read': true});
      if (id != null) {
        ParentApiService.markNotificationRead(id).catchError((_) {
          // Revert on failure so state stays truthful.
          if (mounted) setState(() => _items[index] = {...item, 'is_read': false});
        });
      }
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(du.fmtDate(item['created_at']?.toString())),
        content: SingleChildScrollView(
          child: Text(item['message']?.toString() ?? ''),
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
    return Scaffold(
      // Return true on pop so the dashboard refreshes its unread badge.
      appBar: AppBar(
        title: const Text('Notifications'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context, true),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _loadFirst,
        child: _buildBody(),
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
          const SizedBox(height: 120),
          const Icon(Icons.error_outline, size: 40, color: Colors.red),
          const SizedBox(height: 12),
          Center(child: Text(_error!, textAlign: TextAlign.center)),
          const SizedBox(height: 16),
          Center(
            child: FilledButton.icon(
              onPressed: _loadFirst,
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
          SizedBox(height: 140),
          Icon(Icons.notifications_none, size: 48, color: Colors.grey),
          SizedBox(height: 12),
          Center(child: Text('No notifications yet.',
              style: TextStyle(color: Colors.grey))),
        ],
      );
    }

    return ListView.separated(
      controller: _scrollCtrl,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _items.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index >= _items.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return _tile(index);
      },
    );
  }

  Widget _tile(int index) {
    final item   = _items[index];
    final unread = item['is_read'] != true;
    final message = item['message']?.toString() ?? '';
    final created = item['created_at']?.toString();
    final theme = Theme.of(context);

    return Container(
      color: unread
          ? theme.colorScheme.primary.withValues(alpha: 0.06)
          : null,
      child: ListTile(
        leading: Icon(
          unread ? Icons.notifications_active : Icons.notifications_none,
          color: unread ? theme.colorScheme.primary : Colors.grey,
        ),
        title: Text(
          message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: unread ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${du.fmtDate(created)}  •  ${du.fmtClock(created)}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        trailing: unread
            ? Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              )
            : null,
        onTap: () => _open(index),
      ),
    );
  }
}
