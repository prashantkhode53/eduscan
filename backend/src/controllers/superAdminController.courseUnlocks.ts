/**
 * Super-admin course fee unlocks.
 *
 * A student's subject fees are frozen the moment they are first assigned —
 * `updateStudent`'s upsert deliberately does not touch `fee_amount`, and the
 * app renders the fee as a read-only badge. That is the correct default: fees
 * feed receipts and collection, so an academy admin must not be able to rewrite
 * history on a whim.
 *
 * This module is the escape hatch. A super admin opens a specific (student,
 * course) pair, which lets the academy admin edit that course's subject fees
 * for that one student. The grant persists until a super admin re-locks it.
 *
 * The unlock is stored per student AND per course: unlocking a course for
 * Rohan never touches Priya, and never touches Rohan's other courses.
 *
 * All reads/writes go through poolManager (`SET LOCAL search_path` inside a
 * transaction) — never the raw pool, never a session-level search_path.
 */

import { Request, Response, NextFunction } from 'express';
import { sharedPool, academyQuery, academyQueryOne } from '../db/poolManager';
import { AppError } from '../middleware/errorHandler';

/** Cap on one unlock/re-lock request, so a malformed client can't submit unbounded arrays. */
const MAX_STUDENTS_PER_REQUEST = 500;

/** 404s unless the slug names a real academy. Returns its display name for audit lines. */
async function requireAcademy(slug: string): Promise<string> {
  const { rows } = await sharedPool.query<{ name: string }>(
    `SELECT name FROM academies WHERE slug = $1`, [slug]
  );
  if (!rows.length) throw new AppError('Academy not found', 404);
  return rows[0].name;
}

async function auditLog(
  adminId: string, action: string, targetSlug: string, details: string
): Promise<void> {
  try {
    await sharedPool.query(
      `INSERT INTO super_admin_audit_log (admin_id, action, target_slug, details)
       VALUES ($1, $2, $3, $4)`,
      [adminId, action, targetSlug, details]
    );
  } catch { /* non-fatal — never let logging break an action */ }
}

/**
 * Validate a student_ids payload into a deduped, non-empty list.
 * students.id is VARCHAR(20) (e.g. ACF-2026-00001), never a uuid — do not cast.
 */
function cleanStudentIds(raw: unknown): string[] {
  if (!Array.isArray(raw)) {
    throw new AppError('student_ids must be an array', 400);
  }
  const ids = [...new Set(
    raw.filter((v): v is string => typeof v === 'string' && v.trim() !== '')
       .map((v) => v.trim())
  )];
  if (!ids.length) throw new AppError('Select at least one student', 400);
  if (ids.length > MAX_STUDENTS_PER_REQUEST) {
    throw new AppError(`Too many students in one request (max ${MAX_STUDENTS_PER_REQUEST})`, 400);
  }
  return ids;
}

// ── GET /api/super-admin/academies/:slug/academic-years ───────────────────────

export async function listAcademyYears(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    await requireAcademy(slug);

    const years = await academyQuery(
      slug,
      `SELECT id, academic_year_name, start_date, end_date, is_current_year, status
       FROM academic_years
       ORDER BY start_date DESC`
    );

    res.json({ success: true, data: years });
  } catch (err) { next(err); }
}

// ── GET /api/super-admin/academies/:slug/courses?academic_year_id= ────────────

export async function listAcademyCourses(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const yearId = (req.query['academic_year_id'] as string | undefined)?.trim() || null;
    await requireAcademy(slug);

    const params: unknown[] = [];
    let filter = '';
    if (yearId) {
      params.push(yearId);
      filter = `AND c.academic_year_id = $${params.length}`;
    }

    const courses = await academyQuery(
      slug,
      `SELECT c.id, c.name, c.default_fee,
              (SELECT COUNT(*) FROM subjects s
                WHERE s.course_id = c.id AND s.is_active = TRUE)::int AS subject_count
       FROM courses c
       WHERE c.is_active = TRUE ${filter}
       ORDER BY c.name`,
      params
    );

    res.json({ success: true, data: courses });
  } catch (err) { next(err); }
}

// ── GET /api/super-admin/academies/:slug/courses/:courseId/students ───────────

interface UnlockRosterRow {
  id: string;
  name: string;
  subject_count: number;
  total_fee: string | null;
  is_unlocked: boolean;
  unlocked_at: Date | null;
  unlocked_by: string | null;
}

/**
 * The course's active roster, each student flagged with whether their subject
 * fees have actually been assigned yet (`has_fees`) and whether the course is
 * currently unlocked for them.
 *
 * A student with no assigned subject fees has nothing to unlock — the app still
 * lists them, greyed out, so the super admin can see the whole roster rather
 * than wondering why someone is missing.
 */
export async function listCourseUnlockRoster(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug, courseId } = req.params;
    await requireAcademy(slug);

    const course = await academyQueryOne<{ id: string; name: string }>(
      slug, `SELECT id, name FROM courses WHERE id = $1`, [courseId]
    );
    if (!course) return next(new AppError('Course not found', 404));

    const rows = await academyQuery<UnlockRosterRow>(
      slug,
      `SELECT s.id,
              TRIM(s.first_name || ' ' || s.last_name) AS name,
              (SELECT COUNT(*)
                 FROM student_subjects ss
                 JOIN subjects sub ON sub.id = ss.subject_id
                WHERE ss.student_id = s.id
                  AND sub.course_id = $1
                  AND ss.status = 'active')::int          AS subject_count,
              (SELECT SUM(ss.fee_amount)
                 FROM student_subjects ss
                 JOIN subjects sub ON sub.id = ss.subject_id
                WHERE ss.student_id = s.id
                  AND sub.course_id = $1
                  AND ss.status = 'active')               AS total_fee,
              (u.student_id IS NOT NULL)                  AS is_unlocked,
              u.unlocked_at,
              u.unlocked_by
       FROM students s
       JOIN student_courses sc
         ON sc.student_id = s.id AND sc.course_id = $1 AND sc.status = 'active'
       LEFT JOIN course_fee_unlocks u
         ON u.student_id = s.id AND u.course_id = $1
       WHERE s.status = 'active'
       ORDER BY s.first_name, s.last_name, s.id`,
      [courseId]
    );

    const students = rows.map((r) => ({
      id:            r.id,
      name:          r.name,
      subject_count: r.subject_count,
      total_fee:     r.total_fee === null ? 0 : Number(r.total_fee),
      has_fees:      r.subject_count > 0,
      is_unlocked:   r.is_unlocked,
      unlocked_at:   r.unlocked_at,
      unlocked_by:   r.unlocked_by,
    }));

    res.json({
      success: true,
      data: {
        course:   { id: course.id, name: course.name },
        students,
        count:    students.length,
        unlocked: students.filter((s) => s.is_unlocked).length,
      },
    });
  } catch (err) { next(err); }
}

// ── POST /api/super-admin/academies/:slug/course-unlocks ──────────────────────

/**
 * Unlock one course for a set of students. Idempotent: re-unlocking an already
 * unlocked pair refreshes who granted it and when, rather than erroring.
 *
 * Only students on the course's ACTIVE roster are written — a stale student_id
 * from a client that missed a roster change is reported back as skipped rather
 * than silently creating an orphan grant.
 */
export async function unlockCourseFees(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { course_id, student_ids } = req.body as {
      course_id?: string; student_ids?: unknown;
    };

    if (!course_id || typeof course_id !== 'string') {
      return next(new AppError('course_id is required', 400));
    }
    const ids = cleanStudentIds(student_ids);
    const academyName = await requireAcademy(slug);

    const course = await academyQueryOne<{ id: string; name: string }>(
      slug, `SELECT id, name FROM courses WHERE id = $1`, [course_id]
    );
    if (!course) return next(new AppError('Course not found', 404));

    const grantedBy = req.admin?.username ?? req.admin?.id ?? 'superadmin';

    // Restrict to the course's active roster. The SELECT … WHERE feeding the
    // INSERT is what enforces it, so a bad id can never produce a row.
    const inserted = await academyQuery<{ student_id: string }>(
      slug,
      `INSERT INTO course_fee_unlocks (student_id, course_id, unlocked_by)
       SELECT s.id, $1, $3
         FROM students s
         JOIN student_courses sc
           ON sc.student_id = s.id AND sc.course_id = $1 AND sc.status = 'active'
        WHERE s.id = ANY($2::varchar[])
          AND s.status = 'active'
       ON CONFLICT (student_id, course_id) DO UPDATE
         SET unlocked_at = NOW(), unlocked_by = EXCLUDED.unlocked_by
       RETURNING student_id`,
      [course_id, ids, grantedBy]
    );

    const unlockedIds = inserted.map((r) => r.student_id);
    const skipped     = ids.filter((id) => !unlockedIds.includes(id));

    if (!unlockedIds.length) {
      return next(new AppError(
        'None of the selected students are on this course\'s active roster', 400
      ));
    }

    await auditLog(
      req.admin!.id, 'UNLOCK_COURSE_FEES', slug,
      `Unlocked course "${course.name}" fee editing for ${unlockedIds.length} student(s) ` +
      `at ${academyName}: ${unlockedIds.join(', ')}`
    );

    res.json({
      success: true,
      data: { course_id, unlocked: unlockedIds, skipped },
      message: `Unlocked ${unlockedIds.length} student(s) for ${course.name}`,
    });
  } catch (err) { next(err); }
}

// ── DELETE /api/super-admin/academies/:slug/course-unlocks ────────────────────

/**
 * Re-lock a course for a set of students, dropping the grants. Fees already
 * changed while unlocked stay as they are — this closes the door, it does not
 * roll anything back.
 */
export async function relockCourseFees(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { course_id, student_ids } = req.body as {
      course_id?: string; student_ids?: unknown;
    };

    if (!course_id || typeof course_id !== 'string') {
      return next(new AppError('course_id is required', 400));
    }
    const ids = cleanStudentIds(student_ids);
    const academyName = await requireAcademy(slug);

    const course = await academyQueryOne<{ id: string; name: string }>(
      slug, `SELECT id, name FROM courses WHERE id = $1`, [course_id]
    );
    if (!course) return next(new AppError('Course not found', 404));

    const removed = await academyQuery<{ student_id: string }>(
      slug,
      `DELETE FROM course_fee_unlocks
        WHERE course_id = $1 AND student_id = ANY($2::varchar[])
       RETURNING student_id`,
      [course_id, ids]
    );

    const relockedIds = removed.map((r) => r.student_id);

    await auditLog(
      req.admin!.id, 'RELOCK_COURSE_FEES', slug,
      `Re-locked course "${course.name}" fee editing for ${relockedIds.length} student(s) ` +
      `at ${academyName}: ${relockedIds.join(', ')}`
    );

    res.json({
      success: true,
      data: { course_id, relocked: relockedIds },
      message: `Re-locked ${relockedIds.length} student(s) for ${course.name}`,
    });
  } catch (err) { next(err); }
}
