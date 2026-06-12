import { Request, Response, NextFunction } from 'express';
import { academyQuery, academyQueryOne, academyExec, academyTransaction } from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';

interface CourseRow {
  id: string;
  academic_year_id: string | null;
  academic_year_name: string | null;
  name: string;
  description: string | null;
  subject: string | null;
  duration_months: number | null;
  default_fee: number;
  schedule: string;
  fee_due_day: number | null;
  fee_due_date: string | null;
  is_active: boolean;
  created_at: string;
  student_count?: number;
  subject_count?: number;
  total_subject_fee?: number;
}

// ── GET /api/academy/courses ──────────────────────────────────────────────────

export async function listCourses(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { academic_year_id } = req.query as Record<string, string>;

    const courses = await academyQuery<CourseRow>(
      academySlug,
      `SELECT c.*,
              ay.academic_year_name,
              (SELECT COUNT(*) FROM student_courses sc
               WHERE sc.course_id = c.id AND sc.status = 'active')  AS student_count,
              (SELECT COUNT(*) FROM subjects sub
               WHERE sub.course_id = c.id AND sub.is_active = TRUE)  AS subject_count,
              (SELECT COALESCE(SUM(sub.default_fee), 0) FROM subjects sub
               WHERE sub.course_id = c.id AND sub.is_active = TRUE)  AS total_subject_fee
       FROM courses c
       LEFT JOIN academic_years ay ON ay.id = c.academic_year_id
       WHERE c.is_active = TRUE
         AND ($1::uuid IS NULL OR c.academic_year_id = $1::uuid)
       ORDER BY c.name`,
      [academic_year_id || null]
    );
    res.json({ success: true, data: courses });
  } catch (err) { next(err); }
}

// ── POST /api/academy/courses ─────────────────────────────────────────────────

export async function createCourse(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const {
      academic_year_id, name, description, subject,
      duration_months, default_fee, schedule, fee_due_day, fee_due_date,
    } = req.body as {
      academic_year_id?: string; name: string; description?: string;
      subject?: string; duration_months?: number; default_fee?: number;
      schedule?: 'monthly' | 'quarterly' | 'onetime';
      fee_due_day?: number | null; fee_due_date?: string | null;
    };

    if (!name?.trim()) return next(new AppError('Course name is required', 400));

    const course = await academyQueryOne<CourseRow>(
      academySlug,
      `INSERT INTO courses (academic_year_id, name, description, subject, duration_months, default_fee, schedule, fee_due_day, fee_due_date)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
       RETURNING *`,
      [
        academic_year_id ?? null,
        name.trim(),
        description ?? null,
        subject ?? null,
        duration_months ?? null,
        default_fee ?? 0,
        schedule ?? 'monthly',
        fee_due_day ?? null,
        fee_due_date ?? null,
      ]
    );
    res.status(201).json({ success: true, data: course, message: 'Course created' });
  } catch (err) { next(err); }
}

// ── PUT /api/academy/courses/:id ──────────────────────────────────────────────

export async function updateCourse(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;
    const {
      academic_year_id, name, description, subject,
      duration_months, default_fee, schedule, fee_due_day, fee_due_date,
      update_pending_fees,
    } = req.body as Partial<CourseRow> & {
      academic_year_id?: string | null;
      fee_due_day?: number | null;
      fee_due_date?: string | null;
      update_pending_fees?: boolean;
    };

    const feeDueDayInBody  = 'fee_due_day'  in req.body;
    const feeDueDateInBody = 'fee_due_date' in req.body;

    let course: CourseRow | null = null;

    await academyTransaction(academySlug, async (client) => {
      course = await client.query<CourseRow>(
        `UPDATE courses
         SET academic_year_id = CASE WHEN $1::boolean THEN $2::uuid   ELSE academic_year_id END,
             name             = COALESCE($3, name),
             description      = COALESCE($4, description),
             subject          = COALESCE($5, subject),
             duration_months  = COALESCE($6, duration_months),
             default_fee      = COALESCE($7, default_fee),
             schedule         = COALESCE($8, schedule),
             fee_due_day      = CASE WHEN $10::boolean THEN $11::int  ELSE fee_due_day  END,
             fee_due_date     = CASE WHEN $12::boolean THEN $13::date ELSE fee_due_date END,
             updated_at       = NOW()
         WHERE id = $9 AND is_active = TRUE
         RETURNING *`,
        [
          'academic_year_id' in req.body,
          academic_year_id ?? null,
          name ?? null, description ?? null, subject ?? null,
          duration_months ?? null, default_fee ?? null, schedule ?? null,
          id,
          feeDueDayInBody,
          fee_due_day ?? null,
          feeDueDateInBody,
          fee_due_date ?? null,
        ]
      ).then(r => r.rows[0] ?? null);

      if (!course) return;

      // If requested, bulk-update due_date on pending/overdue course-level fee records.
      // Derive effective day-of-month: prefer fee_due_date, fall back to fee_due_day.
      if (update_pending_fees && (feeDueDayInBody || feeDueDateInBody)) {
        const effectiveDueDay = feeDueDateInBody
          ? (fee_due_date ? new Date(fee_due_date).getDate() : null)
          : (fee_due_day ?? null);
        await client.query(
          `UPDATE fee_records
           SET due_date   = CASE
             WHEN $1::int IS NOT NULL
             THEN (DATE_TRUNC('month', due_date) + ($1::int - 1) * INTERVAL '1 day')::date
             ELSE (DATE_TRUNC('month', due_date) + INTERVAL '1 month - 1 day')::date
           END,
           updated_at = NOW()
           WHERE course_id = $2 AND subject_id IS NULL AND status IN ('pending', 'overdue')`,
          [effectiveDueDay, id]
        );
      }
    });

    if (!course) return next(new AppError('Course not found', 404));
    res.json({ success: true, data: course, message: 'Course updated' });
  } catch (err) { next(err); }
}

// ── GET /api/academy/courses/:courseId/subjects ───────────────────────────────

interface SubjectRow {
  id: string;
  course_id: string;
  name: string;
  default_fee: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export async function listSubjects(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { courseId } = req.params;
    const subjects = await academyQuery<SubjectRow>(
      academySlug,
      `SELECT * FROM subjects
       WHERE course_id = $1 AND is_active = TRUE
       ORDER BY name`,
      [courseId]
    );
    res.json({ success: true, data: subjects });
  } catch (err) { next(err); }
}

// ── POST /api/academy/courses/:courseId/subjects ──────────────────────────────

export async function createSubject(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { courseId } = req.params;
    const { name, default_fee } = req.body as { name: string; default_fee?: number };
    if (!name?.trim()) return next(new AppError('Subject name is required', 400));

    const dup = await academyQueryOne<{ id: string }>(
      academySlug,
      `SELECT id FROM subjects WHERE course_id = $1 AND LOWER(name) = LOWER($2) AND is_active = TRUE`,
      [courseId, name.trim()]
    );
    if (dup) return next(new AppError(`Subject "${name.trim()}" already exists in this course`, 409));

    const subject = await academyQueryOne<SubjectRow>(
      academySlug,
      `INSERT INTO subjects (course_id, name, default_fee)
       VALUES ($1, $2, $3)
       RETURNING *`,
      [courseId, name.trim(), default_fee ?? 0]
    );
    res.status(201).json({ success: true, data: subject, message: 'Subject created' });
  } catch (err) { next(err); }
}

// ── PUT /api/academy/subjects/:subjectId ──────────────────────────────────────

export async function updateSubject(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { subjectId } = req.params;
    const { name, default_fee } = req.body as { name?: string; default_fee?: number };

    if (name?.trim()) {
      const dup = await academyQueryOne<{ id: string }>(
        academySlug,
        `SELECT id FROM subjects
         WHERE course_id = (SELECT course_id FROM subjects WHERE id = $1)
           AND LOWER(name) = LOWER($2)
           AND is_active   = TRUE
           AND id         != $1`,
        [subjectId, name.trim()]
      );
      if (dup) return next(new AppError(`Subject "${name.trim()}" already exists in this course`, 409));
    }

    const subject = await academyQueryOne<SubjectRow>(
      academySlug,
      `UPDATE subjects
       SET name        = COALESCE($1, name),
           default_fee = COALESCE($2, default_fee),
           updated_at  = NOW()
       WHERE id = $3 AND is_active = TRUE
       RETURNING *`,
      [name?.trim() ?? null, default_fee ?? null, subjectId]
    );
    if (!subject) return next(new AppError('Subject not found', 404));
    res.json({ success: true, data: subject, message: 'Subject updated' });
  } catch (err) { next(err); }
}

// ── DELETE /api/academy/subjects/:subjectId ───────────────────────────────────

export async function deleteSubject(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { subjectId } = req.params;

    const active = await academyQueryOne<{ count: string }>(
      academySlug,
      `SELECT COUNT(*) FROM student_subjects WHERE subject_id = $1 AND status = 'active'`,
      [subjectId]
    );
    if (active && parseInt(active.count) > 0) {
      return next(new AppError('Cannot delete subject with active student enrollments', 409));
    }

    await academyQuery(
      academySlug,
      `UPDATE subjects SET is_active = FALSE, updated_at = NOW() WHERE id = $1`,
      [subjectId]
    );
    res.json({ success: true, message: 'Subject deleted' });
  } catch (err) { next(err); }
}

// ── DELETE /api/academy/courses/:id ──────────────────────────────────────────

export async function deleteCourse(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;

    const active = await academyQueryOne<{ count: string }>(
      academySlug,
      `SELECT COUNT(*) FROM student_courses WHERE course_id=$1 AND status='active'`,
      [id]
    );
    if (active && parseInt(active.count) > 0) {
      return next(new AppError('Cannot delete course with active student enrollments', 409));
    }

    await academyQuery(
      academySlug,
      `UPDATE courses SET is_active=FALSE, updated_at=NOW() WHERE id=$1`,
      [id]
    );
    res.json({ success: true, message: 'Course deleted' });
  } catch (err) { next(err); }
}
