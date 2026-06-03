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
        // Look up the matched student so the client can show a useful warning.
        const dup = matchResult.student_id
          ? await academyQueryOne<{
              id: string; first_name: string; last_name: string;
              created_at: string; course_names: string[];
            }>(
              academySlug,
              `SELECT s.id, s.first_name, s.last_name, s.created_at,
                      COALESCE(
                        json_agg(c.name ORDER BY c.name)
                        FILTER (WHERE c.id IS NOT NULL), '[]'
                      ) AS course_names
               FROM students s
               LEFT JOIN student_courses sc
                 ON sc.student_id = s.id AND sc.status = 'active'
               LEFT JOIN courses c ON c.id = sc.course_id
               WHERE s.id = $1
               GROUP BY s.id`,
              [matchResult.student_id]
            )
          : null;

        return next(new AppError(
          `Face already registered — ${(matchResult.confidence! * 100).toFixed(1)}% match with an existing student.`,
          409,
          {
            code: 'FACE_DUPLICATE',
            duplicate: {
              student_id:    dup?.id    ?? matchResult.student_id ?? null,
              student_name:  dup ? `${dup.first_name} ${dup.last_name}` : null,
              courses:       dup?.course_names ?? [],
              registered_at: dup?.created_at  ?? null,
              confidence:    matchResult.confidence,
            },
          }
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

// ── POST /api/academy/students/bulk-upload ────────────────────────────────────
// Accepts a pre-parsed array of student objects from the Flutter client
// (Flutter does Excel/CSV parsing and client-side validation; the server
// does a final validation pass plus DB-duplicate detection and bulk insert).

interface BulkStudent {
  first_name: string; last_name: string; gender?: string; dob: string;
  mobile: string; email?: string; parent_name?: string;
  parent_mobile?: string; address?: string;
  courses?: string; // comma-separated course names from the upload file
}

function normalizeDob(raw: string): string | null {
  const t = raw.trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(t)) return t;
  if (/^\d{2}\/\d{2}\/\d{4}$/.test(t)) {
    const [d, m, y] = t.split('/');
    return `${y}-${m}-${d}`;
  }
  return null;
}

export async function bulkUploadStudents(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { students, academic_year_id: requestedYearId } =
      req.body as { students: BulkStudent[]; academic_year_id?: string };

    if (!Array.isArray(students) || !students.length) {
      return next(new AppError('No student records provided', 400));
    }
    if (students.length > 1000) {
      return next(new AppError('Maximum 1000 students per upload', 400));
    }

    // Fetch all active students once for in-memory duplicate detection.
    const existing = await academyQuery<{
      id: string; first_name: string; last_name: string; dob: string;
    }>(
      academySlug,
      `SELECT id, first_name, last_name, TO_CHAR(dob, 'YYYY-MM-DD') AS dob
       FROM students WHERE status = 'active'`,
      []
    );
    const existingKeys = new Map<string, string>(); // key → student_id
    for (const s of existing) {
      const k = `${s.first_name.trim().toLowerCase()}|${s.last_name.trim().toLowerCase()}|${s.dob}`;
      existingKeys.set(k, s.id);
    }

    // Resolve which academic year's courses to match against.
    // Priority: year supplied in request body → current year → all active courses.
    let resolvedYearId: string | null = requestedYearId ?? null;
    if (!resolvedYearId) {
      const currentYear = await academyQueryOne<{ id: string }>(
        academySlug,
        `SELECT id FROM academic_years WHERE is_current_year = TRUE LIMIT 1`
      );
      resolvedYearId = currentYear?.id ?? null;
    }
    const courseRows = await academyQuery<{ id: string; name: string; default_fee: number }>(
      academySlug,
      resolvedYearId
        ? `SELECT id, name, default_fee FROM courses WHERE is_active = TRUE AND academic_year_id = $1`
        : `SELECT id, name, default_fee FROM courses WHERE is_active = TRUE`,
      resolvedYearId ? [resolvedYearId] : []
    );
    // Map: lower-case course name → { id, default_fee }
    const courseMap = new Map<string, { id: string; default_fee: number }>();
    for (const c of courseRows) {
      courseMap.set(c.name.trim().toLowerCase(), { id: c.id, default_fee: Number(c.default_fee) });
    }

    // Current max ID sequence for bulk ID generation.
    const year = new Date().getFullYear();
    const prefix = `ACF-${year}-`;
    const maxRow = await academyQueryOne<{ max_seq: string | null }>(
      academySlug,
      `SELECT MAX(CAST(SUBSTRING(id FROM LENGTH($1) + 1) AS INTEGER)) AS max_seq
       FROM students WHERE id LIKE $2`,
      [prefix, `${prefix}%`]
    );
    let seq = (parseInt(maxRow?.max_seq ?? '0') || 0) + 1;

    const results = {
      total:              students.length,
      imported:           0,
      duplicates:         0,
      failed:             0,
      course_assignments: 0,
      ignored_courses:    [] as string[],
      errors:             [] as { row: number; name: string; reason: string }[],
      duplicate_details:  [] as { row: number; existing_id: string; name: string }[],
    };

    // Each entry carries the INSERT params plus the parsed course names from the row.
    interface StudentInsert {
      params: [string, string, string, string, string | null, string,
               string | null, string | null, string | null, string | null];
      courseNames: string[];
    }
    const toInsert: StudentInsert[] = [];
    const seenKeys = new Set<string>();

    // Track unmatched course names across all rows (de-duplicated).
    const ignoredCourseSet = new Set<string>();

    for (let i = 0; i < students.length; i++) {
      const s = students[i];
      const rowNum = i + 2; // spreadsheet row (1-indexed + header)
      const fn  = s.first_name?.trim() ?? '';
      const ln  = s.last_name?.trim()  ?? '';
      const name = `${fn} ${ln}`.trim();

      // ── Validation ──────────────────────────────────────────────────────────
      const errs: string[] = [];
      if (!fn)           errs.push('First Name required');
      else if (fn.length > 50) errs.push('First Name exceeds 50 chars');
      if (!ln)           errs.push('Last Name required');
      else if (ln.length > 50) errs.push('Last Name exceeds 50 chars');

      const mob = s.mobile?.trim() ?? '';
      if (!mob || !/^\d{10}$/.test(mob)) errs.push('Mobile must be 10 digits');

      const dobNorm = normalizeDob(s.dob ?? '');
      if (!dobNorm) errs.push('DOB must be DD/MM/YYYY');

      const email = s.email?.trim() ?? '';
      if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) errs.push('Invalid email');

      const gender = s.gender?.trim().toLowerCase() ?? '';
      if (gender && !['male', 'female', 'other'].includes(gender)) {
        errs.push('Gender: Male/Female/Other');
      }

      if (!s.parent_name?.trim()) errs.push('Parent/Guardian Name required');
      const pMob = s.parent_mobile?.trim() ?? '';
      if (!pMob || !/^\d{10}$/.test(pMob)) errs.push('Parent Mobile must be 10 digits');

      if (errs.length) {
        results.failed++;
        results.errors.push({ row: rowNum, name, reason: errs.join('; ') });
        continue;
      }

      // ── Intra-file duplicate ─────────────────────────────────────────────────
      const key = `${fn.toLowerCase()}|${ln.toLowerCase()}|${dobNorm}`;
      if (seenKeys.has(key)) {
        results.duplicates++;
        results.duplicate_details.push({ row: rowNum, existing_id: '(same file)', name });
        continue;
      }
      seenKeys.add(key);

      // ── DB duplicate ─────────────────────────────────────────────────────────
      const existingId = existingKeys.get(key);
      if (existingId) {
        results.duplicates++;
        results.duplicate_details.push({ row: rowNum, existing_id: existingId, name });
        continue;
      }

      // ── Parse course names from the Courses column ────────────────────────────
      const courseNames = (s.courses ?? '')
        .split(',')
        .map((c) => c.trim())
        .filter((c) => c.length > 0)
        .filter((c, idx, arr) => arr.indexOf(c) === idx); // deduplicate

      // Pre-check: collect ignored course names now so the final report is complete
      // even for rows whose DB insert later fails.
      for (const cn of courseNames) {
        if (!courseMap.has(cn.toLowerCase())) {
          ignoredCourseSet.add(cn);
        }
      }

      const studentId = `${prefix}${(seq++).toString().padStart(5, '0')}`;
      toInsert.push({
        params: [
          studentId, fn, ln, dobNorm!,
          gender || null, mob,
          email || null,
          s.parent_name?.trim() || null,
          pMob || null,
          s.address?.trim() || null,
        ],
        courseNames,
      });
    }

    // ── Bulk insert in one transaction ─────────────────────────────────────────
    if (toInsert.length) {
      await academyTransaction(academySlug, async (client) => {
        for (const row of toInsert) {
          const r = await client.query(
            `INSERT INTO students
               (id, first_name, last_name, dob, gender, mobile, email,
                parent_name, parent_mobile, address, status)
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'active')
             ON CONFLICT (id) DO NOTHING`,
            row.params
          );
          if ((r.rowCount ?? 0) > 0) {
            results.imported++;
            // Create course enrollments for matched courses.
            for (const cn of row.courseNames) {
              const course = courseMap.get(cn.toLowerCase());
              if (course) {
                await client.query(
                  `INSERT INTO student_courses
                     (student_id, course_id, fee_amount, start_date, status)
                   VALUES ($1, $2, $3, CURRENT_DATE, 'active')
                   ON CONFLICT (student_id, course_id) DO NOTHING`,
                  [row.params[0], course.id, course.default_fee]
                );
                results.course_assignments++;
              }
            }
          } else {
            results.failed++;
            results.errors.push({
              row: -1,
              name: `${row.params[1]} ${row.params[2]}`,
              reason: 'ID conflict',
            });
          }
        }
      });
    }

    results.ignored_courses = [...ignoredCourseSet];
    res.json({ success: true, data: results });
  } catch (err) { next(err); }
}

// ── GET /api/academy/students/check-duplicate ────────────────────────────────
// Checks whether a fully-registered student with the same first_name +
// last_name + dob already exists in this academy's schema. Only considers
// students with a face_embedding (i.e. completed registrations) so that
// orphaned Phase-1 records from abandoned flows don't produce false positives.

export async function checkDuplicate(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { first_name, last_name, dob } =
      req.query as Record<string, string | undefined>;

    if (!first_name?.trim() || !last_name?.trim() || !dob?.trim()) {
      return next(new AppError('first_name, last_name, and dob are required', 400));
    }

    const student = await academyQueryOne<{
      id: string; first_name: string; last_name: string; dob: string;
      created_at: string; course_names: string[];
    }>(
      academySlug,
      `SELECT s.id, s.first_name, s.last_name, s.dob, s.created_at,
              COALESCE(
                json_agg(c.name ORDER BY c.name)
                FILTER (WHERE c.id IS NOT NULL), '[]'
              ) AS course_names
       FROM students s
       LEFT JOIN student_courses sc
         ON sc.student_id = s.id AND sc.status = 'active'
       LEFT JOIN courses c ON c.id = sc.course_id
       WHERE LOWER(TRIM(s.first_name)) = LOWER(TRIM($1))
         AND LOWER(TRIM(s.last_name))  = LOWER(TRIM($2))
         AND s.dob                     = $3::date
         AND s.status                  = 'active'
         AND s.face_embedding IS NOT NULL
       GROUP BY s.id
       LIMIT 1`,
      [first_name.trim(), last_name.trim(), dob.trim()]
    );

    if (!student) {
      return void res.json({ success: true, data: { exists: false } });
    }

    res.json({
      success: true,
      data: {
        exists: true,
        student: {
          id:            student.id,
          name:          `${student.first_name} ${student.last_name}`.trim(),
          dob:           student.dob,
          registered_at: student.created_at,
          courses:       student.course_names,
        },
      },
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
    const { academic_year_id } = req.query as Record<string, string>;
    const yearId = academic_year_id || null;

    const [students, courses, presentToday, feesDue] = await Promise.all([
      yearId
        ? academyQueryOne<{ count: string }>(
            academySlug,
            `SELECT COUNT(DISTINCT sc.student_id) AS count
             FROM student_courses sc
             JOIN courses c ON c.id = sc.course_id
             JOIN students s ON s.id = sc.student_id
             WHERE c.academic_year_id = $1 AND sc.status = 'active' AND s.status = 'active'`,
            [yearId]
          )
        : academyQueryOne<{ count: string }>(
            academySlug, `SELECT COUNT(*) AS count FROM students WHERE status='active'`
          ),
      yearId
        ? academyQueryOne<{ count: string }>(
            academySlug,
            `SELECT COUNT(*) AS count FROM courses WHERE academic_year_id = $1 AND is_active = TRUE`,
            [yearId]
          )
        : academyQueryOne<{ count: string }>(
            academySlug, `SELECT COUNT(*) AS count FROM courses WHERE is_active=TRUE`
          ),
      yearId
        ? academyQueryOne<{ count: string }>(
            academySlug,
            `SELECT COUNT(DISTINCT a.student_id) AS count
             FROM attendance a
             JOIN student_courses sc ON sc.student_id = a.student_id AND sc.status = 'active'
             JOIN courses c          ON c.id = sc.course_id
             WHERE a.date = $1 AND a.status IN ('present','late') AND c.academic_year_id = $2`,
            [today, yearId]
          )
        : academyQueryOne<{ count: string }>(
            academySlug,
            `SELECT COUNT(*) AS count FROM attendance WHERE date=$1 AND status IN ('present','late')`,
            [today]
          ),
      yearId
        ? academyQueryOne<{ count: string }>(
            academySlug,
            `SELECT COUNT(*) AS count
             FROM fee_records fr
             JOIN courses c ON c.id = fr.course_id
             WHERE fr.status IN ('pending','overdue') AND fr.due_date <= $1 AND c.academic_year_id = $2`,
            [today, yearId]
          )
        : academyQueryOne<{ count: string }>(
            academySlug,
            `SELECT COUNT(*) AS count FROM fee_records WHERE status IN ('pending','overdue') AND due_date<=$1`,
            [today]
          ),
    ]);

    res.json({
      success: true,
      data: {
        total_students:  parseInt(students?.count    ?? '0'),
        total_courses:   parseInt(courses?.count     ?? '0'),
        present_today:   parseInt(presentToday?.count ?? '0'),
        fees_due:        parseInt(feesDue?.count     ?? '0'),
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
      const dup = await academyQueryOne<{
        id: string; first_name: string; last_name: string;
        created_at: string; course_names: string[];
      }>(
        academySlug,
        `SELECT s.id, s.first_name, s.last_name, s.created_at,
                COALESCE(
                  json_agg(c.name ORDER BY c.name)
                  FILTER (WHERE c.id IS NOT NULL), '[]'
                ) AS course_names
         FROM students s
         LEFT JOIN student_courses sc
           ON sc.student_id = s.id AND sc.status = 'active'
         LEFT JOIN courses c ON c.id = sc.course_id
         WHERE s.id = $1
         GROUP BY s.id`,
        [match.student_id]
      );
      return next(new AppError(
        `Face already registered to another student — ${(match.confidence! * 100).toFixed(1)}% match.`,
        409,
        {
          code: 'FACE_DUPLICATE',
          duplicate: {
            student_id:    dup?.id    ?? match.student_id,
            student_name:  dup ? `${dup.first_name} ${dup.last_name}` : null,
            courses:       dup?.course_names ?? [],
            registered_at: dup?.created_at  ?? null,
            confidence:    match.confidence,
          },
        }
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
// Soft-deletes a student by setting status='deleted'. The record and its
// Student ID remain permanently reserved — the ID generator uses MAX() across
// ALL statuses so deleted IDs are never recycled. The student's face embedding
// is purged from the InsightFace cache so they can't be matched for attendance.

export async function deleteStudent(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;

    const student = await academyQueryOne<{ id: string; status: string }>(
      academySlug, `SELECT id, status FROM students WHERE id = $1`, [id]
    );
    if (!student) return next(new AppError('Student not found', 404));
    if (student.status === 'deleted') return next(new AppError('Student already deleted', 409));

    await academyExec(
      academySlug,
      `UPDATE students SET status = 'deleted', updated_at = NOW() WHERE id = $1`,
      [id]
    );

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
