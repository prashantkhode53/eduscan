import { Request, Response, NextFunction } from 'express';
import bcrypt from 'bcrypt';
import { academyQuery, academyQueryOne, academyTransaction, academyExec } from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';
import { batchEmbed, cacheUpsert, cacheDelete, warmup } from '../../utils/insightface';
import { invalidateScanCache, getDuplicateThreshold } from '../../db/scanCache';
import {
  findSchemaDuplicate, findSchemaDuplicateTx, FACE_LOCK_KEY, slugToLockId,
} from '../../utils/faceDuplicate';

/**
 * Lightweight, structured step logging for the registration flow. Lets us see
 * exactly which phase a failing request reached in the Render logs (correlate
 * with the error_ref logged by the central errorHandler). No PII beyond the
 * academy slug + a short mobile suffix is recorded.
 */
function regLog(slug: string, phase: string, extra?: Record<string, unknown>): void {
  const tail = extra
    ? ' ' + Object.entries(extra).map(([k, v]) => `${k}=${v}`).join(' ')
    : '';
  console.log(`[register] academy=${slug} phase=${phase}${tail}`);
}

// ── ID generation ─────────────────────────────────────────────────────────────

/**
 * Build the stable per-academy student-ID prefix, e.g. "BRIG-58-".
 *
 * Globally unique across academies because it is derived from the academy
 * slug, which is itself globally unique:
 *   - letters:  first 4 alphabetic chars of the slug, uppercased (padded with
 *               'X' if the slug has <4 letters; "ACAD" if it has none).
 *   - 2-digit:  deterministic slug hash mod 100, zero-padded — fixed for the
 *               academy, requires no stored column.
 * The letters carry the real uniqueness guarantee, so even two academies that
 * hash to the same 2-digit number (e.g. BRIG-58 vs PRIN-58) never collide.
 */
function studentIdPrefix(slug: string): string {
  const letters = (slug.replace(/[^a-z]/g, '').toUpperCase() + 'XXXX').slice(0, 4);
  let h = 0;
  for (let i = 0; i < slug.length; i++) h = (h * 31 + slug.charCodeAt(i)) >>> 0;
  const num = (h % 100).toString().padStart(2, '0');
  return `${letters}-${num}-`;
}

async function generateStudentId(slug: string): Promise<string> {
  const prefix = studentIdPrefix(slug);
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
interface SubjectSelection { subject_id: string; fee_amount: number }

export async function registerStudent(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const {
      first_name, last_name, dob, gender, mobile,
      email, parent_name, parent_mobile, address,
      subjects, courses, face_images, academic_year_id,
    } = req.body as {
      first_name: string; last_name: string; dob?: string;
      gender?: string; mobile: string; email?: string;
      parent_name?: string; parent_mobile?: string; address?: string;
      subjects?: SubjectSelection[];
      courses?: CourseSelection[];
      face_images: string[];
      academic_year_id?: string;
    };

    if (!first_name || !last_name || !mobile) {
      return next(new AppError('first_name, last_name, mobile are required', 400));
    }
    // Accept either subjects[] (new) or courses[] (legacy). At least one is required.
    if (!subjects?.length && !courses?.length) {
      return next(new AppError('At least one subject must be selected', 400));
    }

    regLog(academySlug, 'start', {
      hasFace: !!face_images?.length,
      subjects: subjects?.length ?? 0,
      courses: courses?.length ?? 0,
    });

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
    let dupThreshold = 0.88;  // set from settings when a face is provided
    if (!face_images?.length) {
      // Phase 1 (details-only save): ping InsightFace now so it wakes up on
      // Render's free tier while the admin is capturing the face (30-60 s window).
      warmup();
    }
    if (face_images?.length) {
      // 1 — Generate face embedding via InsightFace
      regLog(academySlug, 'embed', { images: face_images.length });
      let embedResult: Awaited<ReturnType<typeof batchEmbed>>;
      try {
        embedResult = await batchEmbed(face_images);
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error(`[register] academy=${academySlug} phase=embed FAILED (face service):`, msg);
        return next(new AppError(
          `Face service error: ${msg}. Please try again in a moment.`, 503
        ));
      }
      if (!embedResult.success || !embedResult.embedding) {
        regLog(academySlug, 'embed-rejected', { reason: embedResult.reason ?? 'no face detected' });
        return next(new AppError(
          `Face registration failed: ${embedResult.reason ?? 'no face detected'}`, 422
        ));
      }

      // 2 — Duplicate check: SCHEMA-SCOPED and DB-authoritative.
      //     Compare the just-computed embedding against THIS academy's active
      //     faces only (cross-schema duplicates are allowed by business rule).
      //     This reuses the embedding we already have — no second face-service
      //     round-trip — and reads from PostgreSQL, so a student missing from
      //     the shared Redis cache can't slip through. A final authoritative
      //     re-check runs under an advisory lock inside the insert transaction.
      dupThreshold = await getDuplicateThreshold(academySlug);
      const dup = await findSchemaDuplicate(academySlug, embedResult.embedding, dupThreshold);
      if (dup) {
        regLog(academySlug, 'duplicate-blocked', {
          matchedStudentId: dup.student_id,
          matchedName:      dup.student_name,
          confidence:       dup.confidence,
        });
        console.warn(
          `[register] DUPLICATE FACE BLOCKED academy=${academySlug} ` +
          `matched=${dup.student_id} (${dup.student_name}) score=${dup.confidence}`
        );
        return next(new AppError(
          'This face is already registered to another student in the current schema.',
          409,
          { code: 'FACE_DUPLICATE', duplicate: dup }
        ));
      }

      embedding = embedResult.embedding;
      quality   = embedResult.quality ?? null;
    }

    // 3a — Resolve subjects and validate. Support both new (subjects[]) and legacy (courses[]) payloads.
    let resolvedSubjects: Array<{ subject_id: string; course_id: string; fee_amount: number }> = [];

    if (subjects?.length) {
      const subjectIds = subjects.map(s => s.subject_id);
      const foundSubjects = await academyQuery<{ id: string; course_id: string }>(
        academySlug,
        `SELECT id, course_id FROM subjects WHERE id = ANY($1::uuid[]) AND is_active = TRUE`,
        [subjectIds]
      );
      if (foundSubjects.length !== subjectIds.length) {
        return next(new AppError('One or more subject IDs are invalid', 400));
      }
      const subjectMap = new Map(foundSubjects.map(s => [s.id, s.course_id]));
      resolvedSubjects = subjects.map(s => ({
        subject_id: s.subject_id,
        course_id:  subjectMap.get(s.subject_id)!,
        fee_amount: s.fee_amount,
      }));
    } else if (courses?.length) {
      // Legacy: derive subjects from courses (first active subject per course)
      const courseIds = courses.map(c => c.course_id);
      const foundCourses = await academyQuery<{ id: string }>(
        academySlug,
        `SELECT id FROM courses WHERE id = ANY($1::uuid[]) AND is_active = TRUE`,
        [courseIds]
      );
      if (foundCourses.length !== courseIds.length) {
        return next(new AppError('One or more course IDs are invalid', 400));
      }
      const subjectRows = await academyQuery<{ id: string; course_id: string }>(
        academySlug,
        `SELECT DISTINCT ON (course_id) id, course_id
         FROM subjects WHERE course_id = ANY($1::uuid[]) AND is_active = TRUE
         ORDER BY course_id, created_at`,
        [courseIds]
      );
      const subjectByCourse = new Map(subjectRows.map(s => [s.course_id, s.id]));
      resolvedSubjects = courses.map(c => ({
        subject_id: subjectByCourse.get(c.course_id) ?? '',
        course_id:  c.course_id,
        fee_amount: c.fee_amount,
      })).filter(s => s.subject_id !== '');
      if (!resolvedSubjects.length) {
        return next(new AppError('No subjects found for selected courses', 400));
      }
    }

    // 4 — Generate student ID + persist in academy schema
    const studentId = await generateStudentId(academySlug);

    // First fee uses the course's fixed fee_due_date (may be null if not configured).

    // Unique course_ids derived from resolved subjects (for student_courses aggregate)
    const uniqueCourseEnrollments = new Map<string, number>();
    for (const s of resolvedSubjects) {
      uniqueCourseEnrollments.set(
        s.course_id,
        (uniqueCourseEnrollments.get(s.course_id) ?? 0) + s.fee_amount
      );
    }

    // Resolve per-course due dates from each course's fee_due_day setting.
    const courseIds = Array.from(uniqueCourseEnrollments.keys());
    const courseDueSql =
      `SELECT id, fee_due_date, fee_due_day FROM courses WHERE id = ANY($1::uuid[])`;
    // NOTE: node-postgres parses a DATE column into a JS Date object (not a
    // string), so fee_due_date is typed Date | string | null and normalised via
    // toYmd() below — calling .split() on it directly would throw a TypeError.
    let courseRows: Array<{ id: string; fee_due_date: Date | string | null; fee_due_day: number | null }>;
    try {
      courseRows = await academyQuery(academySlug, courseDueSql, [courseIds]);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      // Self-heal: an older academy whose boot-time reconcile partially failed
      // may be missing the fee_due_* columns. Add them idempotently and retry
      // once rather than 500-ing the whole registration. Any other error still
      // propagates so genuine bugs are not masked.
      if (/column .*(fee_due_date|fee_due_day).* does not exist/i.test(msg)) {
        await academyExec(academySlug, `
          ALTER TABLE IF EXISTS courses
            ADD COLUMN IF NOT EXISTS fee_due_day  INT  DEFAULT NULL,
            ADD COLUMN IF NOT EXISTS fee_due_date DATE DEFAULT NULL
        `);
        courseRows = await academyQuery(academySlug, courseDueSql, [courseIds]);
      } else {
        throw e;
      }
    }
    const courseDueDateMap = new Map(
      courseRows.map(r => [r.id, { fee_due_date: r.fee_due_date, fee_due_day: r.fee_due_day }])
    );

    const now = new Date();
    // Format a date value to 'YYYY-MM-DD'. Handles BOTH a pg Date object and a
    // string (some drivers/queries yield either) and reads LOCAL components so
    // the stored calendar date is preserved regardless of the server timezone.
    const toYmd = (v: Date | string): string => {
      if (v instanceof Date) {
        const y = v.getFullYear();
        const m = String(v.getMonth() + 1).padStart(2, '0');
        const d = String(v.getDate()).padStart(2, '0');
        return `${y}-${m}-${d}`;
      }
      return String(v).slice(0, 10); // '2026-09-30' or '2026-09-30T00:00:...' → '2026-09-30'
    };
    const getCourseDueDate = (courseId: string): string => {
      const c = courseDueDateMap.get(courseId);
      if (c?.fee_due_date) return toYmd(c.fee_due_date);
      const feeDueDay = c?.fee_due_day ?? null;
      if (feeDueDay != null && feeDueDay > 0) {
        return toYmd(new Date(now.getFullYear(), now.getMonth(), feeDueDay));
      }
      return toYmd(new Date(now.getFullYear(), now.getMonth() + 1, 0));
    };

    regLog(academySlug, 'db-insert', { studentId, courses: uniqueCourseEnrollments.size });
    try {
    await academyTransaction(academySlug, async (client) => {
      // Serialize face enrollment per academy: an advisory lock (auto-released
      // at COMMIT/ROLLBACK) stops two concurrent registrations of the same face
      // from both passing the duplicate check. The lock is a no-op for
      // face-less Phase-1 saves but harmless to take unconditionally.
      const { classId, objId } = slugToLockId(`${academySlug}:${FACE_LOCK_KEY}`);
      await client.query(`SELECT pg_advisory_xact_lock($1, $2)`, [classId, objId]);

      // Authoritative duplicate re-check UNDER the lock — closes the race
      // window between the pre-insert check above and this insert.
      if (embedding) {
        const raceDup = await findSchemaDuplicateTx(client, embedding, dupThreshold);
        if (raceDup) {
          regLog(academySlug, 'duplicate-blocked-race', {
            matchedStudentId: raceDup.student_id,
            confidence:       raceDup.confidence,
          });
          throw new AppError(
            'This face is already registered to another student in the current schema.',
            409,
            { code: 'FACE_DUPLICATE', duplicate: raceDup }
          );
        }
      }

      await client.query(
        `INSERT INTO students
           (id, first_name, last_name, dob, gender, mobile, email,
            parent_name, parent_mobile, address, face_embedding, face_quality,
            academic_year_id)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`,
        [
          studentId, first_name.trim(), last_name.trim(),
          dob ?? null, gender ?? null, mobile,
          email ?? null, parent_name ?? null, parent_mobile ?? null,
          address ?? null,
          embedding ? JSON.stringify(embedding) : null,
          quality,
          academic_year_id ?? null,
        ]
      );

      // Enrol in each subject
      for (const sel of resolvedSubjects) {
        await client.query(
          `INSERT INTO student_subjects (student_id, subject_id, fee_amount, start_date)
           VALUES ($1,$2,$3,CURRENT_DATE)
           ON CONFLICT (student_id, subject_id) DO NOTHING`,
          [studentId, sel.subject_id, sel.fee_amount]
        );
      }

      // One fee record per course = sum of enrolled subject fees
      for (const [courseId, totalFee] of uniqueCourseEnrollments) {
        const dueDate = getCourseDueDate(courseId);
        await client.query(
          `INSERT INTO fee_records (student_id, course_id, amount_due, due_date, status)
           SELECT $1::varchar, $2::uuid, $3::numeric, $4::date, 'pending'
           WHERE NOT EXISTS (
             SELECT 1 FROM fee_records fr
             WHERE fr.student_id = $1
               AND fr.course_id  = $2
               AND fr.subject_id IS NULL
           )`,
          [studentId, courseId, totalFee, dueDate]
        );
        // Maintain student_courses aggregate (for backward-compat)
        await client.query(
          `INSERT INTO student_courses (student_id, course_id, fee_amount, start_date)
           VALUES ($1,$2,$3,CURRENT_DATE)
           ON CONFLICT (student_id, course_id) DO NOTHING`,
          [studentId, courseId, totalFee]
        );
      }
    });
    } catch (dbErr) {
      // A duplicate block thrown by the in-lock re-check is intentional, not a
      // DB fault — rethrow it as-is so the handler returns the 409 payload.
      if (dbErr instanceof AppError) throw dbErr;
      // Log the failing step + slug so it can be matched to the error_ref the
      // central handler emits, then rethrow so the handler categorises the pg
      // error into a specific client message (e.g. "Database save failed ...").
      console.error(`[register] academy=${academySlug} phase=db-insert FAILED studentId=${studentId}:`, dbErr);
      throw dbErr;
    }
    regLog(academySlug, 'db-ok', { studentId });

    // 5 — Push embedding to InsightFace Redis cache (only when a face was given)
    // Non-fatal: if the cache update fails the student is still registered; the
    // embedding is persisted in the DB and the cache can be reloaded later.
    if (embedding) {
      try {
        await cacheUpsert({
          student_id:  studentId,
          embedding,
          first_name:  first_name.trim(),
          last_name:   last_name.trim(),
          class_grade: 'academy',
          division:    academySlug.substring(0, 8),
          roll_no:     null,
        });
      } catch (e) {
        console.error('[register] cacheUpsert failed (non-fatal):', e);
      }
      invalidateScanCache(academySlug);
    }

    regLog(academySlug, 'done', { studentId });
    res.status(201).json({
      success: true,
      data: { id: studentId, first_name, last_name, subjects_enrolled: resolvedSubjects.length },
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

    // Current max ID sequence for bulk ID generation. Uses the same stable
    // per-academy prefix (e.g. "BRIG-58-") as single registration so bulk and
    // single-import IDs share one continuous sequence and stay globally unique.
    const prefix = studentIdPrefix(academySlug);
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
                // NOTE: subjects are intentionally NOT auto-assigned here.
                // Bulk upload enrols the student in the COURSE only; subject
                // selection (and per-subject fees) is done later by the user in
                // the Student Register/Edit screen. Auto-assigning the "first"
                // subject previously created unwanted ₹0 subject entries.
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
       LEFT JOIN student_courses sc ON sc.student_id = s.id AND sc.status = 'active'
       LEFT JOIN courses c          ON c.id = sc.course_id
       WHERE s.id = $1
       GROUP BY s.id`,
      [id]
    );
    if (!student) return next(new AppError('Student not found', 404));

    // Include subject-level enrollments for the edit screen auto-restore
    const enrolledSubjects = await academyQuery<{
      subject_id: string; subject_name: string;
      course_id: string; course_name: string;
      fee_amount: number; status: string;
    }>(
      academySlug,
      `SELECT ss.subject_id, sub.name AS subject_name,
              sub.course_id, c.name AS course_name,
              ss.fee_amount, ss.status
       FROM student_subjects ss
       JOIN subjects sub ON sub.id = ss.subject_id
       JOIN courses c    ON c.id   = sub.course_id
       WHERE ss.student_id = $1 AND ss.status = 'active'
       ORDER BY c.name, sub.name`,
      [id]
    );

    res.json({ success: true, data: { ...student, enrolled_subjects: enrolledSubjects } });
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
      subjects, courses, face_images,
      first_name, last_name, mobile, email,
      dob, gender, parent_name, parent_mobile, address,
      academic_year_id,
    } = req.body as {
      subjects?: SubjectSelection[];
      courses?: CourseSelection[];
      face_images?: string[];
      first_name?: string; last_name?: string; mobile?: string;
      email?: string; dob?: string; gender?: string;
      parent_name?: string; parent_mobile?: string; address?: string;
      academic_year_id?: string;
    };

    if (!subjects?.length && !courses?.length) {
      return next(new AppError('At least one subject is required', 400));
    }

    const student = await academyQueryOne<{
      id: string; first_name: string; last_name: string;
    }>(academySlug, `SELECT id, first_name, last_name FROM students WHERE id = $1`, [id]);
    if (!student) return next(new AppError('Student not found', 404));

    // Resolve subjects (same logic as register)
    let resolvedSubjects: Array<{ subject_id: string; course_id: string; fee_amount: number }> = [];

    if (subjects?.length) {
      const subjectIds = subjects.map(s => s.subject_id);
      const foundSubjects = await academyQuery<{ id: string; course_id: string }>(
        academySlug,
        `SELECT id, course_id FROM subjects WHERE id = ANY($1::uuid[]) AND is_active = TRUE`,
        [subjectIds]
      );
      if (foundSubjects.length !== subjectIds.length) {
        return next(new AppError('One or more subject IDs are invalid', 400));
      }
      const subjectMap = new Map(foundSubjects.map(s => [s.id, s.course_id]));
      resolvedSubjects = subjects.map(s => ({
        subject_id: s.subject_id,
        course_id:  subjectMap.get(s.subject_id)!,
        fee_amount: s.fee_amount,
      }));
    } else if (courses?.length) {
      const courseIds = courses.map(c => c.course_id);
      const foundCourses = await academyQuery<{ id: string }>(
        academySlug,
        `SELECT id FROM courses WHERE id = ANY($1::uuid[]) AND is_active = TRUE`,
        [courseIds]
      );
      if (foundCourses.length !== courseIds.length) {
        return next(new AppError('One or more course IDs are invalid', 400));
      }
      const subjectRows = await academyQuery<{ id: string; course_id: string }>(
        academySlug,
        `SELECT DISTINCT ON (course_id) id, course_id
         FROM subjects WHERE course_id = ANY($1::uuid[]) AND is_active = TRUE
         ORDER BY course_id, created_at`,
        [courseIds]
      );
      const subjectByCourse = new Map(subjectRows.map(s => [s.course_id, s.id]));
      resolvedSubjects = courses.map(c => ({
        subject_id: subjectByCourse.get(c.course_id) ?? '',
        course_id:  c.course_id,
        fee_amount: c.fee_amount,
      })).filter(s => s.subject_id !== '');
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
      // Group desired subjects by course for targeted upsert + drop
      const desiredByCourse = new Map<string, typeof resolvedSubjects>();
      for (const sel of resolvedSubjects) {
        const list = desiredByCourse.get(sel.course_id) ?? [];
        list.push(sel);
        desiredByCourse.set(sel.course_id, list);
      }

      for (const [courseId, selections] of desiredByCourse) {
        const desiredIds   = selections.map(s => s.subject_id);
        const desiredIdSet = new Set(desiredIds);

        // Upsert desired subjects — fee_amount is LOCKED after first assignment
        for (const sel of selections) {
          await client.query(
            `INSERT INTO student_subjects (student_id, subject_id, fee_amount, start_date, status)
             VALUES ($1, $2, $3, CURRENT_DATE, 'active')
             ON CONFLICT (student_id, subject_id) DO UPDATE
               SET status = 'active', end_date = NULL`,
            [id, sel.subject_id, sel.fee_amount]
          );
        }

        // Guard: block subject removal if fees have already been collected for this course
        const existingActive = (await client.query<{ subject_id: string }>(
          `SELECT ss.subject_id
           FROM student_subjects ss
           JOIN subjects sub ON sub.id = ss.subject_id
           WHERE ss.student_id = $1 AND sub.course_id = $2 AND ss.status = 'active'`,
          [id, courseId]
        )).rows;
        const beingDropped = existingActive.filter(r => !desiredIdSet.has(r.subject_id));

        if (beingDropped.length > 0) {
          const { rows: paidCheck } = await client.query(
            `SELECT 1 FROM fee_records
             WHERE student_id = $1 AND course_id = $2 AND amount_paid > 0 LIMIT 1`,
            [id, courseId]
          );
          if (paidCheck.length > 0) {
            throw new AppError(
              'Cannot remove subjects: fees have already been collected for this course',
              400
            );
          }
        }

        // Drop active subjects for this course that are no longer desired
        await client.query(
          `UPDATE student_subjects ss
             SET status = 'dropped', end_date = CURRENT_DATE
           FROM subjects sub
           WHERE ss.student_id = $1
             AND sub.id = ss.subject_id
             AND sub.course_id = $2
             AND ss.status = 'active'
             AND ss.subject_id <> ALL($3::uuid[])`,
          [id, courseId, desiredIds]
        );
      }

      // Recalculate course totals from DB after upsert/drop
      const { rows: courseAggs } = await client.query<{ course_id: string; total_fee: string }>(
        `SELECT sub.course_id, SUM(ss.fee_amount) AS total_fee
         FROM student_subjects ss
         JOIN subjects sub ON sub.id = ss.subject_id
         WHERE ss.student_id = $1 AND ss.status = 'active'
         GROUP BY sub.course_id`,
        [id]
      );

      for (const agg of courseAggs) {
        const totalFee = parseFloat(agg.total_fee);
        await client.query(
          `INSERT INTO student_courses (student_id, course_id, fee_amount, start_date, status)
           VALUES ($1, $2, $3, CURRENT_DATE, 'active')
           ON CONFLICT (student_id, course_id)
           DO UPDATE SET fee_amount = $3, status = 'active', end_date = NULL`,
          [id, agg.course_id, totalFee]
        );
        // Recalculate the course-level fee record (subject_id IS NULL) to the new
        // subject-fee sum. CRITICAL: this must apply for EVERY status — when a
        // newly added subject raises the total for a student who was already
        // 'partial' or 'paid', the old code's "status IN ('pending','overdue')"
        // filter skipped them, so amount_due stayed stale and they never
        // reappeared in Fees Management. amount_paid (Paid Till Date) is
        // preserved; status + paid_date are recomputed from the new balance.
        const { rowCount: updated } = await client.query(
          `UPDATE fee_records
           SET amount_due = $3,
               status = CASE
                          WHEN amount_paid >= $3       THEN 'paid'
                          WHEN due_date < CURRENT_DATE THEN 'overdue'
                          WHEN amount_paid > 0         THEN 'partial'
                          ELSE 'pending'
                        END,
               paid_date  = CASE WHEN amount_paid >= $3 THEN paid_date ELSE NULL END,
               updated_at = NOW()
           WHERE student_id = $1 AND course_id = $2
             AND subject_id IS NULL`,
          [id, agg.course_id, totalFee]
        );
        // No course-level fee record yet (e.g. a course freshly assigned during
        // edit) → create one so the fee is collectible. Duplicate-guarded.
        if (!updated) {
          await client.query(
            `INSERT INTO fee_records (student_id, course_id, amount_due, due_date, status)
             SELECT $1, $2, $3, COALESCE(c.fee_due_date, CURRENT_DATE),
                    CASE WHEN $3 <= 0 THEN 'paid' ELSE 'pending' END
             FROM courses c
             WHERE c.id = $2
               AND NOT EXISTS (
                 SELECT 1 FROM fee_records fr
                 WHERE fr.student_id = $1 AND fr.course_id = $2 AND fr.subject_id IS NULL
               )`,
            [id, agg.course_id, totalFee]
          );
        }
      }

      // Deactivate student_courses for courses where all subjects were dropped
      for (const courseId of desiredByCourse.keys()) {
        if (!courseAggs.some(a => a.course_id === courseId)) {
          await client.query(
            `UPDATE student_courses
               SET status = 'dropped', end_date = CURRENT_DATE
             WHERE student_id = $1 AND course_id = $2 AND status = 'active'`,
            [id, courseId]
          );
          // All subjects dropped → no fee due for this course. Dropping is
          // blocked earlier if any fee was collected, so amount_paid is 0 here;
          // mark the record settled (balance 0) so it leaves Fees Management.
          await client.query(
            `UPDATE fee_records
               SET amount_due = 0, status = 'paid', updated_at = NOW()
             WHERE student_id = $1 AND course_id = $2
               AND subject_id IS NULL
               AND amount_paid = 0`,
            [id, courseId]
          );
        }
      }

      // Update personal info fields when provided
      if (first_name || last_name || mobile || academic_year_id !== undefined) {
        await client.query(
          `UPDATE students SET
             first_name       = COALESCE($1, first_name),
             last_name        = COALESCE($2, last_name),
             mobile           = COALESCE($3, mobile),
             email            = $4,
             dob              = $5,
             gender           = $6,
             parent_name      = $7,
             parent_mobile    = $8,
             address          = $9,
             academic_year_id = COALESCE($10::uuid, academic_year_id),
             updated_at       = NOW()
           WHERE id = $11`,
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
            academic_year_id      || null,
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

      if (!first_name && !last_name && !mobile && !newEmbedding && academic_year_id === undefined) {
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
      invalidateScanCache(academySlug);
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

    regLog(academySlug, 'face:start', { studentId: id, images: face_images.length });

    const student = await academyQueryOne<{
      id: string; first_name: string; last_name: string;
    }>(academySlug, `SELECT id, first_name, last_name FROM students WHERE id = $1`, [id]);
    if (!student) return next(new AppError('Student not found', 404));

    regLog(academySlug, 'face:embed', { studentId: id });
    let embed: Awaited<ReturnType<typeof batchEmbed>>;
    try {
      embed = await batchEmbed(face_images);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error(`[register] academy=${academySlug} phase=face:embed FAILED (face service) studentId=${id}:`, msg);
      return next(new AppError(
        `Face service error: ${msg}. Please try again in a moment.`, 503
      ));
    }
    if (!embed.success || !embed.embedding) {
      regLog(academySlug, 'face:embed-rejected', { studentId: id, reason: embed.reason ?? 'no face detected' });
      return next(new AppError(
        `Face capture failed: ${embed.reason ?? 'no face detected'}`, 422
      ));
    }

    // Duplicate check + write, atomic under a per-academy advisory lock so a
    // concurrent enrollment of the same face can't slip in between. The check
    // is SCHEMA-SCOPED and DB-authoritative (excludes THIS student so a
    // re-capture of their own face isn't flagged); cross-schema duplicates are
    // allowed by business rule.
    const dupThreshold = await getDuplicateThreshold(academySlug);
    regLog(academySlug, 'face:db-update', { studentId: id });
    try {
      await academyTransaction(academySlug, async (client) => {
        const { classId, objId } = slugToLockId(`${academySlug}:${FACE_LOCK_KEY}`);
        await client.query(`SELECT pg_advisory_xact_lock($1, $2)`, [classId, objId]);

        const dup = await findSchemaDuplicateTx(client, embed.embedding!, dupThreshold, id);
        if (dup) {
          regLog(academySlug, 'duplicate-blocked', {
            studentId:        id,
            matchedStudentId: dup.student_id,
            matchedName:      dup.student_name,
            confidence:       dup.confidence,
          });
          console.warn(
            `[updateStudentFace] DUPLICATE FACE BLOCKED academy=${academySlug} ` +
            `student=${id} matched=${dup.student_id} (${dup.student_name}) score=${dup.confidence}`
          );
          throw new AppError(
            'This face is already registered to another student in the current schema.',
            409,
            { code: 'FACE_DUPLICATE', duplicate: dup }
          );
        }

        await client.query(
          `UPDATE students SET face_embedding = $1, face_quality = $2, updated_at = NOW()
           WHERE id = $3`,
          [JSON.stringify(embed.embedding), embed.quality ?? null, id]
        );
      });
    } catch (dbErr) {
      if (dbErr instanceof AppError) throw dbErr;  // intentional duplicate block
      console.error(`[register] academy=${academySlug} phase=face:db-update FAILED studentId=${id}:`, dbErr);
      throw dbErr;
    }

    // Non-fatal: if the cache update fails the student is still registered.
    try {
      await cacheUpsert({
        student_id:  id,
        embedding:   embed.embedding,
        first_name:  student.first_name,
        last_name:   student.last_name,
        class_grade: 'academy',
        division:    academySlug.substring(0, 8),
        roll_no:     null,
      });
    } catch (e) {
      console.error('[updateStudentFace] cacheUpsert failed (non-fatal):', e);
    }
    invalidateScanCache(academySlug);

    regLog(academySlug, 'face:done', { studentId: id });
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
    invalidateScanCache(academySlug);

    res.json({ success: true, message: 'Student deleted successfully' });
  } catch (err) { next(err); }
}

// ── PUT /api/academy/students/:id/master-password ─────────────────────────────
// Admin sets or replaces the fallback login password for a specific student.
// The password is stored hashed; it is shared with the parent manually (offline).

export async function setMasterPassword(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;
    const { password } = req.body as { password?: string };

    if (!password || password.length < 6) {
      return next(new AppError('Password must be at least 6 characters', 400));
    }

    const student = await academyQueryOne<{ id: string }>(
      academySlug, `SELECT id FROM students WHERE id = $1 AND status = 'active'`, [id]
    );
    if (!student) return next(new AppError('Student not found or inactive', 404));

    const hash = await bcrypt.hash(password, 12);

    await academyExec(
      academySlug,
      `UPDATE students
       SET fallback_password_hash    = $1,
           fallback_password_enabled = TRUE,
           updated_at                = NOW()
       WHERE id = $2`,
      [hash, id]
    );

    console.log(`[admin/master-password] SET for student ${id} @ ${academySlug}`);
    res.json({ success: true, message: 'Fallback password set. Share it with the parent manually.' });
  } catch (err) { next(err); }
}

// ── DELETE /api/academy/students/:id/master-password ─────────────────────────
// Admin revokes the fallback login password for a student.
// The "Use Institute Password" option disappears from the parent's login screen.

export async function deleteMasterPassword(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { id } = req.params;

    const student = await academyQueryOne<{ id: string }>(
      academySlug, `SELECT id FROM students WHERE id = $1`, [id]
    );
    if (!student) return next(new AppError('Student not found', 404));

    await academyExec(
      academySlug,
      `UPDATE students
       SET fallback_password_hash    = NULL,
           fallback_password_enabled = FALSE,
           updated_at                = NOW()
       WHERE id = $1`,
      [id]
    );

    console.log(`[admin/master-password] REVOKED for student ${id} @ ${academySlug}`);
    res.json({ success: true, message: 'Fallback password revoked successfully.' });
  } catch (err) { next(err); }
}
