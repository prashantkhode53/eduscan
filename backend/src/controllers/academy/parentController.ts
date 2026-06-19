import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import bcrypt from 'bcrypt';
import { academyQuery, academyQueryOne, academyExec } from '../../db/poolManager';
import { queryOne } from '../../db/pool';
import { AppError } from '../../middleware/errorHandler';
import { batchEmbed } from '../../utils/insightface';
import { cosineSimilarity } from '../../utils/faceMatch';
import { subjectNamesSql } from './feeController';

function jwtSecret(): string {
  const s = process.env.JWT_SECRET;
  if (!s) throw new Error('JWT_SECRET not configured');
  return s;
}

function normalMobile(m: string): string {
  return m.replace(/\D/g, '').slice(-10);
}

// ── POST /api/academy/parent/check-credentials ────────────────────────────────
// Step 1: validate Academy Code + Student ID + Mobile.
// Returns a short-lived (5 min) session token used to unlock the face-scan step.

export async function checkCredentials(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academy_slug, student_id, mobile } = req.body as {
      academy_slug?: string;
      student_id?:  string;
      mobile?:      string;
    };

    if (!academy_slug || !student_id || !mobile) {
      return next(new AppError('academy_slug, student_id and mobile are required', 400));
    }

    const academy = await queryOne<{
      id: string; name: string; slug: string; status: string;
    }>(
      `SELECT id, name, slug, status FROM academies WHERE slug = $1`,
      [academy_slug.toLowerCase().trim()]
    );
    if (!academy)                    return next(new AppError('Academy not found. Check your academy code.', 404));
    if (academy.status !== 'active') return next(new AppError('This academy is inactive.', 403));

    const student = await academyQueryOne<{
      id: string; first_name: string; last_name: string;
      parent_name: string | null; parent_mobile: string | null;
      face_embedding: unknown; status: string;
      fallback_password_enabled: boolean;
    }>(
      academy.slug,
      `SELECT id, first_name, last_name, parent_name, parent_mobile,
              face_embedding, status, fallback_password_enabled
       FROM students WHERE id = $1 AND status = 'active'`,
      [student_id.trim().toUpperCase()]
    );

    if (!student)               return next(new AppError('Student not found or inactive.', 404));
    if (!student.parent_mobile) return next(new AppError('No parent mobile on file. Contact academy admin.', 403));

    if (normalMobile(student.parent_mobile) !== normalMobile(mobile)) {
      return next(new AppError('Student ID or mobile number is incorrect.', 401));
    }

    const hasFace = student.face_embedding !== null &&
                    Array.isArray(student.face_embedding) &&
                    (student.face_embedding as unknown[]).length > 0;

    if (!hasFace && !student.fallback_password_enabled) {
      return next(new AppError(
        'No face registered for this student. Please contact your academy admin to complete registration.',
        403
      ));
    }

    // Issue a 5-minute session token — only valid for the face-scan or password step
    const sessionToken = jwt.sign(
      {
        type:        'parent_session',
        studentId:   student.id,
        academySlug: academy.slug,
        academyName: academy.name,
        parentName:  student.parent_name ?? '',
        mobile:      normalMobile(mobile),
      },
      jwtSecret(),
      { expiresIn: '5m' } as import('jsonwebtoken').SignOptions
    );

    console.log(`[parent/check-credentials] OK: ${student.id} @ ${academy.slug}`);

    res.json({
      success: true,
      data: {
        session_token:       sessionToken,
        student_name:        `${student.first_name} ${student.last_name}`,
        academy_name:        academy.name,
        has_face:            hasFace,
        has_master_password: student.fallback_password_enabled,
      },
      message: 'Credentials verified. Please scan your face to continue.',
    });
  } catch (err) { next(err); }
}

// ── POST /api/academy/parent/verify-face ─────────────────────────────────────
// Step 2: verify face against stored embedding.
// Requires valid session token (from step 1) as Bearer header.
// Returns a 30-day parent JWT on success.

export async function verifyFace(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { studentId, academySlug, academyName, parentName, mobile } = req.parentSession!;
    const { face_image } = req.body as { face_image?: string };

    if (!face_image) return next(new AppError('face_image is required', 400));

    // Get stored face embedding
    const student = await academyQueryOne<{
      id: string; first_name: string; last_name: string;
      face_embedding: unknown; parent_name: string | null;
    }>(
      academySlug,
      `SELECT id, first_name, last_name, face_embedding, parent_name
       FROM students WHERE id = $1 AND status = 'active'`,
      [studentId]
    );

    if (!student)              return next(new AppError('Student not found.', 404));
    if (!student.face_embedding) return next(new AppError('No face registered. Contact admin.', 403));

    // Extract embedding from the scan image via InsightFace
    let embed;
    try {
      embed = await batchEmbed([face_image]);
    } catch {
      return next(new AppError('Face recognition service unavailable. Please try again.', 503));
    }

    if (!embed.success || !embed.embedding) {
      return next(new AppError(
        embed.reason === 'no_face_detected'
          ? 'No face detected. Look directly at the camera.'
          : 'Face scan failed. Ensure good lighting and try again.',
        422
      ));
    }

    // Cosine similarity against stored embedding
    const stored: number[] = typeof student.face_embedding === 'string'
      ? JSON.parse(student.face_embedding)
      : (student.face_embedding as number[]);

    const score = cosineSimilarity(embed.embedding, stored);
    const threshold = 0.70;

    console.log(`[parent/verify-face] ${studentId} score=${score.toFixed(4)} threshold=${threshold}`);

    if (score < threshold) {
      return next(new AppError(
        `Face not recognised (${(score * 100).toFixed(1)}% match, need ≥${threshold * 100}%). ` +
        'Try in better lighting or contact admin.',
        401
      ));
    }

    // Issue 30-day parent JWT
    const token = jwt.sign(
      {
        type:        'parent',
        studentId:   student.id,
        academySlug: academySlug,
        academyName: academyName,
        parentName:  student.parent_name ?? parentName,
        mobile:      mobile,
      },
      jwtSecret(),
      { expiresIn: '30d' } as import('jsonwebtoken').SignOptions
    );

    console.log(`[parent/verify-face] LOGIN SUCCESS: ${studentId} @ ${academySlug} score=${score.toFixed(4)}`);

    // Record login time (fire-and-forget — don't block the response)
    academyExec(academySlug, `UPDATE students SET last_login = NOW() WHERE id = $1`, [studentId])
      .catch((e) => console.error('[parent/verify-face] last_login update failed:', e));

    res.json({
      success: true,
      data: {
        token,
        student: {
          id:          student.id,
          first_name:  student.first_name,
          last_name:   student.last_name,
          parent_name: student.parent_name ?? '',
        },
        academy: { name: academyName, slug: academySlug },
        confidence: Math.round(score * 10000) / 10000,
      },
      message: 'Face verified. Login successful.',
    });
  } catch (err) { next(err); }
}

// ── POST /api/academy/parent/fcm-token ───────────────────────────────────────

export async function saveFcmToken(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { studentId, academySlug } = req.parentUser!;
    const { fcm_token } = req.body as { fcm_token?: string };
    if (!fcm_token) return next(new AppError('fcm_token is required', 400));

    await academyQuery(
      academySlug,
      `UPDATE students SET parent_fcm_token = $1, updated_at = NOW() WHERE id = $2`,
      [fcm_token, studentId]
    );
    res.json({ success: true, message: 'FCM token saved' });
  } catch (err) { next(err); }
}

// ── GET /api/academy/parent/profile ──────────────────────────────────────────

export async function getParentProfile(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { studentId, academySlug } = req.parentUser!;
    const today = new Date().toISOString().split('T')[0];

    const [student, todayAtt, pendingFees] = await Promise.all([
      academyQueryOne<Record<string, unknown>>(
        academySlug,
        `SELECT s.id, s.first_name, s.last_name, s.mobile,
                COALESCE(
                  json_agg(
                    json_build_object('name', c.name)
                    ORDER BY c.name
                  ) FILTER (WHERE c.id IS NOT NULL AND sc.status = 'active'),
                  '[]'::json
                ) AS courses
         FROM students s
         LEFT JOIN student_courses sc ON sc.student_id = s.id
         LEFT JOIN courses c          ON c.id = sc.course_id
         WHERE s.id = $1
         GROUP BY s.id`,
        [studentId]
      ),
      academyQueryOne<Record<string, unknown>>(
        academySlug,
        `SELECT time_in, time_out, duration_mins, status, date
         FROM attendance WHERE student_id = $1 AND date = $2`,
        [studentId, today]
      ),
      academyQuery<Record<string, unknown>>(
        academySlug,
        `SELECT fr.status, fr.amount_due, fr.amount_paid, fr.due_date,
                (SELECT name FROM courses WHERE id = fr.course_id) AS course_name,
                ${subjectNamesSql('fr.student_id', 'fr.course_id')} AS subject_names
         FROM fee_records fr
         WHERE fr.student_id = $1 AND fr.status IN ('pending', 'overdue')
         ORDER BY fr.due_date ASC LIMIT 5`,
        [studentId]
      ),
    ]);

    if (!student) return next(new AppError('Student not found', 404));

    res.json({
      success: true,
      data: { student, today_attendance: todayAtt, pending_fees: pendingFees },
    });
  } catch (err) { next(err); }
}

// ── GET /api/academy/parent/attendance ───────────────────────────────────────

export async function getAttendanceHistory(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { studentId, academySlug } = req.parentUser!;

    // Filter precedence (backward compatible — `days` remains the default when
    // none of the new params are supplied, so the existing dashboard is unchanged):
    //   1. month=YYYY-MM        → that whole calendar month
    //   2. from=YYYY-MM-DD[&to] → explicit date range (to defaults to today)
    //   3. days=N               → trailing N days (legacy default = 30)
    const monthRaw = (req.query['month'] as string) ?? '';
    const fromRaw  = (req.query['from']  as string) ?? '';
    const toRaw    = (req.query['to']    as string) ?? '';

    const DATE_RE  = /^\d{4}-\d{2}-\d{2}$/;
    const MONTH_RE = /^\d{4}-\d{2}$/;

    let where = 'student_id = $1';
    const params: unknown[] = [studentId];

    if (MONTH_RE.test(monthRaw)) {
      // [first-of-month, first-of-next-month) — avoids end-of-month edge cases.
      params.push(`${monthRaw}-01`);
      where += ` AND date >= $${params.length}::date
                 AND date <  ($${params.length}::date + INTERVAL '1 month')`;
    } else if (DATE_RE.test(fromRaw)) {
      params.push(fromRaw);
      where += ` AND date >= $${params.length}::date`;
      if (DATE_RE.test(toRaw)) {
        params.push(toRaw);
        where += ` AND date <= $${params.length}::date`;
      } else {
        where += ` AND date <= CURRENT_DATE`;
      }
    } else {
      const rawDays = parseInt((req.query['days'] as string) ?? '30', 10);
      const days = Math.max(1, Math.min(Number.isFinite(rawDays) ? rawDays : 30, 366));
      params.push(days);
      where += ` AND date >= CURRENT_DATE - MAKE_INTERVAL(days => $${params.length})`;
    }

    const records = await academyQuery<Record<string, unknown>>(
      academySlug,
      `SELECT date, time_in, time_out, duration_mins, status
       FROM attendance
       WHERE ${where}
       ORDER BY date DESC`,
      params
    );

    res.json({ success: true, data: records });
  } catch (err) { next(err); }
}

// ── GET /api/academy/parent/receipts ─────────────────────────────────────────

export async function getParentReceipts(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { studentId, academySlug } = req.parentUser!;
    const { from, to, page = '1', limit = '30' } = req.query as Record<string, string>;
    const offset = (parseInt(page) - 1) * parseInt(limit);

    const receipts = await academyQuery<Record<string, unknown>>(
      academySlug,
      `SELECT
         r.id, r.receipt_number, r.amount_paid, r.payment_mode, r.generated_at,
         COALESCE(c.name,
           (SELECT fri.course_name FROM fee_receipt_items fri
            WHERE fri.receipt_id = r.id ORDER BY fri.course_name LIMIT 1)
         ) AS course_name,
         COALESCE(
           ${subjectNamesSql('r.student_id', 'fr.course_id')},
           (SELECT STRING_AGG(DISTINCT fri.subject_name, ', ' ORDER BY fri.subject_name)
            FROM fee_receipt_items fri
            WHERE fri.receipt_id = r.id AND fri.subject_name IS NOT NULL)
         ) AS subject_names,
         sub.name AS subject_name,
         fr.amount_due, fr.amount_paid AS fr_amount_paid,
         GREATEST(0, fr.amount_due - fr.amount_paid) AS balance,
         fr.status AS fee_status, fr.due_date
       FROM fee_receipts r
       LEFT JOIN fee_records fr ON fr.id = r.fee_record_id
       LEFT JOIN courses c      ON c.id  = fr.course_id
       LEFT JOIN subjects sub   ON sub.id = fr.subject_id
       WHERE r.student_id = $1
         AND ($2::date IS NULL OR r.generated_at::date >= $2::date)
         AND ($3::date IS NULL OR r.generated_at::date <= $3::date)
       ORDER BY r.generated_at DESC
       LIMIT $4 OFFSET $5`,
      [studentId, from || null, to || null, parseInt(limit), offset]
    );

    // Overall fee summary for this student
    const summary = await academyQueryOne<{
      total_due: string; total_paid: string; total_balance: string;
    }>(
      academySlug,
      `SELECT
         COALESCE(SUM(amount_due),  0) AS total_due,
         COALESCE(SUM(amount_paid), 0) AS total_paid,
         COALESCE(SUM(GREATEST(0, amount_due - amount_paid)), 0) AS total_balance
       FROM fee_records WHERE student_id = $1`,
      [studentId]
    );

    res.json({
      success: true,
      data: {
        receipts,
        summary: {
          total_due:     parseFloat(summary?.total_due     ?? '0'),
          total_paid:    parseFloat(summary?.total_paid    ?? '0'),
          total_balance: parseFloat(summary?.total_balance ?? '0'),
        },
        page: parseInt(page),
        limit: parseInt(limit),
      },
    });
  } catch (err) { next(err); }
}

// ── POST /api/academy/parent/verify-password ─────────────────────────────────
// Fallback login when face scan is not possible.
// Requires valid 5-min session token (same as /verify-face).
// Admin must have set fallback_password_enabled = true for this student.

export async function verifyPassword(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { studentId, academySlug, academyName, parentName, mobile } = req.parentSession!;
    const { password } = req.body as { password?: string };

    if (!password) return next(new AppError('password is required', 400));

    const student = await academyQueryOne<{
      id: string; first_name: string; last_name: string;
      parent_name: string | null;
      fallback_password_hash: string | null;
      fallback_password_enabled: boolean;
    }>(
      academySlug,
      `SELECT id, first_name, last_name, parent_name,
              fallback_password_hash, fallback_password_enabled
       FROM students WHERE id = $1 AND status = 'active'`,
      [studentId]
    );

    if (!student) return next(new AppError('Student not found.', 404));

    if (!student.fallback_password_enabled || !student.fallback_password_hash) {
      return next(new AppError('Password login is not enabled for this student. Contact your institute.', 403));
    }

    const match = await bcrypt.compare(password, student.fallback_password_hash);

    console.log(`[parent/verify-password] ${studentId} @ ${academySlug} match=${match}`);

    if (!match) {
      return next(new AppError('Incorrect password. Contact your institute.', 401));
    }

    const token = jwt.sign(
      {
        type:        'parent',
        studentId:   student.id,
        academySlug: academySlug,
        academyName: academyName,
        parentName:  student.parent_name ?? parentName,
        mobile:      mobile,
      },
      jwtSecret(),
      { expiresIn: '30d' } as import('jsonwebtoken').SignOptions
    );

    console.log(`[parent/verify-password] LOGIN SUCCESS (password): ${studentId} @ ${academySlug}`);

    academyExec(academySlug, `UPDATE students SET last_login = NOW() WHERE id = $1`, [studentId])
      .catch((e) => console.error('[parent/verify-password] last_login update failed:', e));

    res.json({
      success: true,
      data: {
        token,
        student: {
          id:          student.id,
          first_name:  student.first_name,
          last_name:   student.last_name,
          parent_name: student.parent_name ?? '',
        },
        academy: { name: academyName, slug: academySlug },
        login_method: 'password',
      },
      message: 'Password verified. Login successful.',
    });
  } catch (err) { next(err); }
}

// ── GET /api/academy/parent/receipts/:id ─────────────────────────────────────

export async function getParentReceipt(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { studentId, academySlug } = req.parentUser!;
    const { id } = req.params;

    const receipt = await academyQueryOne<Record<string, unknown>>(
      academySlug,
      `SELECT
         r.id, r.receipt_number, r.amount_paid, r.payment_mode, r.generated_at,
         s.id AS student_id, s.first_name, s.last_name, s.mobile, s.parent_name,
         COALESCE(c.name,
           (SELECT fri.course_name FROM fee_receipt_items fri
            WHERE fri.receipt_id = r.id ORDER BY fri.course_name LIMIT 1)
         ) AS course_name,
         COALESCE(
           ${subjectNamesSql('r.student_id', 'fr.course_id')},
           (SELECT STRING_AGG(DISTINCT fri.subject_name, ', ' ORDER BY fri.subject_name)
            FROM fee_receipt_items fri
            WHERE fri.receipt_id = r.id AND fri.subject_name IS NOT NULL)
         ) AS subject_names,
         sub.name AS subject_name,
         fr.amount_due, fr.amount_paid AS fr_amount_paid,
         GREATEST(0, fr.amount_due - fr.amount_paid) AS balance,
         fr.status AS fee_status, fr.due_date, fr.paid_date
       FROM fee_receipts r
       JOIN students s          ON s.id  = r.student_id
       LEFT JOIN fee_records fr ON fr.id = r.fee_record_id
       LEFT JOIN courses c      ON c.id  = fr.course_id
       LEFT JOIN subjects sub   ON sub.id = fr.subject_id
       WHERE r.id = $1 AND r.student_id = $2`,
      [id, studentId]
    );

    if (!receipt) return next(new AppError('Receipt not found', 404));

    // Itemised lines (multi-subject receipts) so the parent view can show each
    // course with its subjects.
    const items = await academyQuery<Record<string, unknown>>(
      academySlug,
      `SELECT fri.course_id, fri.course_name, fri.subject_id, fri.subject_name,
              fri.amount_paid
       FROM fee_receipt_items fri
       WHERE fri.receipt_id = $1
       ORDER BY fri.course_name, fri.subject_name`,
      [id]
    );

    res.json({ success: true, data: { ...receipt, items: items.length > 0 ? items : null } });
  } catch (err) { next(err); }
}
