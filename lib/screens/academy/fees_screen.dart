import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../services/academy_api_service.dart';
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

  // Shared data — all tabs use the same monthly load
  List<Map<String, dynamic>> _all      = [];
  Map<String, dynamic>       _summary  = {};
  bool   _loading = true;
  String _month   = _currentMonth();

  static String _currentMonth() =>
      DateTime.now().toIso8601String().substring(0, 7);

  @override
  void initState() {
    super.initState();
    // +1 for the "By Student" tab appended after the status tabs.
    _tabCtrl = TabController(length: _tabs.length + 1, vsync: this);
    // Rebuild on tab change so the month strip can be hidden on the By Student tab.
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
      final data = await AcademyApiService.getFees(
          month: _month, limit: 200);
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
          content: Text(result['message']?.toString() ??
              'Fee records generated'),
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
    // Simple month picker using date picker, then extract YYYY-MM
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fees Management'),
        actions: [
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
          ],
        ),
      ),
      body: Column(
        children: [
          // Month header + summary strip (hidden on the By Student tab,
          // which is not scoped to a single month).
          if (_tabCtrl.index < _tabs.length)
            Container(
            color: theme.colorScheme.surfaceContainerLow,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(Icons.calendar_today_outlined,
                        size: 16,
                        color: theme.colorScheme.primary),
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
                          width: 16,
                          height: 16,
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

          // Tab views
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatMonth(String m) {
    final parts = m.split('-');
    final months = [
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
    // Strip ISO timestamp → keep only YYYY-MM-DD
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header: name + status badge ───────────────────────────────
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
                        record['course_name'] as String? ?? 'Course',
                        style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6)),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _StatusBadge(status: status, color: color),
              ],
            ),
            const SizedBox(height: 10),

            // ── Progress bar ───────────────────────────────────────────────
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

            // ── Amount row (no button here — button below) ─────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Due: ₹${due.toStringAsFixed(0)}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (paid > 0)
                  Text(
                    'Paid: ₹${paid.toStringAsFixed(0)}',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.green),
                  )
                else
                  Text(
                    'By ${_fmtDate(record['due_date'])}',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.55)),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // ── Action ─────────────────────────────────────────────────────
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
            Text(label,
                style: TextStyle(fontSize: 11, color: color)),
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

  Map<String, dynamic>? _activeQr;
  bool _showQr = false;

  @override
  void initState() {
    super.initState();
    final due   = double.tryParse(widget.record['amount_due']?.toString()  ?? '0') ?? 0.0;
    final paid  = double.tryParse(widget.record['amount_paid']?.toString() ?? '0') ?? 0.0;
    final balance = (due - paid).clamp(0.0, double.infinity);
    _amountCtrl.text = balance.toStringAsFixed(0);
    _loadActiveQr();
  }

  Future<void> _loadActiveQr() async {
    try {
      final qr = await AcademyApiService.getActiveQrCode();
      if (mounted && qr != null) setState(() => _activeQr = qr);
    } catch (_) {}
  }

  Uint8List? _qrBytes() {
    final data = _activeQr?['image_data'] as String? ?? '';
    if (data.isEmpty) return null;
    try {
      final b64 = data.contains(',') ? data.split(',').last : data;
      return base64Decode(b64);
    } catch (_) { return null; }
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result['message']?.toString() ?? 'Payment recorded'),
          backgroundColor: Colors.green,
        ));
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme   = Theme.of(context);
    final due     = double.tryParse(widget.record['amount_due']?.toString()  ?? '0') ?? 0.0;
    final paid    = double.tryParse(widget.record['amount_paid']?.toString() ?? '0') ?? 0.0;
    final balance = (due - paid).clamp(0.0, double.infinity);

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          const SizedBox(height: 16),

          Text('Collect Fee',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            '${widget.record['first_name']} ${widget.record['last_name']}  ·  '
            '${widget.record['course_name'] ?? ''}',
            style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
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

          // Amount
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

          // Payment mode
          DropdownButtonFormField<String>(
            value: _paymentMode,
            decoration: const InputDecoration(
                labelText: 'Payment Mode', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'cash',         child: Text('Cash')),
              DropdownMenuItem(value: 'upi',          child: Text('UPI')),
              DropdownMenuItem(value: 'bank_transfer',child: Text('Bank Transfer')),
              DropdownMenuItem(value: 'cheque',       child: Text('Cheque')),
            ],
            onChanged: (v) => setState(() => _paymentMode = v!),
          ),
          const SizedBox(height: 12),

          // Remarks
          TextFormField(
            controller: _remarksCtrl,
            decoration: const InputDecoration(
                labelText: 'Remarks (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),

          // Active QR code (shown when available)
          if (_activeQr != null) ...[
            InkWell(
              onTap: () => setState(() => _showQr = !_showQr),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                ),
                child: Row(children: [
                  Icon(Icons.qr_code_2, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_activeQr!['name'] as String? ?? 'Pay via QR',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Icon(_showQr ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down),
                ]),
              ),
            ),
            if (_showQr) ...[
              const SizedBox(height: 10),
              Builder(builder: (_) {
                final bytes = _qrBytes();
                return bytes != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(bytes, height: 200, fit: BoxFit.contain))
                    : const SizedBox.shrink();
              }),
              if ((_activeQr!['description'] as String?)?.isNotEmpty ?? false)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _activeQr!['description'] as String,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
                  ),
                ),
            ],
            const SizedBox(height: 12),
          ],

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
