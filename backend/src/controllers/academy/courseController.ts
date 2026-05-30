import { Request, Response, NextFunction } from 'express';
import { academyQuery, academyQueryOne } from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';

interface CourseRow {
  id: string;
  name: string;
  description: string | null;
  subject: string | null;
  duration_months: number | null;
  default_fee: number;
  schedule: string;
  is_active: boolean;
  created_at: string;
  student_count?: number;
}

// ── GET /api/academy/courses ──────────────────────────────────────────────────

export async function listCourses(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const courses = await academyQuery<CourseRow>(
      academySlug,
      `SELECT c.*,
              COUNT(sc.id) FILTER (WHERE sc.status = 'active') AS student_count
       FROM courses c
       LEFT JOIN student_courses sc ON sc.course_id = c.id
       WHERE c.is_active = TRUE
       GROUP BY c.id
       ORDER BY c.name`
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
    const { name, description, subject, duration_months, default_fee, schedule } =
      req.body as {
        name: string; description?: string; subject?: string;
        duration_months?: number; default_fee?: number;
        schedule?: 'monthly' | 'quarterly' | 'onetime';
      };

    if (!name?.trim()) return next(new AppError('Course name is required', 400));

    const course = await academyQueryOne<CourseRow>(
      academySlug,
      `INSERT INTO courses (name, description, subject, duration_months, default_fee, schedule)
       VALUES ($1,$2,$3,$4,$5,$6)
       RETURNING *`,
      [
        name.trim(),
        description ?? null,
        subject ?? null,
        duration_months ?? null,
        default_fee ?? 0,
        schedule ?? 'monthly',
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
    const { name, description, subject, duration_months, default_fee, schedule } =
      req.body as Partial<CourseRow>;

    const course = await academyQueryOne<CourseRow>(
      academySlug,
      `UPDATE courses
       SET name             = COALESCE($1, name),
           description      = COALESCE($2, description),
           subject          = COALESCE($3, subject),
           duration_months  = COALESCE($4, duration_months),
           default_fee      = COALESCE($5, default_fee),
           schedule         = COALESCE($6, schedule),
           updated_at       = NOW()
       WHERE id = $7 AND is_active = TRUE
       RETURNING *`,
      [name ?? null, description ?? null, subject ?? null,
       duration_months ?? null, default_fee ?? null, schedule ?? null, id]
    );
    if (!course) return next(new AppError('Course not found', 404));
    res.json({ success: true, data: course, message: 'Course updated' });
  } catch (err) { next(err); }
}

// ── DELETE /api/academy/courses/:id ──────────────────────────────────────────

export async function deleteCourse(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;

    // Check no active enrollments
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
