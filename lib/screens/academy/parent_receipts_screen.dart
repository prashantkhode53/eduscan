import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/parent_api_service.dart';
import '../../services/fee_pdf_service.dart';
import '../../providers/parent_auth_provider.dart';
import '../../utils/fee_format.dart';

class ParentReceiptsScreen extends StatefulWidget {
  const ParentReceiptsScreen({super.key});

  @override
  State<ParentReceiptsScreen> createState() => _ParentReceiptsScreenState();
}

class _ParentReceiptsScreenState extends State<ParentReceiptsScreen> {
  List<Map<String, dynamic>> _receipts = [];
  Map<String, dynamic> _summary = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await ParentApiService.getReceipts(limit: 100);
      if (!mounted) return;
      setState(() {
        _receipts = (data['receipts'] as List? ?? []).cast<Map<String, dynamic>>();
        _summary  = data['summary'] as Map<String, dynamic>? ?? {};
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user  = context.watch<ParentAuthProvider>().user;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Fee Receipts', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            if (user != null)
              Text(user.studentFullName,
                  style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh_outlined),
              onPressed: _load,
              tooltip: 'Refresh'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError(theme)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                        16, 16, 16,
                        MediaQuery.of(context).padding.bottom + 24),
                    children: [
                      _buildSummaryCard(theme),
                      const SizedBox(height: 16),
                      if (_receipts.isEmpty)
                        _buildEmpty(theme)
                      else ...[
                        Row(children: [
                          const Icon(Icons.receipt_long_outlined, size: 18),
                          const SizedBox(width: 8),
                          Text('Payment History',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                          const Spacer(),
                          Text('${_receipts.length} receipt${_receipts.length == 1 ? '' : 's'}',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.6))),
                        ]),
                        const SizedBox(height: 10),
                        ..._receipts.map(
                            (r) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _ParentReceiptCard(receipt: r),
                            )),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _buildSummaryCard(ThemeData theme) {
    final totalDue     = double.tryParse(_summary['total_due']?.toString()     ?? '0') ?? 0;
    final totalPaid    = double.tryParse(_summary['total_paid']?.toString()    ?? '0') ?? 0;
    final totalBalance = double.tryParse(_summary['total_balance']?.toString() ?? '0') ?? 0;
    final progress     = totalDue > 0 ? (totalPaid / totalDue).clamp(0.0, 1.0) : 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Fee Summary',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 14),
            Row(
              children: [
                _SummaryTile('Total Fee',     _money(totalDue),     theme.colorScheme.onSurface),
                _divider(),
                _SummaryTile('Paid',          _money(totalPaid),    Colors.green),
                _divider(),
                _SummaryTile('Outstanding',   _money(totalBalance),
                    totalBalance > 0 ? Colors.orange : Colors.green),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                color: totalBalance <= 0 ? Colors.green : theme.colorScheme.primary,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              totalBalance <= 0
                  ? 'All fees cleared'
                  : '${(progress * 100).toStringAsFixed(0)}% paid',
              style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) => Card(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              Icon(Icons.receipt_long_outlined,
                  size: 56,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.25)),
              const SizedBox(height: 14),
              Text('No receipts yet',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(
                'Your fee payment receipts will appear here after payments are recorded.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
              ),
            ],
          ),
        ),
      );

  Widget _buildError(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 56, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
              const SizedBox(height: 20),
              FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry')),
            ],
          ),
        ),
      );

  Widget _divider() => Container(
      width: 1, height: 34, color: Colors.grey.withValues(alpha: 0.25));
}

// ── Individual receipt card ────────────────────────────────────────────────────

class _ParentReceiptCard extends StatefulWidget {
  final Map<String, dynamic> receipt;
  const _ParentReceiptCard({required this.receipt});

  @override
  State<_ParentReceiptCard> createState() => _ParentReceiptCardState();
}

class _ParentReceiptCardState extends State<_ParentReceiptCard> {
  bool _generatingPdf = false;

  Future<void> _downloadPdf() async {
    if (_generatingPdf) return;
    final id = widget.receipt['id'] as String?;
    if (id == null || id.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Receipt not found.'), backgroundColor: Colors.red));
      }
      return;
    }
    setState(() => _generatingPdf = true);
    print('[Receipt] Download Started');
    print('[Receipt] Receipt No: ${widget.receipt['receipt_number'] ?? 'unknown'}');
    try {
      final detail = await ParentApiService.getReceiptById(id);
      if (!mounted) return;
      final user = context.read<ParentAuthProvider>().user;
      await FeePdfService.generateReceiptPdf(
        context: context,
        academyName: user?.academyName ?? 'Academy',
        receipt: detail,
      );
      print('[Receipt] PDF Generated Successfully');
    } catch (e) {
      print('[Receipt] Validation Failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _generatingPdf = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme      = Theme.of(context);
    final r          = widget.receipt;
    final rcptNo     = r['receipt_number'] as String? ?? '—';
    final amountPaid = double.tryParse(r['amount_paid']?.toString() ?? '') ?? 0;
    final amountDue  = double.tryParse(r['amount_due']?.toString()  ?? '') ?? 0;
    final balance    = double.tryParse(r['balance']?.toString() ?? '')
        ?? (amountDue - amountPaid).clamp(0.0, double.infinity);
    final course     = r['course_name'] as String? ?? '';
    final subjectNames = subjectNamesOf(r);
    final mode       = _parseMode(r['payment_mode'] as String?);
    final date       = _fmtDate(r['generated_at']);
    final dueDate    = _fmtDate(r['due_date']);
    final feeStatus  = r['fee_status'] as String? ?? 'paid';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ────────────────────────────────────────────────────
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(rcptNo,
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: theme.colorScheme.primary)),
                ),
                const Spacer(),
                _StatusChip(status: feeStatus),
              ],
            ),
            const SizedBox(height: 12),

            // ── Course / Subject ──────────────────────────────────────────
            if (course.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(children: [
                  Icon(Icons.menu_book_outlined,
                      size: 15,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.55)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      courseWithSubjects(course, subjectNames),
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
              ),

            // ── Key-value rows ─────────────────────────────────────────────
            _kv(theme, Icons.payments_outlined,       'Amount Paid',    '₹${amountPaid.toStringAsFixed(0)}', Colors.green),
            _kv(theme, Icons.account_balance_wallet_outlined, 'Outstanding', '₹${balance.toStringAsFixed(0)}',
                balance > 0 ? Colors.orange : Colors.green),
            _kv(theme, Icons.credit_card_outlined,    'Payment Mode',   mode, null),
            _kv(theme, Icons.calendar_today_outlined, 'Payment Date',   date, null),
            _kv(theme, Icons.event_outlined,          'Due Date',       dueDate, null),
            const SizedBox(height: 12),

            // ── Parent-friendly message ────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: balance <= 0
                    ? Colors.green.withValues(alpha: 0.08)
                    : Colors.orange.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                balance <= 0
                    ? 'All fees cleared for this installment.'
                    : 'Remaining balance: ₹${balance.toStringAsFixed(0)}. Please pay by $dueDate.',
                style: TextStyle(
                    fontSize: 12,
                    color: balance <= 0
                        ? Colors.green.shade700
                        : Colors.orange.shade800),
              ),
            ),
            const SizedBox(height: 12),

            // ── Download ───────────────────────────────────────────────────
            FilledButton.tonalIcon(
              onPressed: _generatingPdf ? null : _downloadPdf,
              icon: _generatingPdf
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_outlined, size: 18),
              label: Text(_generatingPdf ? 'Generating Receipt...' : 'Download Receipt PDF'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(42)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(ThemeData theme, IconData icon, String label, String value, Color? valueColor) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(icon, size: 14,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7))),
          const Spacer(),
          Text(value,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: valueColor ?? theme.colorScheme.onSurface)),
        ]),
      );
}

// ── Small shared widgets ──────────────────────────────────────────────────────

class _SummaryTile extends StatelessWidget {
  final String label, value;
  final Color color;
  const _SummaryTile(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 16, color: color),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6))),
        ]),
      );
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status) {
      case 'paid':    color = Colors.green;  break;
      case 'overdue': color = Colors.red;    break;
      case 'partial': color = Colors.blue;   break;
      default:        color = Colors.orange;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(status.toUpperCase(),
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.bold, color: color)),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _money(double v) => '₹${v.toStringAsFixed(0)}';

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

String _parseMode(String? mode) {
  switch (mode?.toLowerCase()) {
    case 'cash':          return 'Cash';
    case 'upi':           return 'UPI';
    case 'bank_transfer': return 'Bank Transfer';
    case 'cheque':        return 'Cheque';
    default:              return mode?.isNotEmpty == true ? mode! : '—';
  }
}
