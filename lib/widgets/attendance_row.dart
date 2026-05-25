import 'package:flutter/material.dart';
import '../models/attendance.dart';

class AttendanceRow extends StatelessWidget {
  final Attendance record;
  final VoidCallback? onTap;

  const AttendanceRow({super.key, required this.record, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color statusColor;
    switch (record.status) {
      case 'present':
        statusColor = Colors.green;
      case 'late':
        statusColor = Colors.orange;
      default:
        statusColor = Colors.red;
    }

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 3,
              child: Text(
                record.studentFullName.isNotEmpty
                    ? record.studentFullName
                    : record.studentId,
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                record.date,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: Text(
                record.timeIn ?? '-',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: Text(
                record.timeOut ?? '-',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha:0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                record.status.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: statusColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
