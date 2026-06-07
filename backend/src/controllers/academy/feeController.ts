import { Request, Response, NextFunction } from 'express';
import { academyQuery, academyQueryOne, academyExec, academyTransaction } from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';
import { sendFcm } from '../../utils/fcm';

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
              c.name  AS course_name,
              sub.name AS subject_name,
              GREATEST(0, fr.amount_due - fr.amount_paid) AS balance,
              rcpt.receipt_number
       FROM fee_records fr
       JOIN students s    ON s.id   = fr.student_id
       LEFT JOIN courses c ON c.id  = fr.course_id
       LEFT JOIN subjects sub ON sub.id = fr.subject_id
       LEFT JOIN fee_receipts rcpt ON rcpt.fee_record_id = fr.id
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

    type _FeeRecord = {
      id: string; student_id: string; course_id: string | null;
      subject_id: string | null; amount_due: number; amount_paid: number;
      status: string; paid_date: string | null; due_date: string; remarks: string | null;
    };

    const txResult = {
      updated: null as _FeeRecord | null,
      receiptNumber: '',
      receiptId: '',
    };

    // ── Atomic: update fee record + generate receipt in one transaction ───
    await academyTransaction(academySlug, async (client) => {
      const { rows: uRows } = await client.query<_FeeRecord>(
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
      txResult.updated = uRows[0] ?? null;
      if (!txResult.updated) throw new Error('Fee record not found during update');

      const year = new Date().getFullYear();
      const { rows: seqRows } = await client.query<{ n: string }>(`SELECT nextval('fee_receipt_seq') AS n`);
      txResult.receiptNumber = `RCP-${year}-${String(seqRows[0].n).padStart(6, '0')}`;

      const { rows: rcptRows } = await client.query<{ id: string }>(
        `INSERT INTO fee_receipts
           (receipt_number, fee_record_id, student_id, amount_paid, payment_mode, generated_by)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id`,
        [txResult.receiptNumber, fee_record_id, txResult.updated.student_id, amount_paid, payment_mode, userId]
      );
      txResult.receiptId = rcptRows[0].id;
    });

    const updated = txResult.updated;
    const { receiptNumber, receiptId } = txResult;
    if (!updated) return next(new AppError('Fee record update failed unexpectedly', 500));

    // ── Push notification to parent (fire-and-forget) ─────────────────────
    const student = await academyQueryOne<{
      first_name: string; last_name: string; parent_name: string | null;
      parent_fcm_token: string | null;
      course_name: string | null; subject_name: string | null;
    }>(
      academySlug,
      `SELECT s.first_name, s.last_name, s.parent_name, s.parent_fcm_token,
              c.name   AS course_name,
              sub.name AS subject_name
       FROM students s
       LEFT JOIN courses  c   ON c.id   = $2::uuid
       LEFT JOIN subjects sub ON sub.id = $3::uuid
       WHERE s.id = $1`,
      [updated.student_id, updated.course_id, updated.subject_id]
    );

    if (student?.parent_fcm_token) {
      const balanceLine = balance <= 0
        ? 'All fees are now cleared.'
        : `Remaining balance: ₹${Math.max(0, balance).toFixed(0)}`;
      const subjectLine = [student.course_name, student.subject_name].filter(Boolean).join(' › ');
      const sent = await sendFcm({
        token: student.parent_fcm_token,
        title: 'Fee Payment Received',
        body:
          `Dear ${student.parent_name ?? 'Parent'}, ₹${amount_paid} received for ` +
          `${student.first_name} ${student.last_name}` +
          (subjectLine ? ` (${subjectLine})` : '') +
          `. ${balanceLine} Receipt No: ${receiptNumber}.`,
        data: {
          type:           'fee_receipt',
          receipt_id:     receiptId,
          receipt_number: receiptNumber,
        },
      });
      if (sent) {
        void academyExec(
          academySlug,
          `UPDATE fee_receipts SET fcm_sent = TRUE WHERE id = $1`,
          [receiptId]
        );
      }
    }

    res.json({
      success: true,
      data: {
        ...updated,
        receipt_number: receiptNumber,
        receipt_id: receiptId,
      },
      message: newStatus === 'paid'
        ? `Fee fully paid · Receipt ${receiptNumber}`
        : `₹${amount_paid} collected · ₹${Math.max(0, balance).toFixed(0)} remaining · Receipt ${receiptNumber}`,
    });
  } catch (err) { next(err); }
}

// ── POST /api/academy/fees/generate ──────────────────────────────────────────

export async function generateMonthlyFees(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { month } = req.body as { month?: string };

    const targetMonth = month ?? new Date().toISOString().substring(0, 7);
    const [year, mon] = targetMonth.split('-').map(Number);
    const dueDate = new Date(year, mon, 0).toISOString().split('T')[0];

    const { rowCount: subjectRows } = await academyExec(
      academySlug,
      `INSERT INTO fee_records (student_id, subject_id, course_id, amount_due, due_date, status)
       SELECT ss.student_id, ss.subject_id, sub.course_id, ss.fee_amount,
              $1::date, 'pending'
       FROM student_subjects ss
       JOIN subjects sub ON sub.id = ss.subject_id
       WHERE ss.status = 'active'
         AND NOT EXISTS (
           SELECT 1 FROM fee_records fr
           WHERE fr.student_id = ss.student_id
             AND fr.subject_id = ss.subject_id
             AND TO_CHAR(fr.due_date,'YYYY-MM') = $2
         )`,
      [dueDate, targetMonth]
    );

    const { rowCount: courseRows } = await academyExec(
      academySlug,
      `INSERT INTO fee_records (student_id, course_id, amount_due, due_date, status)
       SELECT sc.student_id, sc.course_id, sc.fee_amount,
              $1::date, 'pending'
       FROM student_courses sc
       WHERE sc.status = 'active'
         AND NOT EXISTS (SELECT 1 FROM student_subjects ss WHERE ss.student_id = sc.student_id AND ss.status = 'active')
         AND NOT EXISTS (
           SELECT 1 FROM fee_records fr
           WHERE fr.student_id = sc.student_id
             AND fr.course_id  = sc.course_id
             AND fr.subject_id IS NULL
             AND TO_CHAR(fr.due_date,'YYYY-MM') = $2
         )`,
      [dueDate, targetMonth]
    );

    const total = (subjectRows ?? 0) + (courseRows ?? 0);
    res.json({
      success: true,
      data: { generated: total, month: targetMonth },
      message: `${total} fee records generated for ${targetMonth}`,
    });
  } catch (err) { next(err); }
}

// ── POST /api/academy/fees/mark-overdue ──────────────────────────────────────

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
      `SELECT fr.*,
              c.name   AS course_name,
              sub.name AS subject_name,
              GREATEST(0, fr.amount_due - fr.amount_paid) AS balance,
              rcpt.receipt_number,
              rcpt.id AS receipt_id
       FROM fee_records fr
       LEFT JOIN courses c      ON c.id   = fr.course_id
       LEFT JOIN subjects sub   ON sub.id = fr.subject_id
       LEFT JOIN fee_receipts rcpt ON rcpt.fee_record_id = fr.id
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
              COALESCE(SUM(GREATEST(0, amount_due - amount_paid)),0) AS total_balance
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

// ── GET /api/academy/fees/receipts ───────────────────────────────────────────

export async function listReceipts(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const {
      student_id, from, to, q,
      page = '1', limit = '50',
    } = req.query as Record<string, string>;

    const offset = (parseInt(page) - 1) * parseInt(limit);

    const rows = await academyQuery(
      academySlug,
      `SELECT
         r.id, r.receipt_number, r.amount_paid, r.payment_mode,
         r.generated_at, r.fcm_sent,
         s.id AS student_id, s.first_name, s.last_name, s.mobile,
         c.name  AS course_name,
         sub.name AS subject_name,
         fr.amount_due, fr.amount_paid AS fr_amount_paid,
         fr.status AS fee_status, fr.due_date
       FROM fee_receipts r
       JOIN students s        ON s.id   = r.student_id
       LEFT JOIN fee_records fr ON fr.id = r.fee_record_id
       LEFT JOIN courses c    ON c.id   = fr.course_id
       LEFT JOIN subjects sub ON sub.id = fr.subject_id
       WHERE ($1::text IS NULL OR r.student_id = $1)
         AND ($2::date IS NULL OR r.generated_at::date >= $2::date)
         AND ($3::date IS NULL OR r.generated_at::date <= $3::date)
         AND ($4::text IS NULL OR
              r.receipt_number ILIKE '%' || $4 || '%' OR
              s.first_name ILIKE '%' || $4 || '%' OR
              s.last_name  ILIKE '%' || $4 || '%')
       ORDER BY r.generated_at DESC
       LIMIT $5 OFFSET $6`,
      [
        student_id || null,
        from       || null,
        to         || null,
        q          || null,
        parseInt(limit),
        offset,
      ]
    );

    res.json({ success: true, data: { receipts: rows, page: parseInt(page), limit: parseInt(limit) } });
  } catch (err) { next(err); }
}

// ── GET /api/academy/fees/receipts/:id ───────────────────────────────────────

export async function getReceipt(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;

    const receipt = await academyQueryOne(
      academySlug,
      `SELECT
         r.*,
         s.first_name, s.last_name, s.mobile,
         s.parent_name, s.parent_mobile,
         c.name  AS course_name,
         sub.name AS subject_name,
         fr.amount_due, fr.amount_paid AS fr_amount_paid,
         fr.status AS fee_status, fr.due_date, fr.paid_date,
         GREATEST(0, fr.amount_due - fr.amount_paid) AS balance,
         u.name AS collected_by_name
       FROM fee_receipts r
       JOIN students s          ON s.id  = r.student_id
       LEFT JOIN fee_records fr ON fr.id = r.fee_record_id
       LEFT JOIN courses c      ON c.id  = fr.course_id
       LEFT JOIN subjects sub   ON sub.id = fr.subject_id
       LEFT JOIN users u        ON u.id  = r.generated_by
       WHERE r.id = $1`,
      [id]
    );

    if (!receipt) return next(new AppError('Receipt not found', 404));
    res.json({ success: true, data: receipt });
  } catch (err) { next(err); }
}

// ── POST /api/academy/fees/receipts/:id/resend ────────────────────────────────

export async function resendReceipt(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;

    const receipt = await academyQueryOne<{
      id: string; receipt_number: string; amount_paid: number;
      student_id: string;
      course_name: string | null; subject_name: string | null;
    }>(
      academySlug,
      `SELECT r.id, r.receipt_number, r.amount_paid, r.student_id,
              c.name   AS course_name,
              sub.name AS subject_name
       FROM fee_receipts r
       LEFT JOIN fee_records fr ON fr.id  = r.fee_record_id
       LEFT JOIN courses  c     ON c.id   = fr.course_id
       LEFT JOIN subjects sub   ON sub.id = fr.subject_id
       WHERE r.id = $1`,
      [id]
    );
    if (!receipt) return next(new AppError('Receipt not found', 404));

    const student = await academyQueryOne<{
      first_name: string; last_name: string; parent_name: string | null;
      parent_fcm_token: string | null;
    }>(
      academySlug,
      `SELECT first_name, last_name, parent_name, parent_fcm_token
       FROM students WHERE id = $1`,
      [receipt.student_id]
    );

    if (!student?.parent_fcm_token) {
      return next(new AppError('No parent FCM token on file for this student', 422));
    }

    const subLine = [receipt.course_name, receipt.subject_name].filter(Boolean).join(' › ');
    const sent = await sendFcm({
      token: student.parent_fcm_token,
      title: 'Fee Payment Receipt',
      body:
        `Dear ${student.parent_name ?? 'Parent'}, fee receipt for ` +
        `${student.first_name} ${student.last_name}` +
        (subLine ? ` (${subLine})` : '') +
        ` ready. Amount: ₹${parseFloat(receipt.amount_paid.toString()).toFixed(0)}. ` +
        `Receipt No: ${receipt.receipt_number}.`,
      data: { type: 'fee_receipt', receipt_id: receipt.id, receipt_number: receipt.receipt_number },
    });

    if (sent) {
      await academyExec(
        academySlug,
        `UPDATE fee_receipts SET fcm_sent = TRUE WHERE id = $1`,
        [id]
      );
    }

    res.json({
      success: true,
      data: { sent },
      message: sent ? 'Notification sent to parent' : 'FCM send failed — check server logs',
    });
  } catch (err) { next(err); }
}
