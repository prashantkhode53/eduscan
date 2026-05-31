import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { academyQuery, academyQueryOne } from '../../db/poolManager';
import { queryOne } from '../../db/pool';
import { AppError } from '../../middleware/errorHandler';

function jwtSecret(): string {
  const s = process.env.JWT_SECRET;
  if (!s) throw new Error('JWT_SECRET not configured');
  return s;
}

/** Strip non-digits and return last 10 — handles +91, 0-prefix, spaces etc. */
function normalMobile(m: string): string {
  return m.replace(/\D/g, '').slice(-10);
}

// ── POST /api/academy/parent/login ────────────────────────────────────────────

export async function parentLogin(
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

    // Validate academy exists and is active
    const academy = await queryOne<{ id: string; name: string; slug: string; status: string }>(
      `SELECT id, name, slug, status FROM academies WHERE slug = $1`,
      [academy_slug.toLowerCase().trim()]
    );
    if (!academy)              return next(new AppError('Academy not found. Check your academy code.', 404));
    if (academy.status !== 'active') return next(new AppError('This academy is inactive.', 403));

    // Find student and validate parent mobile
    const student = await academyQueryOne<{
      id: string; first_name: string; last_name: string;
      parent_name: string | null; parent_mobile: string | null; status: string;
    }>(
      academy.slug,
      `SELECT id, first_name, last_name, parent_name, parent_mobile, status
       FROM students WHERE id = $1 AND status = 'active'`,
      [student_id.trim().toUpperCase()]
    );

    if (!student)                 return next(new AppError('Student not found or inactive.', 404));
    if (!student.parent_mobile)   return next(new AppError('No parent mobile on file. Contact academy admin.', 403));
    if (normalMobile(student.parent_mobile) !== normalMobile(mobile)) {
      return next(new AppError('Student ID or mobile number is incorrect.', 401));
    }

    const token = jwt.sign(
      {
        type:        'parent',
        studentId:   student.id,
        academySlug: academy.slug,
        academyName: academy.name,
        parentName:  student.parent_name ?? '',
        mobile:      normalMobile(mobile),
      },
      jwtSecret(),
      { expiresIn: '30d' } as import('jsonwebtoken').SignOptions
    );

    console.log(`[parent/login] ${student.id} @ ${academy.slug}`);

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
        academy: { name: academy.name, slug: academy.slug },
      },
      message: 'Login successful',
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
        `SELECT fr.status,
                fr.amount_due,
                fr.amount_paid,
                fr.due_date,
                (SELECT name FROM courses WHERE id = fr.course_id) AS course_name
         FROM fee_records fr
         WHERE fr.student_id = $1 AND fr.status IN ('pending', 'overdue')
         ORDER BY fr.due_date ASC
         LIMIT 5`,
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
    const rawDays = parseInt((req.query['days'] as string) ?? '30', 10);
    const days = Math.max(1, Math.min(rawDays, 90));

    const records = await academyQuery<Record<string, unknown>>(
      academySlug,
      `SELECT date, time_in, time_out, duration_mins, status
       FROM attendance
       WHERE student_id = $1
         AND date >= CURRENT_DATE - MAKE_INTERVAL(days => $2)
       ORDER BY date DESC`,
      [studentId, days]
    );

    res.json({ success: true, data: records });
  } catch (err) { next(err); }
}
