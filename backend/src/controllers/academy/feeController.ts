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
      due_filter,
      page = '1', limit = '50',
    } = req.query as Record<string, string>;

    const offset = (parseInt(page) - 1) * parseInt(limit);

    // Course-level aggregation: one row per (student, course)
    const rows = await academyQuery(
      academySlug,
      `WITH course_fees AS (
         SELECT
           s.id          AS student_id,
           s.first_name, s.last_name, s.mobile,
           c.id          AS course_id,
           c.name        AS course_name,
           STRING_AGG(DISTINCT sub.name, ', ' ORDER BY sub.name)
             FILTER (WHERE sub.name IS NOT NULL)       AS subject_names,
           SUM(fr.amount_due)                          AS amount_due,
           SUM(fr.amount_paid)                         AS amount_paid,
           SUM(GREATEST(0, fr.amount_due - fr.amount_paid)) AS balance,
           MAX(fr.due_date)                            AS due_date,
           CASE
             WHEN SUM(GREATEST(0, fr.amount_due - fr.amount_paid)) <= 0
               THEN 'paid'
             WHEN CURRENT_DATE > MAX(fr.due_date)
              AND SUM(GREATEST(0, fr.amount_due - fr.amount_paid)) > 0
               THEN 'overdue'
             WHEN SUM(fr.amount_paid) > 0
              AND SUM(GREATEST(0, fr.amount_due - fr.amount_paid)) > 0
               THEN 'partial'
             ELSE 'pending'
           END           AS status,
           JSON_AGG(
             JSON_BUILD_OBJECT(
               'id',           fr.id,
               'course_id',    fr.course_id,
               'course_name',  c.name,
               'subject_id',   fr.subject_id,
               'subject_name', sub.name,
               'amount_due',   fr.amount_due,
               'amount_paid',  fr.amount_paid,
               'balance',      GREATEST(0, fr.amount_due - fr.amount_paid),
               'status',       fr.status,
               'due_date',     fr.due_date
             ) ORDER BY fr.due_date
           )               AS fee_records
         FROM fee_records fr
         JOIN students s      ON s.id  = fr.student_id
         LEFT JOIN courses c  ON c.id  = fr.course_id
         LEFT JOIN subjects sub ON sub.id = fr.subject_id
         WHERE ($2::text IS NULL OR fr.student_id = $2)
           AND ($3::uuid IS NULL OR fr.course_id  = $3::uuid)
           AND (
             ($7::text IS NULL AND ($4::text IS NULL OR TO_CHAR(fr.due_date,'YYYY-MM') = $4))
             OR ($7 = 'today'      AND fr.due_date = CURRENT_DATE)
             OR ($7 = 'this_week'  AND fr.due_date >= CURRENT_DATE AND fr.due_date <= CURRENT_DATE + INTERVAL '6 days')
             OR ($7 = 'this_month' AND TO_CHAR(fr.due_date,'YYYY-MM') = TO_CHAR(CURRENT_DATE,'YYYY-MM'))
             OR ($7 = 'overdue'    AND fr.due_date < CURRENT_DATE AND fr.status IN ('pending','partial','overdue'))
             OR ($7 = 'upcoming'   AND fr.due_date >= CURRENT_DATE AND fr.status IN ('pending','partial'))
           )
         GROUP BY s.id, s.first_name, s.last_name, s.mobile, c.id, c.name
       )
       SELECT * FROM course_fees
       WHERE ($1::text IS NULL OR status = $1)
       ORDER BY
         CASE status
           WHEN 'overdue'  THEN 1
           WHEN 'pending'  THEN 2
           WHEN 'partial'  THEN 3
           ELSE 4
         END,
         due_date ASC
       LIMIT $5 OFFSET $6`,
      [
        status       || null,
        student_id   || null,
        course_id    || null,
        month        || null,
        parseInt(limit),
        offset,
        due_filter   || null,
      ]
    );

    // Course-level summary statistics
    const summary = await academyQueryOne<{
      total_due: string; total_paid: string;
      count_pending: string; count_overdue: string;
      count_partial: string; count_paid: string;
    }>(
      academySlug,
      `WITH course_fees AS (
         SELECT
           SUM(fr.amount_due)   AS total_due,
           SUM(fr.amount_paid)  AS total_paid,
           CASE
             WHEN SUM(GREATEST(0, fr.amount_due - fr.amount_paid)) <= 0
               THEN 'paid'
             WHEN CURRENT_DATE > MAX(fr.due_date)
              AND SUM(GREATEST(0, fr.amount_due - fr.amount_paid)) > 0
               THEN 'overdue'
             WHEN SUM(fr.amount_paid) > 0
              AND SUM(GREATEST(0, fr.amount_due - fr.amount_paid)) > 0
               THEN 'partial'
             ELSE 'pending'
           END AS status
         FROM fee_records fr
         WHERE (
           ($2::text IS NULL AND ($1::text IS NULL OR TO_CHAR(fr.due_date,'YYYY-MM') = $1))
           OR ($2 = 'today'      AND fr.due_date = CURRENT_DATE)
           OR ($2 = 'this_week'  AND fr.due_date >= CURRENT_DATE AND fr.due_date <= CURRENT_DATE + INTERVAL '6 days')
           OR ($2 = 'this_month' AND TO_CHAR(fr.due_date,'YYYY-MM') = TO_CHAR(CURRENT_DATE,'YYYY-MM'))
           OR ($2 = 'overdue'    AND fr.due_date < CURRENT_DATE AND fr.status IN ('pending','partial','overdue'))
           OR ($2 = 'upcoming'   AND fr.due_date >= CURRENT_DATE AND fr.status IN ('pending','partial'))
         )
         GROUP BY fr.student_id, fr.course_id
       )
       SELECT
         COALESCE(SUM(total_due),  0) AS total_due,
         COALESCE(SUM(total_paid), 0) AS total_paid,
         COUNT(*) FILTER (WHERE status='pending')  AS count_pending,
         COUNT(*) FILTER (WHERE status='overdue')  AS count_overdue,
         COUNT(*) FILTER (WHERE status='partial')  AS count_partial,
         COUNT(*) FILTER (WHERE status='paid')     AS count_paid
       FROM course_fees`,
      [month || null, due_filter || null]
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
          count_partial: parseInt(summary?.count_partial   ?? '0'),
          count_paid:    parseInt(summary?.count_paid      ?? '0'),
        },
        page: parseInt(page),
        limit: parseInt(limit),
      },
    });
  } catch (err) { next(err); }
}

// ── GET /api/academy/fees/students-summary ────────────────────────────────────
// Returns all students with pending/overdue/partial fees, grouped with their
// pending records. Drives the "Students" collection tab in the app.

export async function listFeesStudentSummary(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { month, due_filter } = req.query as Record<string, string>;

    // One query: all pending fee records joined to students/courses/subjects
    const rows = await academyQuery<{
      student_id: string; first_name: string; last_name: string; mobile: string;
      record_id: string; course_id: string | null; subject_id: string | null;
      amount_due: string; amount_paid: string; status: string; due_date: string;
      course_name: string | null; subject_name: string | null;
    }>(
      academySlug,
      `SELECT
         s.id        AS student_id,
         s.first_name, s.last_name, s.mobile,
         fr.id       AS record_id,
         fr.course_id, fr.subject_id,
         fr.amount_due, fr.amount_paid, fr.status, fr.due_date,
         c.name      AS course_name,
         sub.name    AS subject_name
       FROM students s
       JOIN fee_records fr ON fr.student_id = s.id
         AND fr.status IN ('pending', 'partial', 'overdue')
         AND (
           ($2::text IS NULL AND ($1::text IS NULL OR TO_CHAR(fr.due_date,'YYYY-MM') = $1))
           OR ($2 = 'today'      AND fr.due_date = CURRENT_DATE)
           OR ($2 = 'this_week'  AND fr.due_date >= CURRENT_DATE AND fr.due_date <= CURRENT_DATE + INTERVAL '6 days')
           OR ($2 = 'this_month' AND TO_CHAR(fr.due_date,'YYYY-MM') = TO_CHAR(CURRENT_DATE,'YYYY-MM'))
           OR ($2 = 'overdue'    AND fr.due_date < CURRENT_DATE)
           OR ($2 = 'upcoming'   AND fr.due_date >= CURRENT_DATE)
         )
       LEFT JOIN courses c    ON c.id   = fr.course_id
       LEFT JOIN subjects sub ON sub.id = fr.subject_id
       WHERE s.status = 'active'
       ORDER BY s.first_name, s.last_name, fr.due_date ASC`,
      [month || null, due_filter || null]
    );

    // Group by student
    const map = new Map<string, {
      student_id: string; first_name: string; last_name: string; mobile: string;
      balance: number; pending_count: number;
      pending_records: object[];
    }>();

    for (const row of rows) {
      if (!map.has(row.student_id)) {
        map.set(row.student_id, {
          student_id:     row.student_id,
          first_name:     row.first_name,
          last_name:      row.last_name,
          mobile:         row.mobile,
          balance:        0,
          pending_count:  0,
          pending_records: [],
        });
      }
      const student = map.get(row.student_id)!;
      const due  = parseFloat(row.amount_due);
      const paid = parseFloat(row.amount_paid);
      const bal  = Math.max(0, due - paid);
      student.balance       += bal;
      student.pending_count += 1;
      student.pending_records.push({
        id:           row.record_id,
        course_id:    row.course_id,
        course_name:  row.course_name,
        subject_id:   row.subject_id,
        subject_name: row.subject_name,
        amount_due:   due,
        amount_paid:  paid,
        balance:      bal,
        status:       row.status,
        due_date:     row.due_date,
      });
    }

    // Sort descending by balance
    const students = [...map.values()].sort((a, b) => b.balance - a.balance);

    res.json({ success: true, data: { students } });
  } catch (err) { next(err); }
}

// ── POST /api/academy/fees/collect ────────────────────────────────────────────
// Accepts both:
//   NEW format: { student_id, items: [{fee_record_id, amount_paid}], payment_mode, remarks }
//   OLD format: { fee_record_id, amount_paid, payment_mode, remarks }

export async function collectFee(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug, userId } = req.academyUser!;
    const { payment_mode = 'cash', remarks } = req.body as Record<string, unknown>;

    // Normalize input
    let items: Array<{ fee_record_id: string; amount_paid: number }>;
    let studentIdArg: string | undefined;

    if (Array.isArray(req.body.items)) {
      items        = req.body.items as typeof items;
      studentIdArg = req.body.student_id as string | undefined;
      if (!items.length) return next(new AppError('items array must not be empty', 400));
    } else if (req.body.fee_record_id) {
      items        = [{ fee_record_id: req.body.fee_record_id as string, amount_paid: req.body.amount_paid as number }];
      studentIdArg = undefined;
    } else {
      return next(new AppError('Provide either items[] or fee_record_id', 400));
    }

    for (const item of items) {
      if (!item.fee_record_id || !item.amount_paid || item.amount_paid <= 0) {
        return next(new AppError('Each item requires fee_record_id and amount_paid > 0', 400));
      }
    }

    // Fetch all fee records + enrichment in one query
    const ids = items.map(i => i.fee_record_id);
    type RecordRow = {
      id: string; student_id: string; course_id: string | null; subject_id: string | null;
      amount_due: string; amount_paid: string; status: string;
      course_name: string | null; subject_name: string | null;
    };
    const records = await academyQuery<RecordRow>(
      academySlug,
      `SELECT fr.id, fr.student_id, fr.course_id, fr.subject_id,
              fr.amount_due, fr.amount_paid, fr.status,
              c.name   AS course_name,
              sub.name AS subject_name
       FROM fee_records fr
       LEFT JOIN courses  c   ON c.id   = fr.course_id
       LEFT JOIN subjects sub ON sub.id = fr.subject_id
       WHERE fr.id = ANY($1::uuid[])`,
      [ids]
    );

    if (records.length !== ids.length) {
      return next(new AppError('One or more fee records not found', 404));
    }

    const studentId = studentIdArg ?? records[0].student_id;
    for (const rec of records) {
      if (rec.student_id !== studentId) {
        return next(new AppError('All fee records must belong to the same student', 400));
      }
      if (rec.status === 'paid') {
        return next(new AppError(`Fee record is already fully paid`, 409));
      }
    }

    const remarksFull = [
      payment_mode ? `Mode: ${payment_mode}` : null,
      (remarks as string) || null,
    ].filter(Boolean).join(' | ');

    type ItemUpdate = {
      id: string; newPaid: number; newStatus: string; paidDate: string | null;
      course_id: string | null; subject_id: string | null;
      course_name: string | null; subject_name: string | null;
      amountInReceipt: number;
    };

    const updates: ItemUpdate[] = records.map(rec => {
      const item       = items.find(i => i.fee_record_id === rec.id)!;
      const curPaid    = parseFloat(rec.amount_paid);
      const newPaid    = curPaid + item.amount_paid;
      const balance    = parseFloat(rec.amount_due) - newPaid;
      const newStatus  = balance <= 0 ? 'paid' : newPaid > 0 ? 'partial' : rec.status;
      const paidDate   = newStatus === 'paid' ? new Date().toISOString().split('T')[0] : null;
      return {
        id: rec.id, newPaid, newStatus, paidDate,
        course_id: rec.course_id, subject_id: rec.subject_id,
        course_name: rec.course_name, subject_name: rec.subject_name,
        amountInReceipt: item.amount_paid,
      };
    });

    const totalAmountPaid = items.reduce((s, i) => s + i.amount_paid, 0);
    const txResult        = { receiptNumber: '', receiptId: '' };

    await academyTransaction(academySlug, async (client) => {
      // Update each fee record
      for (const u of updates) {
        await client.query(
          `UPDATE fee_records
           SET amount_paid  = $1,
               status       = $2,
               paid_date    = $3,
               remarks      = $4,
               collected_by = $5,
               updated_at   = NOW()
           WHERE id = $6`,
          [u.newPaid, u.newStatus, u.paidDate, remarksFull || null, userId, u.id]
        );
      }

      // Generate receipt number
      const year = new Date().getFullYear();
      const { rows: seqRows } = await client.query<{ n: string }>(`SELECT nextval('fee_receipt_seq') AS n`);
      txResult.receiptNumber = `RCP-${year}-${String(seqRows[0].n).padStart(6, '0')}`;

      // Keep fee_record_id on receipt for backward compat when single item
      const legacyFeeRecordId = updates.length === 1 ? updates[0].id : null;

      const { rows: rcptRows } = await client.query<{ id: string }>(
        `INSERT INTO fee_receipts
           (receipt_number, fee_record_id, student_id, amount_paid, payment_mode, generated_by)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id`,
        [txResult.receiptNumber, legacyFeeRecordId, studentId, totalAmountPaid, payment_mode, userId]
      );
      txResult.receiptId = rcptRows[0].id;

      // Insert receipt items and update receipt_id on each fee_record
      for (const u of updates) {
        await client.query(
          `INSERT INTO fee_receipt_items
             (receipt_id, fee_record_id, subject_id, subject_name, course_id, course_name, amount_paid)
           VALUES ($1, $2, $3, $4, $5, $6, $7)`,
          [txResult.receiptId, u.id, u.subject_id, u.subject_name, u.course_id, u.course_name, u.amountInReceipt]
        );
        await client.query(
          `UPDATE fee_records SET receipt_id = $1 WHERE id = $2`,
          [txResult.receiptId, u.id]
        );
      }
    });

    const { receiptNumber, receiptId } = txResult;

    // FCM notification (fire-and-forget)
    const student = await academyQueryOne<{
      first_name: string; last_name: string; parent_name: string | null;
      parent_fcm_token: string | null;
    }>(
      academySlug,
      `SELECT first_name, last_name, parent_name, parent_fcm_token FROM students WHERE id = $1`,
      [studentId]
    );

    if (student?.parent_fcm_token) {
      const coursesMap = new Map<string, string[]>();
      for (const u of updates) {
        const cName = u.course_name ?? 'Course';
        if (!coursesMap.has(cName)) coursesMap.set(cName, []);
        if (u.subject_name) coursesMap.get(cName)!.push(u.subject_name);
      }
      const subjectLine = [...coursesMap.entries()]
        .map(([c, subs]) => (subs.length > 0 ? `${c}: ${subs.join(', ')}` : c))
        .join('; ');

      const allClear  = updates.every(u => u.newStatus === 'paid');
      const statusLine = allClear
        ? 'All fees are now cleared.'
        : `Payment of ₹${totalAmountPaid.toFixed(0)} recorded.`;

      void sendFcm({
        token: student.parent_fcm_token,
        title: 'Fee Payment Received',
        body:
          `Dear ${student.parent_name ?? 'Parent'}, ` +
          `₹${totalAmountPaid.toFixed(0)} received for ` +
          `${student.first_name} ${student.last_name}` +
          (subjectLine ? ` (${subjectLine})` : '') +
          `. ${statusLine} Receipt No: ${receiptNumber}.`,
        data: {
          type:           'fee_receipt',
          receipt_id:     receiptId,
          receipt_number: receiptNumber,
        },
      }).then((sent: boolean) => {
        if (sent) {
          void academyExec(academySlug, `UPDATE fee_receipts SET fcm_sent = TRUE WHERE id = $1`, [receiptId]);
        }
      });
    }

    res.json({
      success: true,
      data: {
        receipt_number: receiptNumber,
        receipt_id:     receiptId,
        student_id:     studentId,
        total_paid:     totalAmountPaid,
        items: updates.map(u => ({
          fee_record_id: u.id,
          status:        u.newStatus,
          amount_paid:   u.amountInReceipt,
        })),
      },
      message: `₹${totalAmountPaid.toFixed(0)} collected · Receipt ${receiptNumber}`,
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

    // One fee record per student per course = sum of active subject fees.
    // Due date uses the course's fee_due_day if set, otherwise last day of month.
    const { rowCount } = await academyExec(
      academySlug,
      `INSERT INTO fee_records (student_id, course_id, amount_due, due_date, status)
       SELECT
         t.student_id,
         t.course_id,
         t.total_fee,
         CASE
           WHEN c.fee_due_date IS NOT NULL
           THEN (DATE_TRUNC('month', $1::date) + (EXTRACT(DAY FROM c.fee_due_date)::int - 1) * INTERVAL '1 day')::date
           WHEN c.fee_due_day IS NOT NULL
           THEN (DATE_TRUNC('month', $1::date) + (c.fee_due_day - 1) * INTERVAL '1 day')::date
           ELSE $1::date
         END,
         'pending'
       FROM (
         SELECT ss.student_id, sub.course_id, SUM(ss.fee_amount) AS total_fee
         FROM student_subjects ss
         JOIN subjects sub ON sub.id = ss.subject_id
         WHERE ss.status = 'active'
         GROUP BY ss.student_id, sub.course_id
       ) t
       JOIN courses c ON c.id = t.course_id
       WHERE NOT EXISTS (
         SELECT 1 FROM fee_records fr
         WHERE fr.student_id = t.student_id
           AND fr.course_id  = t.course_id
           AND fr.subject_id IS NULL
           AND TO_CHAR(fr.due_date, 'YYYY-MM') = $2
       )`,
      [dueDate, targetMonth]
    );

    const total = rowCount ?? 0;
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
       LEFT JOIN fee_receipts rcpt ON rcpt.id = fr.receipt_id
       WHERE fr.student_id = $1
       ORDER BY fr.due_date DESC`,
      [studentId]
    );

    const totals = await academyQueryOne<{
      total_due: string; total_paid: string; total_balance: string;
    }>(
      academySlug,
      `SELECT COALESCE(SUM(amount_due),0)                            AS total_due,
              COALESCE(SUM(amount_paid),0)                           AS total_paid,
              COALESCE(SUM(GREATEST(0, amount_due - amount_paid)),0) AS total_balance
       FROM fee_records WHERE student_id = $1`,
      [studentId]
    );

    res.json({
      success: true,
      data: {
        records,
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
         (SELECT fri.course_name FROM fee_receipt_items fri
          WHERE fri.receipt_id = r.id
          ORDER BY fri.course_name LIMIT 1)      AS course_name,
         (SELECT STRING_AGG(DISTINCT fri.subject_name, ', ' ORDER BY fri.subject_name)
          FROM fee_receipt_items fri
          WHERE fri.receipt_id = r.id
            AND fri.subject_name IS NOT NULL)     AS subject_names
       FROM fee_receipts r
       JOIN students s ON s.id = r.student_id
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
         s.first_name, s.last_name, s.mobile, s.parent_mobile,
         u.name AS collected_by_name
       FROM fee_receipts r
       JOIN students s ON s.id = r.student_id
       LEFT JOIN users u ON u.id = r.generated_by
       WHERE r.id = $1`,
      [id]
    );

    if (!receipt) return next(new AppError('Receipt not found', 404));

    // Fetch receipt items (all records paid in this receipt)
    const items = await academyQuery<{
      fee_record_id: string; course_id: string | null; course_name: string | null;
      subject_id: string | null; subject_name: string | null; amount_paid: string;
    }>(
      academySlug,
      `SELECT fri.fee_record_id, fri.course_id, fri.course_name,
              fri.subject_id, fri.subject_name, fri.amount_paid
       FROM fee_receipt_items fri
       WHERE fri.receipt_id = $1
       ORDER BY fri.course_name, fri.subject_name`,
      [id]
    );

    // Compute course-level totals from the underlying fee_records.
    // For old receipts (pre-items migration) fall back to the legacy fee_record_id
    // stored directly on fee_receipts.
    let recordIds = items.map(i => i.fee_record_id).filter(Boolean) as string[];
    if (recordIds.length === 0) {
      const legacyId = (receipt as Record<string, unknown>)['fee_record_id'] as string | null;
      if (legacyId) recordIds = [legacyId];
    }

    let courseTotals: {
      course_id: string | null; course_name: string | null;
      subject_names: string | null;
      total_course_fee: string; total_paid_now: string; remaining_balance: string;
    }[] = [];

    if (recordIds.length > 0) {
      // Get all fee_records for the same student+course combinations
      const relatedCourses = await academyQuery<{
        course_id: string | null; course_name: string | null;
        student_id: string;
      }>(
        academySlug,
        `SELECT DISTINCT fr.course_id, c.name AS course_name, fr.student_id
         FROM fee_records fr
         LEFT JOIN courses c ON c.id = fr.course_id
         WHERE fr.id = ANY($1::uuid[])`,
        [recordIds]
      );

      for (const rc of relatedCourses) {
        const totalsRow = await academyQueryOne<{
          total_course_fee: string; total_paid_now: string; subject_names: string | null;
        }>(
          academySlug,
          `SELECT
             SUM(fr.amount_due)  AS total_course_fee,
             SUM(fr.amount_paid) AS total_paid_now,
             STRING_AGG(DISTINCT sub.name, ', ' ORDER BY sub.name)
               FILTER (WHERE sub.name IS NOT NULL) AS subject_names
           FROM fee_records fr
           LEFT JOIN subjects sub ON sub.id = fr.subject_id
           WHERE fr.student_id = $1
             AND ($2::uuid IS NULL OR fr.course_id = $2::uuid)`,
          [rc.student_id, rc.course_id]
        );
        const totalCourseFee = parseFloat(totalsRow?.total_course_fee ?? '0');
        const totalPaidNow   = parseFloat(totalsRow?.total_paid_now   ?? '0');
        courseTotals.push({
          course_id:         rc.course_id,
          course_name:       rc.course_name,
          subject_names:     totalsRow?.subject_names ?? null,
          total_course_fee:  totalCourseFee.toString(),
          total_paid_now:    totalPaidNow.toString(),
          remaining_balance: Math.max(0, totalCourseFee - totalPaidNow).toString(),
        });
      }
    }

    // Primary course info (first course in the receipt)
    const primaryCourse = courseTotals[0] ?? null;
    const currentPayment = parseFloat((receipt as Record<string, unknown>)['amount_paid']?.toString() ?? '0');
    const previousPaid   = primaryCourse
      ? Math.max(0, parseFloat(primaryCourse.total_paid_now) - currentPayment)
      : 0;

    res.json({
      success: true,
      data: {
        ...receipt,
        course_name:       primaryCourse?.course_name       ?? null,
        subject_names:     primaryCourse?.subject_names     ?? null,
        total_course_fee:  primaryCourse ? parseFloat(primaryCourse.total_course_fee) : null,
        previous_paid:     primaryCourse ? previousPaid : null,
        total_paid:        primaryCourse ? parseFloat(primaryCourse.total_paid_now) : null,
        remaining_balance: primaryCourse ? parseFloat(primaryCourse.remaining_balance) : null,
        items:             items.length > 0 ? items : null,
        course_totals:     courseTotals.length > 1 ? courseTotals : null,
      },
    });
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
      id: string; receipt_number: string; amount_paid: string; student_id: string;
      course_name: string | null; subject_name: string | null;
    }>(
      academySlug,
      `SELECT r.id, r.receipt_number, r.amount_paid, r.student_id,
              COALESCE(c.name,
                (SELECT fri.course_name FROM fee_receipt_items fri
                 WHERE fri.receipt_id = r.id ORDER BY fri.course_name LIMIT 1)
              ) AS course_name,
              COALESCE(sub.name,
                (SELECT CASE WHEN COUNT(*) > 1
                             THEN COUNT(*)::TEXT || ' subjects'
                             ELSE MAX(fri.subject_name)
                        END
                 FROM fee_receipt_items fri WHERE fri.receipt_id = r.id)
              ) AS subject_name
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
      `SELECT first_name, last_name, parent_name, parent_fcm_token FROM students WHERE id = $1`,
      [receipt.student_id]
    );

    if (!student?.parent_fcm_token) {
      return next(new AppError('No parent FCM token on file for this student', 422));
    }

    const subLine    = [receipt.course_name, receipt.subject_name].filter(Boolean).join(' › ');
    const amountStr  = parseFloat(receipt.amount_paid.toString()).toFixed(0);
    const sent = await sendFcm({
      token: student.parent_fcm_token,
      title: 'Fee Payment Receipt',
      body:
        `Dear ${student.parent_name ?? 'Parent'}, fee receipt for ` +
        `${student.first_name} ${student.last_name}` +
        (subLine ? ` (${subLine})` : '') +
        ` ready. Amount: ₹${amountStr}. Receipt No: ${receipt.receipt_number}.`,
      data: { type: 'fee_receipt', receipt_id: receipt.id, receipt_number: receipt.receipt_number },
    });

    if (sent) {
      await academyExec(academySlug, `UPDATE fee_receipts SET fcm_sent = TRUE WHERE id = $1`, [id]);
    }

    res.json({
      success: true,
      data: { sent },
      message: sent ? 'Notification sent to parent' : 'FCM send failed — check server logs',
    });
  } catch (err) { next(err); }
}
