import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/academy_api_service.dart';
import '../../services/fee_pdf_service.dart';
import '../../providers/auth_provider.dart';
import 'student_fees_detail_tab.dart';

class FeesScreen extends StatefulWidget {
  const FeesScreen({super.key});

  @override
  State<FeesScreen> createState() => _FeesScreenState();
}

class _FeesScreenState extends State<FeesScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  final List<_Tab> _tabs = const [
    _Tab('All',     null),
    _Tab('Pending', 'pending'),
    _Tab('Overdue', 'overdue'),
    _Tab('Partial', 'partial'),
    _Tab('Paid',    'paid'),
  ];

  List<Map<String, dynamic>> _all      = [];
  Map<String, dynamic>       _summary  = {};
  bool   _loading = true;
  String _month   = _currentMonth();

  static String _currentMonth() =>
      DateTime.now().toIso8601String().substring(0, 7);

  @override
  void initState() {
    super.initState();
    // +2: one for "By Student" tab, one for "Receipts" tab.
    _tabCtrl = TabController(length: _tabs.length + 2, vsync: this);
    _tabCtrl.addListener(() { if (mounted) setState(() {}); });
    _load();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final data = await AcademyApiService.getFees(month: _month, limit: 200);
      if (!mounted) return;
      setState(() {
        _all     = (data['records'] as List).cast<Map<String, dynamic>>();
        _summary = data['summary'] as Map<String, dynamic>? ?? {};
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> _filtered(String? status) => status == null
      ? _all
      : _all.where((r) => r['status'] == status).toList();

  Future<void> _generateFees() async {
    try {
      final result = await AcademyApiService.generateMonthlyFees(month: _month);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result['message']?.toString() ?? 'Fee records generated'),
          backgroundColor: Colors.green,
        ));
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _markOverdue() async {
    try {
      await AcademyApiService.markOverdueFees();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Overdue fees updated'),
          backgroundColor: Colors.orange,
        ));
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _pickMonth() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(int.parse(_month.split('-')[0]),
          int.parse(_month.split('-')[1])),
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 1),
      helpText: 'Select month',
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );
    if (picked != null) {
      setState(() => _month =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}');
      _load();
    }
  }

  // True when the current tab is one of the status-filtered tabs (shows month strip)
  bool get _showMonthStrip => _tabCtrl.index < _tabs.length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fees Management'),
        actions: [
          if (_showMonthStrip)
            IconButton(
              icon: const Icon(Icons.calendar_month_outlined),
              onPressed: _pickMonth,
              tooltip: 'Select month',
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'generate') _generateFees();
              if (v == 'overdue')  _markOverdue();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'generate',
                  child: ListTile(
                      leading: Icon(Icons.add_circle_outline),
                      title: Text('Generate Monthly Fees'),
                      dense: true)),
              const PopupMenuItem(
                  value: 'overdue',
                  child: ListTile(
                      leading: Icon(Icons.warning_amber_outlined,
                          color: Colors.orange),
                      title: Text('Mark Overdue'),
                      dense: true)),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          isScrollable: true,
          tabs: [
            ..._tabs.map((t) => Tab(
                  child: Text(
                    t.status == null
                        ? 'All (${_all.length})'
                        : '${t.label} (${_filtered(t.status).length})',
                  ),
                )),
            const Tab(text: 'By Student'),
            const Tab(text: 'Receipts'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_showMonthStrip)
            Container(
            color: theme.colorScheme.surfaceContainerLow,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(Icons.calendar_today_outlined,
                        size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      _formatMonth(_month),
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary),
                    ),
                    const Spacer(),
                    if (_loading)
                      const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ),
                if (!_loading && _summary.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _SummaryChip(
                          label: 'Collected',
                          value: '₹${_fmt(_summary['total_paid'])}',
                          color: Colors.green),
                      const SizedBox(width: 8),
                      _SummaryChip(
                          label: 'Pending',
                          value: '${_summary['count_pending']}',
                          color: Colors.orange),
                      const SizedBox(width: 8),
                      _SummaryChip(
                          label: 'Overdue',
                          value: '${_summary['count_overdue']}',
                          color: Colors.red),
                    ],
                  ),
                ],
              ],
            ),
          ),

          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                ..._tabs.map((t) => _FeeList(
                      records: _filtered(t.status),
                      loading: _loading,
                      onCollect: (record) async {
                        final ok = await showModalBottomSheet<bool>(
                          context: context,
                          isScrollControlled: true,
                          useSafeArea: true,
                          shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(20))),
                          builder: (_) => FeeCollectionSheet(record: record),
                        );
                        if (ok == true) _load();
                      },
                    )),
                const StudentFeesDetailTab(),
                const _ReceiptsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatMonth(String m) {
    final parts = m.split('-');
    const months = [
      '', 'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${months[int.parse(parts[1])]} ${parts[0]}';
  }

  String _fmt(dynamic v) {
    if (v == null) return '0';
    final d = double.tryParse(v.toString()) ?? 0;
    return d.toStringAsFixed(0);
  }
}

// ── Receipts admin tab ────────────────────────────────────────────────────────

class _ReceiptsTab extends StatefulWidget {
  const _ReceiptsTab();

  @override
  State<_ReceiptsTab> createState() => _ReceiptsTabState();
}

class _ReceiptsTabState extends State<_ReceiptsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<Map<String, dynamic>> _receipts = [];
  bool   _loading = true;
  String? _error;
  final _searchCtrl = TextEditingController();
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await AcademyApiService.listReceipts(limit: 200);
      if (!mounted) return;
      setState(() {
        _receipts = (data['receipts'] as List? ?? []).cast<Map<String, dynamic>>();
        _loading  = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error   = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_q.isEmpty) return _receipts;
    final q = _q.toLowerCase();
    return _receipts.where((r) {
      final num  = (r['receipt_number'] as String? ?? '').toLowerCase();
      final name = '${r['first_name'] ?? ''} ${r['last_name'] ?? ''}'.toLowerCase();
      return num.contains(q) || name.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);

    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry')),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              hintText: 'Search by receipt number or student name',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _q.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () { _searchCtrl.clear(); setState(() => _q = ''); })
                  : null,
              isDense: true,
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerLow,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
          ),
        ),
        Expanded(
          child: _filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.receipt_long_outlined, size: 56,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.25)),
                      const SizedBox(height: 12),
                      Text(_q.isEmpty ? 'No receipts yet' : 'No receipts match "$_q"',
                          style: theme.textTheme.bodyMedium),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                    itemCount: _filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _ReceiptAdminCard(receipt: _filtered[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ReceiptAdminCard extends StatefulWidget {
  final Map<String, dynamic> receipt;
  const _ReceiptAdminCard({required this.receipt});

  @override
  State<_ReceiptAdminCard> createState() => _ReceiptAdminCardState();
}

class _ReceiptAdminCardState extends State<_ReceiptAdminCard> {
  bool _resending = false;
  bool _generatingPdf = false;

  Future<void> _downloadPdf() async {
    if (_generatingPdf) return;
    setState(() => _generatingPdf = true);
    try {
      final detail = await AcademyApiService.getReceipt(widget.receipt['id'] as String);
      if (!mounted) return;
      final academyName =
          context.read<AuthProvider>().academyUser?.academyName ?? 'Academy';
      await FeePdfService.generateReceiptPdf(
          context: context, academyName: academyName, receipt: detail);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _generatingPdf = false);
    }
  }

  Future<void> _resend() async {
    if (_resending) return;
    setState(() => _resending = true);
    try {
      final res = await AcademyApiService.resendReceipt(widget.receipt['id'] as String);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res['message']?.toString() ?? 'Notification sent'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final r      = widget.receipt;
    final name   = '${r['first_name'] ?? ''} ${r['last_name'] ?? ''}'.trim();
    final amount = double.tryParse(r['amount_paid']?.toString() ?? '') ?? 0.0;
    final date   = _fmtDate(r['generated_at']);
    final rcptNo = r['receipt_number'] as String? ?? '—';
    final course = r['course_name'] as String? ?? '';
    final subject = r['subject_name'] as String?;
    final fcmSent = r['fcm_sent'] as bool? ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rcptNo,
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                              fontSize: 13)),
                      const SizedBox(height: 2),
                      Text(name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (course.isNotEmpty)
                        Text(
                          subject != null && subject.isNotEmpty
                              ? '$course · $subject'
                              : course,
                          style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.6)),
                        ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('₹${amount.toStringAsFixed(0)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Colors.green)),
                    Text(date,
                        style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6))),
                    if (fcmSent)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.notifications_active_outlined,
                              size: 12, color: Colors.green),
                          const SizedBox(width: 3),
                          Text('Notified',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.green.shade700)),
                        ],
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _generatingPdf ? null : _downloadPdf,
                    icon: _generatingPdf
                        ? const SizedBox(
                            width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.picture_as_pdf_outlined, size: 16),
                    label: const Text('PDF', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _resending ? null : _resend,
                    icon: _resending
                        ? const SizedBox(
                            width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_outlined, size: 16),
                    label: const Text('Resend', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Fee list ──────────────────────────────────────────────────────────────────

class _FeeList extends StatelessWidget {
  final List<Map<String, dynamic>> records;
  final bool loading;
  final Future<void> Function(Map<String, dynamic>) onCollect;

  const _FeeList(
      {required this.records,
      required this.loading,
      required this.onCollect});

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (records.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.account_balance_wallet_outlined,
                size: 56,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            const Text('No fee records'),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: records.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _FeeCard(
          record: records[i], onCollect: () => onCollect(records[i])),
    );
  }
}

// ── Fee card ──────────────────────────────────────────────────────────────────

class _FeeCard extends StatelessWidget {
  final Map<String, dynamic> record;
  final VoidCallback onCollect;
  const _FeeCard({required this.record, required this.onCollect});

  String _fmtDate(dynamic raw) {
    final s = raw?.toString() ?? '';
    return s.contains('T') ? s.split('T')[0] : s;
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final status  = record['status'] as String;
    final due     = double.tryParse(record['amount_due']?.toString()  ?? '0') ?? 0.0;
    final paid    = double.tryParse(record['amount_paid']?.toString() ?? '0') ?? 0.0;
    final balance = (due - paid).clamp(0.0, double.infinity);
    final isPaid  = status == 'paid';
    final color   = _statusColor(status);
    final rcptNo  = record['receipt_number'] as String?;
    final subject = record['subject_name'] as String?;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${record['first_name']} ${record['last_name']}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        subject != null && subject.isNotEmpty
                            ? '${record['course_name'] ?? ''} · $subject'
                            : record['course_name'] as String? ?? 'Course',
                        style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6)),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (rcptNo != null)
                        Text(rcptNo,
                            style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.primary)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _StatusBadge(status: status, color: color),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: due > 0 ? (paid / due).clamp(0.0, 1.0) : 0,
                color: isPaid ? Colors.green : color,
                backgroundColor: Colors.grey.shade200,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Due: ₹${due.toStringAsFixed(0)}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                if (paid > 0)
                  Text('Paid: ₹${paid.toStringAsFixed(0)}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.green))
                else
                  Text('By ${_fmtDate(record['due_date'])}',
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.55))),
              ],
            ),
            const SizedBox(height: 10),
            if (isPaid)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.check_circle, color: Colors.green, size: 28),
                  SizedBox(width: 6),
                  Text('Paid',
                      style: TextStyle(
                          color: Colors.green, fontWeight: FontWeight.w600)),
                ],
              )
            else
              FilledButton.tonal(
                onPressed: onCollect,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(40)),
                child: Text('Collect  ₹${balance.toStringAsFixed(0)}'),
              ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'paid':     return Colors.green;
      case 'overdue':  return Colors.red;
      case 'partial':  return Colors.blue;
      default:         return Colors.orange;
    }
  }
}

// ── Status badge ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  final Color color;
  const _StatusBadge({required this.status, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          status.toUpperCase(),
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color),
        ),
      );
}

// ── Summary chip ──────────────────────────────────────────────────────────────

class _SummaryChip extends StatelessWidget {
  final String label, value;
  final Color color;
  const _SummaryChip(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: color)),
            const SizedBox(width: 4),
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: color)),
          ],
        ),
      );
}

// ── Fee collection sheet ──────────────────────────────────────────────────────

class FeeCollectionSheet extends StatefulWidget {
  final Map<String, dynamic> record;
  const FeeCollectionSheet({super.key, required this.record});

  @override
  State<FeeCollectionSheet> createState() => _FeeCollectionSheetState();
}

class _FeeCollectionSheetState extends State<FeeCollectionSheet> {
  final _amountCtrl  = TextEditingController();
  final _remarksCtrl = TextEditingController();
  String _paymentMode = 'cash';
  bool _saving = false;

  // After success, store receipt info for download option
  String? _receiptNumber;
  String? _receiptId;

  @override
  void initState() {
    super.initState();
    final due     = double.tryParse(widget.record['amount_due']?.toString()  ?? '0') ?? 0.0;
    final paid    = double.tryParse(widget.record['amount_paid']?.toString() ?? '0') ?? 0.0;
    final balance = (due - paid).clamp(0.0, double.infinity);
    _amountCtrl.text = balance.toStringAsFixed(0);
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _collect() async {
    final amount = double.tryParse(_amountCtrl.text);
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid amount')));
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await AcademyApiService.collectFee(
        feeRecordId:  widget.record['id'] as String,
        amountPaid:   amount,
        paymentMode:  _paymentMode,
        remarks:      _remarksCtrl.text.trim().isNotEmpty
            ? _remarksCtrl.text.trim()
            : null,
      );
      if (mounted) {
        final data = result['data'] as Map<String, dynamic>? ?? result;
        setState(() {
          _receiptNumber = data['receipt_number'] as String?;
          _receiptId     = data['receipt_id'] as String?;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result['message']?.toString() ?? 'Payment recorded'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _downloadReceipt() async {
    if (_receiptId == null) return;
    try {
      final detail = await AcademyApiService.getReceipt(_receiptId!);
      if (!mounted) return;
      final academyName =
          context.read<AuthProvider>().academyUser?.academyName ?? 'Academy';
      await FeePdfService.generateReceiptPdf(
          context: context, academyName: academyName, receipt: detail);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final due     = double.tryParse(widget.record['amount_due']?.toString()  ?? '0') ?? 0.0;
    final paid    = double.tryParse(widget.record['amount_paid']?.toString() ?? '0') ?? 0.0;
    final balance = (due - paid).clamp(0.0, double.infinity);

    final mq = MediaQuery.of(context);

    // ── Success state after payment ───────────────────────────────────────────
    if (_receiptNumber != null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 24),
              const Icon(Icons.check_circle, color: Colors.green, size: 64),
              const SizedBox(height: 16),
              Text('Payment Recorded',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.receipt_long_outlined,
                        color: theme.colorScheme.primary, size: 18),
                    const SizedBox(width: 8),
                    Text(_receiptNumber!,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: theme.colorScheme.primary)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (((widget.record['course_name'] as String?)?.isNotEmpty ?? false) ||
                  ((widget.record['subject_name'] as String?)?.isNotEmpty ?? false))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    [
                      if ((widget.record['course_name'] as String?)?.isNotEmpty ?? false)
                        widget.record['course_name'] as String,
                      if ((widget.record['subject_name'] as String?)?.isNotEmpty ?? false)
                        widget.record['subject_name'] as String,
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              Text('A notification has been sent to the parent.',
                  style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _downloadReceipt,
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('Download Receipt'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // ── Input form ────────────────────────────────────────────────────────────
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24,
          mq.viewInsets.bottom + mq.padding.bottom + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),

          Text('Collect Fee',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _FeeInfoRow(
                  icon: Icons.person_outline,
                  label: 'Student',
                  value: '${widget.record['first_name'] ?? ''} ${widget.record['last_name'] ?? ''}'.trim(),
                ),
                if ((widget.record['course_name'] as String?)?.isNotEmpty ?? false) ...[
                  const SizedBox(height: 6),
                  _FeeInfoRow(
                    icon: Icons.menu_book_outlined,
                    label: 'Course',
                    value: widget.record['course_name'] as String,
                  ),
                ],
                if ((widget.record['subject_name'] as String?)?.isNotEmpty ?? false) ...[
                  const SizedBox(height: 6),
                  _FeeInfoRow(
                    icon: Icons.science_outlined,
                    label: 'Subject',
                    value: widget.record['subject_name'] as String,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Balance summary
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _BalanceTile('Total Due', '₹${due.toStringAsFixed(0)}'),
                _BalanceTile('Paid',      '₹${paid.toStringAsFixed(0)}', color: Colors.green),
                _BalanceTile('Balance',   '₹${balance.toStringAsFixed(0)}', color: Colors.orange),
              ],
            ),
          ),
          const SizedBox(height: 16),

          TextFormField(
            controller: _amountCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Amount to Collect (₹)',
              prefixText: '₹ ',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),

          DropdownButtonFormField<String>(
            value: _paymentMode,
            decoration: const InputDecoration(
                labelText: 'Payment Mode', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'cash',          child: Text('Cash')),
              DropdownMenuItem(value: 'upi',           child: Text('UPI')),
              DropdownMenuItem(value: 'bank_transfer', child: Text('Bank Transfer')),
              DropdownMenuItem(value: 'cheque',        child: Text('Cheque')),
            ],
            onChanged: (v) => setState(() => _paymentMode = v!),
          ),
          const SizedBox(height: 12),

          TextFormField(
            controller: _remarksCtrl,
            decoration: const InputDecoration(
                labelText: 'Remarks (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),

          FilledButton.icon(
            onPressed: _saving ? null : _collect,
            icon: _saving
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.check),
            label: const Text('Confirm Payment'),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50)),
          ),
        ],
      ),
    );
  }
}

class _BalanceTile extends StatelessWidget {
  final String label, value;
  final Color? color;
  const _BalanceTile(this.label, this.value, {this.color});

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: color)),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6))),
        ],
      );
}

class _Tab {
  final String label;
  final String? status;
  const _Tab(this.label, this.status);
}

// ── Shared helpers ────────────────────────────────────────────────────────────

class _FeeInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _FeeInfoRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 15, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

String _fmtDate(dynamic raw) {
  final s = raw?.toString() ?? '';
  final clean = s.contains('T') ? s.split('T')[0] : s;
  if (clean.isEmpty) return '—';
  try {
    final d = DateTime.parse(clean);
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month]} ${d.year}';
  } catch (_) {
    return clean;
  }
}

