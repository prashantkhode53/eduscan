import { Request, Response, NextFunction } from 'express';
import { academyQuery, academyQueryOne, academyTransaction } from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';
import { batchEmbed, matchFace, cacheUpsert } from '../../utils/insightface';

// ── ID generation ─────────────────────────────────────────────────────────────

async function generateStudentId(slug: string): Promise<string> {
  const row = await academyQueryOne<{ count: string }>(
    slug, `SELECT COUNT(*) FROM students`
  );
  const seq  = (parseInt(row?.count ?? '0') + 1).toString().padStart(5, '0');
  const year = new Date().getFullYear();
  return `ACF-${year}-${seq}`;
}

// ── POST /api/academy/students ────────────────────────────────────────────────

interface CourseSelection { course_id: string; fee_amount: number }

export async function registerStudent(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const {
      first_name, last_name, dob, gender, mobile,
      email, parent_name, parent_mobile, address,
      courses, face_images,
    } = req.body as {
      first_name: string; last_name: string; dob?: string;
      gender?: string; mobile: string; email?: string;
      parent_name?: string; parent_mobile?: string; address?: string;
      courses: CourseSelection[];
      face_images: string[];
    };

    if (!first_name || !last_name || !mobile) {
      return next(new AppError('first_name, last_name, mobile are required', 400));
    }
    if (!courses?.length) {
      return next(new AppError('At least one course must be selected', 400));
    }
    if (!face_images?.length) {
      return next(new AppError('Face images are required for registration', 400));
    }

    // 1 — Generate face embedding via InsightFace
    const embedResult = await batchEmbed(face_images);
    if (!embedResult.success || !embedResult.embedding) {
      return next(new AppError(
        `Face registration failed: ${embedResult.reason ?? 'no face detected'}`, 422
      ));
    }

    // 2 — Duplicate check (confidence >= 0.88 = already registered)
    const matchResult = await matchFace(face_images[0]);
    if (matchResult.matched && (matchResult.confidence ?? 0) >= 0.88) {
      return next(new AppError(
        `Face already registered — ${(matchResult.confidence! * 100).toFixed(1)}% match with existing student.`,
        409
      ));
    }

    // 3 — Validate all course IDs exist in this academy
    const courseIds = courses.map(c => c.course_id);
    const foundCourses = await academyQuery<{ id: string; name: string; default_fee: number }>(
      academySlug,
      `SELECT id, name, default_fee FROM courses
       WHERE id = ANY($1::uuid[]) AND is_active = TRUE`,
      [courseIds]
    );
    if (foundCourses.length !== courseIds.length) {
      return next(new AppError('One or more course IDs are invalid', 400));
    }

    // 4 — Generate student ID + persist in academy schema
    const studentId = await generateStudentId(academySlug);

    await academyTransaction(academySlug, async (client) => {
      await client.query(
        `INSERT INTO students
           (id, first_name, last_name, dob, gender, mobile, email,
            parent_name, parent_mobile, address, face_embedding, face_quality)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
        [
          studentId, first_name.trim(), last_name.trim(),
          dob ?? null, gender ?? null, mobile,
          email ?? null, parent_name ?? null, parent_mobile ?? null,
          address ?? null,
          JSON.stringify(embedResult.embedding),
          embedResult.quality ?? null,
        ]
      );

      // Enrol in each course + generate first fee record
      for (const sel of courses) {
        await client.query(
          `INSERT INTO student_courses (student_id, course_id, fee_amount, start_date)
           VALUES ($1,$2,$3,CURRENT_DATE)`,
          [studentId, sel.course_id, sel.fee_amount]
        );

        const dueDate = new Date();
        dueDate.setDate(1);
        dueDate.setMonth(dueDate.getMonth() + 1);

        await client.query(
          `INSERT INTO fee_records (student_id, course_id, amount_due, due_date, status)
           VALUES ($1,$2,$3,$4,'pending')`,
          [studentId, sel.course_id, sel.fee_amount,
           dueDate.toISOString().split('T')[0]]
        );
      }
    });

    // 5 — Push embedding to InsightFace Redis cache
    await cacheUpsert({
      student_id:  studentId,
      embedding:   embedResult.embedding,
      first_name:  first_name.trim(),
      last_name:   last_name.trim(),
      class_grade: 'academy',
      division:    academySlug.substring(0, 8),
      roll_no:     null,
    });

    res.status(201).json({
      success: true,
      data: { id: studentId, first_name, last_name, courses_enrolled: courses.length },
      message: 'Student registered successfully',
    });
  } catch (err) { next(err); }
}

// ── GET /api/academy/students ─────────────────────────────────────────────────

export async function listStudents(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const {
      search = '', course_id, page = '1', limit = '50', status = 'active'
    } = req.query as Record<string, string>;

    const offset = (parseInt(page) - 1) * parseInt(limit);

    const rows = await academyQuery(
      academySlug,
      `SELECT s.id, s.first_name, s.last_name, s.mobile, s.email,
              s.gender, s.status, s.created_at,
              COALESCE(
                json_agg(
                  json_build_object(
                    'course_id', c.id,
                    'name',      c.name,
                    'fee',       sc.fee_amount,
                    'status',    sc.status
                  )
                ) FILTER (WHERE c.id IS NOT NULL),
                '[]'
              ) AS courses
       FROM students s
       LEFT JOIN student_courses sc ON sc.student_id = s.id
       LEFT JOIN courses c          ON c.id = sc.course_id
       WHERE s.status = $1
         AND ($2 = '' OR s.first_name ILIKE $2 OR s.last_name ILIKE $2
              OR s.id ILIKE $2 OR s.mobile ILIKE $2)
         AND ($3::uuid IS NULL OR sc.course_id = $3::uuid)
       GROUP BY s.id
       ORDER BY s.created_at DESC
       LIMIT $4 OFFSET $5`,
      [
        status,
        search ? `%${search}%` : '',
        course_id || null,
        parseInt(limit),
        offset,
      ]
    );

    const total = await academyQueryOne<{ count: string }>(
      academySlug,
      `SELECT COUNT(DISTINCT s.id) FROM students s
       LEFT JOIN student_courses sc ON sc.student_id = s.id
       WHERE s.status = $1
         AND ($2 = '' OR s.first_name ILIKE $2 OR s.last_name ILIKE $2
              OR s.id ILIKE $2 OR s.mobile ILIKE $2)
         AND ($3::uuid IS NULL OR sc.course_id = $3::uuid)`,
      [status, search ? `%${search}%` : '', course_id || null]
    );

    res.json({
      success: true,
      data: {
        students: rows,
        total: parseInt(total?.count ?? '0'),
        page: parseInt(page),
        limit: parseInt(limit),
      },
    });
  } catch (err) { next(err); }
}

// ── GET /api/academy/students/:id ─────────────────────────────────────────────

export async function getStudent(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;

    const student = await academyQueryOne(
      academySlug,
      `SELECT s.*,
              COALESCE(
                json_agg(
                  json_build_object(
                    'course_id',   c.id,
                    'name',        c.name,
                    'subject',     c.subject,
                    'fee_amount',  sc.fee_amount,
                    'start_date',  sc.start_date,
                    'status',      sc.status
                  )
                ) FILTER (WHERE c.id IS NOT NULL),
                '[]'
              ) AS courses
       FROM students s
       LEFT JOIN student_courses sc ON sc.student_id = s.id
       LEFT JOIN courses c          ON c.id = sc.course_id
       WHERE s.id = $1
       GROUP BY s.id`,
      [id]
    );
    if (!student) return next(new AppError('Student not found', 404));
    res.json({ success: true, data: student });
  } catch (err) { next(err); }
}

// ── GET /api/academy/stats ────────────────────────────────────────────────────

export async function getStats(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const today = new Date().toISOString().split('T')[0];

    const [students, courses, presentToday, feesDue] = await Promise.all([
      academyQueryOne<{ count: string }>(
        academySlug, `SELECT COUNT(*) FROM students WHERE status='active'`
      ),
      academyQueryOne<{ count: string }>(
        academySlug, `SELECT COUNT(*) FROM courses WHERE is_active=TRUE`
      ),
      academyQueryOne<{ count: string }>(
        academySlug,
        `SELECT COUNT(*) FROM attendance WHERE date=$1 AND status IN ('present','late')`,
        [today]
      ),
      academyQueryOne<{ count: string }>(
        academySlug,
        `SELECT COUNT(*) FROM fee_records WHERE status IN ('pending','overdue') AND due_date<=$1`,
        [today]
      ),
    ]);

    res.json({
      success: true,
      data: {
        total_students:  parseInt(students?.count  ?? '0'),
        total_courses:   parseInt(courses?.count   ?? '0'),
        present_today:   parseInt(presentToday?.count ?? '0'),
        fees_due:        parseInt(feesDue?.count   ?? '0'),
      },
    });
  } catch (err) { next(err); }
}
