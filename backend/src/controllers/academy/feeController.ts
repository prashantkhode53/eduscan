import { Request, Response, NextFunction } from 'express';
import { academyQuery, academyQueryOne, academyTransaction, academyExec } from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';

// ── GET /api/academy/fees ─────────────────────────────────────────────────────

export async function listFees(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const {
      status, student_id, course_id, month,
      page = '1', limit = '50',
    } = req.query as Record<string, string>;

    const offset = (parseInt(page) - 1) * parseInt(limit);

    const rows = await academyQuery(
      academySlug,
      `SELECT fr.*,
              s.first_name, s.last_name, s.mobile,
              c.name AS course_name,
              (fr.amount_due - fr.amount_paid) AS balance
       FROM fee_records fr
       JOIN students s ON s.id = fr.student_id
       LEFT JOIN courses c ON c.id = fr.course_id
       WHERE ($1::text IS NULL OR fr.status = $1)
         AND ($2::text IS NULL OR fr.student_id = $2)
         AND ($3::uuid IS NULL OR fr.course_id = $3::uuid)
         AND ($4::text IS NULL OR TO_CHAR(fr.due_date,'YYYY-MM') = $4)
       ORDER BY
         CASE fr.status
           WHEN 'overdue'  THEN 1
           WHEN 'pending'  THEN 2
           WHEN 'partial'  THEN 3
           ELSE 4
         END,
         fr.due_date ASC
       LIMIT $5 OFFSET $6`,
      [
        status  || null,
        student_id || null,
        course_id  || null,
        month      || null,
        parseInt(limit),
        offset,
      ]
    );

    // Summary totals
    const summary = await academyQueryOne<{
      total_due: string; total_paid: string;
      count_pending: string; count_overdue: string; count_paid: string;
    }>(
      academySlug,
      `SELECT
         COALESCE(SUM(amount_due),  0) AS total_due,
         COALESCE(SUM(amount_paid), 0) AS total_paid,
         COUNT(*) FILTER (WHERE status='pending')  AS count_pending,
         COUNT(*) FILTER (WHERE status='overdue')  AS count_overdue,
         COUNT(*) FILTER (WHERE status='paid')     AS count_paid
       FROM fee_records
       WHERE ($1::text IS NULL OR TO_CHAR(due_date,'YYYY-MM') = $1)`,
      [month || null]
    );

    res.json({
      success: true,
      data: {
        records: rows,
        summary: {
          total_due:     parseFloat(summary?.total_due     ?? '0'),
          total_paid:    parseFloat(summary?.total_paid    ?? '0'),
          count_pending: parseInt(summary?.count_pending   ?? '0'),
          count_overdue: parseInt(summary?.count_overdue   ?? '0'),
          count_paid:    parseInt(summary?.count_paid      ?? '0'),
        },
        page: parseInt(page),
        limit: parseInt(limit),
      },
    });
  } catch (err) { next(err); }
}

// ── POST /api/academy/fees/collect ────────────────────────────────────────────

export async function collectFee(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug, userId } = req.academyUser!;
    const { fee_record_id, amount_paid, payment_mode = 'cash', remarks } =
      req.body as {
        fee_record_id: string;
        amount_paid: number;
        payment_mode?: string;
        remarks?: string;
      };

    if (!fee_record_id || !amount_paid || amount_paid <= 0) {
      return next(new AppError('fee_record_id and amount_paid > 0 are required', 400));
    }

    const record = await academyQueryOne<{
      id: string; amount_due: number; amount_paid: number; status: string;
    }>(
      academySlug,
      `SELECT id, amount_due, amount_paid, status FROM fee_records WHERE id = $1`,
      [fee_record_id]
    );
    if (!record) return next(new AppError('Fee record not found', 404));
    if (record.status === 'paid') return next(new AppError('Fee already fully paid', 409));

    const newPaid = parseFloat(record.amount_paid.toString()) + amount_paid;
    const balance = parseFloat(record.amount_due.toString()) - newPaid;
    const newStatus = balance <= 0 ? 'paid' : newPaid > 0 ? 'partial' : record.status;
    const paidDate = newStatus === 'paid' ? new Date().toISOString().split('T')[0] : null;

    const remarksFull = [
      payment_mode ? `Mode: ${payment_mode}` : null,
      remarks || null,
    ].filter(Boolean).join(' | ');

    const updated = await academyQueryOne(
      academySlug,
      `UPDATE fee_records
       SET amount_paid   = $1,
           status        = $2,
           paid_date     = $3,
           remarks       = $4,
           collected_by  = $5,
           updated_at    = NOW()
       WHERE id = $6
       RETURNING *`,
      [newPaid, newStatus, paidDate, remarksFull || null, userId, fee_record_id]
    );

    res.json({
      success: true,
      data: updated,
      message: newStatus === 'paid'
        ? 'Fee fully paid'
        : `₹${amount_paid} collected — ₹${Math.max(0, balance).toFixed(2)} remaining`,
    });
  } catch (err) { next(err); }
}

// ── POST /api/academy/fees/generate ──────────────────────────────────────────
// Generates monthly fee records for all active enrollments.
// Safe to call multiple times — uses ON CONFLICT DO NOTHING.

export async function generateMonthlyFees(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { month } = req.body as { month?: string }; // YYYY-MM, defaults to current month

    const targetMonth = month ?? new Date().toISOString().substring(0, 7);
    const [year, mon] = targetMonth.split('-').map(Number);
    const dueDate = new Date(year, mon, 0).toISOString().split('T')[0]; // last day of month

    const { rowCount } = await academyExec(
      academySlug,
      `INSERT INTO fee_records (student_id, course_id, amount_due, due_date, status)
       SELECT sc.student_id, sc.course_id, sc.fee_amount,
              $1::date, 'pending'
       FROM student_courses sc
       WHERE sc.status = 'active'
         AND NOT EXISTS (
           SELECT 1 FROM fee_records fr
           WHERE fr.student_id = sc.student_id
             AND fr.course_id  = sc.course_id
             AND TO_CHAR(fr.due_date,'YYYY-MM') = $2
         )`,
      [dueDate, targetMonth]
    );

    res.json({
      success: true,
      data: { generated: rowCount, month: targetMonth },
      message: `${rowCount} fee records generated for ${targetMonth}`,
    });
  } catch (err) { next(err); }
}

// ── POST /api/academy/fees/mark-overdue ──────────────────────────────────────
// Marks all pending/partial fees past due_date as overdue.

export async function markOverdueFees(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { rowCount } = await academyExec(
      academySlug,
      `UPDATE fee_records
       SET status = 'overdue', updated_at = NOW()
       WHERE status IN ('pending','partial')
         AND due_date < CURRENT_DATE`
    );
    res.json({
      success: true,
      data: { updated: rowCount },
      message: `${rowCount} fee records marked overdue`,
    });
  } catch (err) { next(err); }
}

// ── GET /api/academy/fees/student/:studentId ──────────────────────────────────

export async function getStudentFees(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { studentId } = req.params;

    const records = await academyQuery(
      academySlug,
      `SELECT fr.*, c.name AS course_name,
              (fr.amount_due - fr.amount_paid) AS balance
       FROM fee_records fr
       LEFT JOIN courses c ON c.id = fr.course_id
       WHERE fr.student_id = $1
       ORDER BY fr.due_date DESC`,
      [studentId]
    );

    const totals = await academyQueryOne<{
      total_due: string; total_paid: string; total_balance: string;
    }>(
      academySlug,
      `SELECT COALESCE(SUM(amount_due),0)               AS total_due,
              COALESCE(SUM(amount_paid),0)              AS total_paid,
              COALESCE(SUM(amount_due - amount_paid),0) AS total_balance
       FROM fee_records WHERE student_id = $1`,
      [studentId]
    );

    res.json({
      success: true,
      data: {
        records: records,
        totals: {
          total_due:     parseFloat(totals?.total_due     ?? '0'),
          total_paid:    parseFloat(totals?.total_paid    ?? '0'),
          total_balance: parseFloat(totals?.total_balance ?? '0'),
        },
      },
    });
  } catch (err) { next(err); }
}
