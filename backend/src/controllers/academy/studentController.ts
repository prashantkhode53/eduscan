import { Request, Response, NextFunction } from 'express';
import { academyQuery, academyQueryOne, academyTransaction, academyExec } from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';
import { batchEmbed, matchFace, cacheUpsert, cacheDelete } from '../../utils/insightface';

// ── ID generation ─────────────────────────────────────────────────────────────

async function generateStudentId(slug: string): Promise<string> {
  const year   = new Date().getFullYear();
  const prefix = `ACF-${year}-`;
  // Use MAX over the numeric suffix of existing IDs, not COUNT. COUNT causes
  // primary-key collisions when there are gaps (e.g. orphaned face-less
  // students from abandoned two-phase registrations).
  const row = await academyQueryOne<{ max_seq: string | null }>(
    slug,
    `SELECT MAX(
       CAST(SUBSTRING(id FROM LENGTH($1) + 1) AS INTEGER)
     ) AS max_seq
     FROM students
     WHERE id LIKE $2`,
    [prefix, `${prefix}%`]
  );
  const seq = ((parseInt(row?.max_seq ?? '0') || 0) + 1)
    .toString().padStart(5, '0');
  return `${prefix}${seq}`;
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

    // Remove any orphaned face-less students for this mobile number created by
    // previous abandoned two-phase registrations. They have no face_embedding,
    // so they cannot be recognised — removing them before inserting the new
    // record prevents duplicate-mobile confusion and cleans up the DB.
    await academyExec(
      academySlug,
      `DELETE FROM students
       WHERE mobile = $1 AND face_embedding IS NULL`,
      [mobile]
    );

    // Face is OPTIONAL here. The registration UI saves the student's details
    // first (so they're never lost if the scan or InsightFace service fails)
    // and attaches the face in a second step via PATCH /:id/face. A one-shot
    // create that includes face_images still behaves exactly as before.
    let embedding: number[] | null = null;
    let quality:   number | null   = null;
    if (face_images?.length) {
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

      embedding = embedResult.embedding;
      quality   = embedResult.quality ?? null;
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

    // First fee is due at the end of the current month. This matches
    // updateStudent's fee logic so a two-phase save (details now, edits on a
    // back-navigation) never produces duplicate fee records for the same month.
    const month   = new Date().toISOString().substring(0, 7);
    const dueDate = new Date(
      new Date().getFullYear(), new Date().getMonth() + 1, 0
    ).toISOString().split('T')[0];

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
          embedding ? JSON.stringify(embedding) : null,
          quality,
        ]
      );

      // Enrol in each course + generate first fee record (idempotent)
      for (const sel of courses) {
        await client.query(
          `INSERT INTO student_courses (student_id, course_id, fee_amount, start_date)
           VALUES ($1,$2,$3,CURRENT_DATE)
           ON CONFLICT (student_id, course_id) DO NOTHING`,
          [studentId, sel.course_id, sel.fee_amount]
        );

        await client.query(
          `INSERT INTO fee_records (student_id, course_id, amount_due, due_date, status)
           SELECT $1::varchar, $2::uuid, $3::numeric, $4::date, 'pending'
           WHERE NOT EXISTS (
             SELECT 1 FROM fee_records fr
             WHERE fr.student_id = $1
               AND fr.course_id  = $2
               AND TO_CHAR(fr.due_date, 'YYYY-MM') = $5::text
           )`,
          [studentId, sel.course_id, sel.fee_amount, dueDate, month]
        );
      }
    });

    // 5 — Push embedding to InsightFace Redis cache (only when a face was given)
    if (embedding) {
      await cacheUpsert({
        student_id:  studentId,
        embedding,
        first_name:  first_name.trim(),
        last_name:   last_name.trim(),
        class_grade: 'academy',
        division:    academySlug.substring(0, 8),
        roll_no:     null,
      });
    }

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

// ── PATCH /api/academy/students/:id ──────────────────────────────────────────
// Atomically updates course enrolments and (optionally) face embedding.
// courses  — full replacement list; old active enrolments are dropped first.
// face_images — optional; if omitted, existing face data is kept unchanged.

export async function updateStudent(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;
    const {
      courses, face_images,
      first_name, last_name, mobile, email,
      dob, gender, parent_name, parent_mobile, address,
    } = req.body as {
      courses: CourseSelection[];
      face_images?: string[];
      first_name?: string; last_name?: string; mobile?: string;
      email?: string; dob?: string; gender?: string;
      parent_name?: string; parent_mobile?: string; address?: string;
    };

    if (!courses?.length) {
      return next(new AppError('At least one course is required', 400));
    }

    const student = await academyQueryOne<{
      id: string; first_name: string; last_name: string;
    }>(academySlug, `SELECT id, first_name, last_name FROM students WHERE id = $1`, [id]);
    if (!student) return next(new AppError('Student not found', 404));

    const courseIds = courses.map(c => c.course_id);
    const foundCourses = await academyQuery<{ id: string }>(
      academySlug,
      `SELECT id FROM courses WHERE id = ANY($1::uuid[]) AND is_active = TRUE`,
      [courseIds]
    );
    if (foundCourses.length !== courseIds.length) {
      return next(new AppError('One or more course IDs are invalid', 400));
    }

    let newEmbedding: number[] | null = null;
    let newQuality:   number | null   = null;

    if (face_images?.length) {
      const embed = await batchEmbed(face_images);
      if (!embed.success || !embed.embedding) {
        return next(new AppError(
          `Face update failed: ${embed.reason ?? 'no face detected'}`, 422
        ));
      }
      newEmbedding = embed.embedding;
      newQuality   = embed.quality ?? null;
    }

    await academyTransaction(academySlug, async (client) => {
      await client.query(
        `UPDATE student_courses
         SET status = 'dropped', end_date = CURRENT_DATE
         WHERE student_id = $1 AND status = 'active'`,
        [id]
      );

      const month   = new Date().toISOString().substring(0, 7);
      const dueDate = new Date(
        new Date().getFullYear(),
        new Date().getMonth() + 1,
        0
      ).toISOString().split('T')[0];

      for (const sel of courses) {
        await client.query(
          `INSERT INTO student_courses (student_id, course_id, fee_amount, start_date, status)
           VALUES ($1, $2, $3, CURRENT_DATE, 'active')
           ON CONFLICT (student_id, course_id)
           DO UPDATE SET fee_amount = $3, status = 'active', end_date = NULL`,
          [id, sel.course_id, sel.fee_amount]
        );

        await client.query(
          // Explicit casts on the SELECT-list params are required: in an
          // INSERT ... SELECT (unlike INSERT ... VALUES) Postgres does not take
          // the parameter types from the target columns, and because $1/$2 are
          // also used in the WHERE NOT EXISTS it otherwise fails with
          // "inconsistent types deduced for parameter $1".
          `INSERT INTO fee_records (student_id, course_id, amount_due, due_date, status)
           SELECT $1::varchar, $2::uuid, $3::numeric, $4::date, 'pending'
           WHERE NOT EXISTS (
             SELECT 1 FROM fee_records fr
             WHERE fr.student_id = $1
               AND fr.course_id  = $2
               AND TO_CHAR(fr.due_date, 'YYYY-MM') = $5::text
           )`,
          [id, sel.course_id, sel.fee_amount, dueDate, month]
        );
      }

      // Update personal info fields when provided
      if (first_name || last_name || mobile) {
        await client.query(
          `UPDATE students SET
             first_name    = COALESCE($1, first_name),
             last_name     = COALESCE($2, last_name),
             mobile        = COALESCE($3, mobile),
             email         = $4,
             dob           = $5,
             gender        = $6,
             parent_name   = $7,
             parent_mobile = $8,
             address       = $9,
             updated_at    = NOW()
           WHERE id = $10`,
          [
            first_name?.trim()    || null,
            last_name?.trim()     || null,
            mobile?.trim()        || null,
            email?.trim()         || null,
            dob                   || null,
            gender                || null,
            parent_name?.trim()   || null,
            parent_mobile?.trim() || null,
            address?.trim()       || null,
            id,
          ]
        );
      }

      if (newEmbedding) {
        await client.query(
          `UPDATE students
           SET face_embedding = $1, face_quality = $2, updated_at = NOW()
           WHERE id = $3`,
          [JSON.stringify(newEmbedding), newQuality, id]
        );
      }

      if (!first_name && !last_name && !mobile && !newEmbedding) {
        await client.query(`UPDATE students SET updated_at = NOW() WHERE id = $1`, [id]);
      }
    });

    if (newEmbedding) {
      await cacheUpsert({
        student_id:  id,
        embedding:   newEmbedding,
        first_name:  first_name?.trim() || student.first_name,
        last_name:   last_name?.trim()  || student.last_name,
        class_grade: 'academy',
        division:    academySlug.substring(0, 8),
        roll_no:     null,
      });
    }

    res.json({ success: true, message: 'Student updated successfully' });
  } catch (err) { next(err); }
}

// ── PATCH /api/academy/students/:id/face ──────────────────────────────────────
// Phase 2 of registration (and re-capture): attaches/updates ONLY the face
// embedding for an existing student — no enrolment or fee side-effects. Lets
// the UI persist the student's details before the scan and the face after.

export async function updateStudentFace(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;
    const { face_images } = req.body as { face_images: string[] };

    if (!face_images?.length) {
      return next(new AppError('face_images are required', 400));
    }

    const student = await academyQueryOne<{
      id: string; first_name: string; last_name: string;
    }>(academySlug, `SELECT id, first_name, last_name FROM students WHERE id = $1`, [id]);
    if (!student) return next(new AppError('Student not found', 404));

    const embed = await batchEmbed(face_images);
    if (!embed.success || !embed.embedding) {
      return next(new AppError(
        `Face capture failed: ${embed.reason ?? 'no face detected'}`, 422
      ));
    }

    // Duplicate check — a high-confidence match to a DIFFERENT student means
    // this face is already registered to someone else.
    const match = await matchFace(face_images[0]);
    if (match.matched && match.student_id && match.student_id !== id &&
        (match.confidence ?? 0) >= 0.88) {
      return next(new AppError(
        `Face already registered to another student — ${(match.confidence! * 100).toFixed(1)}% match.`,
        409
      ));
    }

    await academyExec(
      academySlug,
      `UPDATE students SET face_embedding = $1, face_quality = $2, updated_at = NOW()
       WHERE id = $3`,
      [JSON.stringify(embed.embedding), embed.quality ?? null, id]
    );

    await cacheUpsert({
      student_id:  id,
      embedding:   embed.embedding,
      first_name:  student.first_name,
      last_name:   student.last_name,
      class_grade: 'academy',
      division:    academySlug.substring(0, 8),
      roll_no:     null,
    });

    res.json({ success: true, message: 'Face saved successfully' });
  } catch (err) { next(err); }
}

// ── DELETE /api/academy/students/:id ──────────────────────────────────────────
// Permanently removes a student. student_courses, fee_records and attendance
// rows are removed automatically via ON DELETE CASCADE, and the student's face
// embedding is purged from the InsightFace cache so they can't be matched again.

export async function deleteStudent(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;

    const student = await academyQueryOne<{ id: string }>(
      academySlug, `SELECT id FROM students WHERE id = $1`, [id]
    );
    if (!student) return next(new AppError('Student not found', 404));

    await academyExec(academySlug, `DELETE FROM students WHERE id = $1`, [id]);

    // Best-effort cache purge — the DB is the source of truth, so a cache
    // failure (e.g. InsightFace service down) must not fail the delete; the
    // stale entry is cleaned up on the next cache reconcile/reload.
    try {
      await cacheDelete(id);
    } catch (err) {
      console.error(
        `[deleteStudent] cache delete failed for ${id}:`,
        err instanceof Error ? err.message : err
      );
    }

    res.json({ success: true, message: 'Student deleted successfully' });
  } catch (err) { next(err); }
}
