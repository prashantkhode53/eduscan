import { Request, Response, NextFunction } from 'express';
import { query, queryOne } from '../db/pool';
import { Student, ApiResponse, AttendanceSummary } from '../types';
import { AppError } from '../middleware/errorHandler';
import { generateStudentId } from '../utils/studentIdGenerator';
import { batchEmbed, cacheUpsert, cacheDelete, matchFace } from '../utils/insightface';

export async function listStudents(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const {
      class: classGrade,
      division,
      search,
      status = 'active',
      page = '1',
      limit = '50',
    } = req.query as Record<string, string>;

    const pageNum = Math.max(1, parseInt(page, 10));
    const limitNum = Math.min(100, Math.max(1, parseInt(limit, 10)));
    const offset = (pageNum - 1) * limitNum;

    const conditions: string[] = [];
    const params: unknown[] = [];
    let paramIdx = 1;

    if (status && status !== 'all') {
      conditions.push(`s.status = $${paramIdx++}`);
      params.push(status);
    }
    if (classGrade) {
      conditions.push(`s.class_grade = $${paramIdx++}`);
      params.push(classGrade);
    }
    if (division) {
      conditions.push(`s.division = $${paramIdx++}`);
      params.push(division);
    }
    if (search) {
      conditions.push(
        `(s.first_name ILIKE $${paramIdx} OR s.last_name ILIKE $${paramIdx} OR s.id ILIKE $${paramIdx})`
      );
      params.push(`%${search}%`);
      paramIdx++;
    }

    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

    const countRows = await query<{ count: string }>(
      `SELECT COUNT(*) as count FROM students s ${where}`,
      params
    );
    const total = parseInt(countRows[0]?.count ?? '0', 10);

    const rows = await query<Student>(
      `SELECT id, first_name, middle_name, last_name, dob, gender, blood_group,
              nationality, govt_id, institution, academic_year, class_grade, division,
              roll_no, stream, admission_date, parent_name, parent_relation,
              mobile, email, address, known_allergies, medical_conditions,
              emergency_contact, transport_route, face_quality, status,
              created_at, updated_at
       FROM students s ${where}
       ORDER BY s.class_grade, s.division, s.roll_no, s.last_name
       LIMIT $${paramIdx} OFFSET $${paramIdx + 1}`,
      [...params, limitNum, offset]
    );

    res.json({
      success: true,
      data: {
        students: rows,
        pagination: { page: pageNum, limit: limitNum, total, pages: Math.ceil(total / limitNum) },
      },
      message: 'Students fetched',
    } as ApiResponse<unknown>);
  } catch (err) {
    next(err);
  }
}

export async function createStudent(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const body = req.body as Partial<Student> & {
      face_images?: unknown;
    };

    // ── Validate face images ───────────────────────────────────────────────
    if (!Array.isArray(body.face_images) || body.face_images.length < 1) {
      throw new AppError('face_images must be a non-empty array of base64 JPEG strings', 400);
    }
    const faceImages = body.face_images as string[];

    const required: (keyof Student)[] = [
      'first_name', 'last_name', 'dob', 'gender', 'institution',
      'academic_year', 'class_grade', 'division', 'admission_date',
      'parent_name', 'mobile',
    ];
    for (const field of required) {
      if (!body[field]) throw new AppError(`Field '${field}' is required`, 400);
    }

    // ── Generate 512-D ArcFace embedding via Python ────────────────────────
    let embedResult;
    try {
      embedResult = await batchEmbed(faceImages);
    } catch (err) {
      console.error('[createStudent] InsightFace service error:', err);
      throw new AppError('Face recognition service unavailable. Please try again.', 503);
    }

    if (!embedResult.success || !embedResult.embedding) {
      throw new AppError(
        `Face embedding failed: ${embedResult.reason ?? 'unknown error'}. Please re-capture with a clear, front-facing photo.`,
        422
      );
    }

    const embedding = embedResult.embedding;

    // ── Duplicate face check via Redis cache ───────────────────────────────
    // Use /match with one of the registration images against existing cache.
    try {
      const dupeCheck = await matchFace(faceImages[0]);
      const DUPE_THRESHOLD = 0.88;
      if (dupeCheck.matched && dupeCheck.confidence != null && dupeCheck.confidence >= DUPE_THRESHOLD) {
        const existing = dupeCheck.student;
        throw new AppError(
          `Face already registered — ${(dupeCheck.confidence * 100).toFixed(1)}% match with ${existing?.first_name ?? ''} ${existing?.last_name ?? ''} (ID: ${dupeCheck.student_id ?? ''}). Re-capture with a clearer image or contact admin if this is a different student.`,
          409
        );
      }
    } catch (err) {
      if (err instanceof AppError) throw err;
      // InsightFace unavailable for dupe check — log and proceed
      console.warn('[createStudent] Duplicate check skipped — InsightFace unavailable:', err);
    }

    const id = await generateStudentId();
    const rollNo = body.roll_no != null ? parseInt(String(body.roll_no), 10) : null;
    const faceQuality = embedResult.quality != null ? Number(embedResult.quality) : null;

    await query(
      `INSERT INTO students (
        id, first_name, middle_name, last_name, dob, gender, blood_group, nationality, govt_id,
        institution, academic_year, class_grade, division, roll_no, stream, admission_date,
        parent_name, parent_relation, mobile, email, address, known_allergies, medical_conditions,
        emergency_contact, transport_route, face_embedding, face_quality, status
      ) VALUES (
        $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28
      )`,
      [
        id, body.first_name, body.middle_name ?? null, body.last_name,
        body.dob, body.gender, body.blood_group ?? null, body.nationality ?? null, body.govt_id ?? null,
        body.institution, body.academic_year, body.class_grade, body.division,
        rollNo, body.stream ?? null, body.admission_date,
        body.parent_name, body.parent_relation ?? null, body.mobile,
        body.email ?? null, body.address ?? null, body.known_allergies ?? null,
        body.medical_conditions ?? null, body.emergency_contact ?? null, body.transport_route ?? null,
        JSON.stringify(embedding), faceQuality, 'active',
      ]
    );

    // ── Update Redis cache ─────────────────────────────────────────────────
    try {
      await cacheUpsert({
        student_id: id,
        embedding,
        first_name: body.first_name as string,
        last_name:  body.last_name as string,
        class_grade: body.class_grade as string,
        division:   body.division as string,
        roll_no:    rollNo,
      });
    } catch (err) {
      console.warn('[createStudent] Redis cache upsert failed (non-fatal):', err);
    }

    const student = await queryOne<Student>(`SELECT * FROM students WHERE id = $1`, [id]);
    res.status(201).json({ success: true, data: student, message: 'Student registered successfully' });
  } catch (err) {
    next(err);
  }
}

export async function getStudent(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { id } = req.params;
    const student = await queryOne<Student>(`SELECT * FROM students WHERE id = $1`, [id]);
    if (!student) return next(new AppError('Student not found', 404));

    const summaryRows = await query<{
      total_days: string; present_days: string; absent_days: string; late_days: string;
    }>(
      `SELECT
         COUNT(*) as total_days,
         COUNT(*) FILTER (WHERE status = 'present') as present_days,
         COUNT(*) FILTER (WHERE status = 'absent') as absent_days,
         COUNT(*) FILTER (WHERE status = 'late') as late_days
       FROM attendance WHERE student_id = $1`,
      [id]
    );

    const s = summaryRows[0];
    const totalDays = parseInt(s.total_days, 10);
    const presentDays = parseInt(s.present_days, 10);
    const summary: AttendanceSummary = {
      total_days: totalDays,
      present_days: presentDays,
      absent_days: parseInt(s.absent_days, 10),
      late_days: parseInt(s.late_days, 10),
      percentage: totalDays > 0 ? Math.round((presentDays / totalDays) * 10000) / 100 : 0,
    };

    res.json({ success: true, data: { student, attendance_summary: summary }, message: 'Student fetched' });
  } catch (err) {
    next(err);
  }
}

export async function updateStudent(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { id } = req.params;
    const body = req.body as Partial<Student> & { face_images?: string[] };

    const existing = await queryOne<{ id: string; class_grade: string; division: string; roll_no: number | null }>(
      `SELECT id, class_grade, division, roll_no FROM students WHERE id = $1`,
      [id]
    );
    if (!existing) return next(new AppError('Student not found', 404));

    const fields: string[] = [];
    const values: unknown[] = [];
    let idx = 1;

    const allowed: (keyof Student)[] = [
      'first_name', 'middle_name', 'last_name', 'dob', 'gender', 'blood_group',
      'nationality', 'govt_id', 'institution', 'academic_year', 'class_grade',
      'division', 'roll_no', 'stream', 'admission_date', 'parent_name',
      'parent_relation', 'mobile', 'email', 'address', 'known_allergies',
      'medical_conditions', 'emergency_contact', 'transport_route', 'face_quality', 'status',
    ];

    for (const key of allowed) {
      if (body[key] !== undefined) {
        fields.push(`${key} = $${idx++}`);
        values.push(body[key]);
      }
    }

    // Re-register face via new images
    if (Array.isArray(body.face_images) && body.face_images.length > 0) {
      let embedResult;
      try {
        embedResult = await batchEmbed(body.face_images);
      } catch {
        throw new AppError('Face recognition service unavailable', 503);
      }
      if (!embedResult.success || !embedResult.embedding) {
        throw new AppError(`Face embedding failed: ${embedResult.reason ?? 'unknown error'}`, 422);
      }
      fields.push(`face_embedding = $${idx++}`);
      values.push(JSON.stringify(embedResult.embedding));
      if (embedResult.quality != null) {
        fields.push(`face_quality = $${idx++}`);
        values.push(Number(embedResult.quality));
      }
      // Update Redis cache with new embedding
      try {
        const updated = { ...existing, ...body };
        await cacheUpsert({
          student_id: id,
          embedding: embedResult.embedding,
          first_name: String(updated.first_name ?? ''),
          last_name:  String(updated.last_name ?? ''),
          class_grade: String(updated.class_grade ?? existing.class_grade),
          division:   String(updated.division ?? existing.division),
          roll_no:    updated.roll_no != null ? parseInt(String(updated.roll_no), 10) : existing.roll_no,
        });
      } catch (err) {
        console.warn('[updateStudent] Redis cache upsert failed (non-fatal):', err);
      }
    }

    if (fields.length === 0) return next(new AppError('No fields to update', 400));

    fields.push(`updated_at = NOW()`);
    values.push(id);

    await query(
      `UPDATE students SET ${fields.join(', ')} WHERE id = $${idx}`,
      values
    );

    const updated = await queryOne<Student>(`SELECT * FROM students WHERE id = $1`, [id]);
    res.json({ success: true, data: updated, message: 'Student updated' });
  } catch (err) {
    next(err);
  }
}

/**
 * GET /api/students/face-duplicates
 * Admin diagnostic: find students with suspiciously similar 512-D ArcFace embeddings.
 */
export async function listFaceDuplicates(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const rows = await query<{
      id: string; first_name: string; last_name: string;
      class_grade: string; division: string; face_embedding: unknown;
    }>(
      `SELECT id, first_name, last_name, class_grade, division, face_embedding
       FROM students WHERE status = 'active' ORDER BY created_at`
    );

    const students = rows.map(s => {
      const raw = s.face_embedding;
      let emb: number[];
      try { emb = typeof raw === 'string' ? JSON.parse(raw) : Array.isArray(raw) ? (raw as number[]) : []; }
      catch { emb = []; }
      return { ...s, emb };
    }).filter(s => s.emb.length >= 128);

    const SUSPICIOUS = 0.85;
    const pairs: Array<{
      studentA: { id: string; name: string; class_grade: string; division: string };
      studentB: { id: string; name: string; class_grade: string; division: string };
      similarity: number;
      severity: string;
    }> = [];

    for (let i = 0; i < students.length; i++) {
      for (let j = i + 1; j < students.length; j++) {
        // Cosine similarity — works for any dimension (128 or 512)
        const a = students[i].emb;
        const b = students[j].emb;
        if (a.length !== b.length) continue;
        let dot = 0, ma = 0, mb = 0;
        for (let k = 0; k < a.length; k++) { dot += a[k] * b[k]; ma += a[k] * a[k]; mb += b[k] * b[k]; }
        const sim = (ma === 0 || mb === 0) ? 0 : dot / (Math.sqrt(ma) * Math.sqrt(mb));
        if (sim >= SUSPICIOUS) {
          pairs.push({
            studentA: { id: students[i].id, name: `${students[i].first_name} ${students[i].last_name}`, class_grade: students[i].class_grade, division: students[i].division },
            studentB: { id: students[j].id, name: `${students[j].first_name} ${students[j].last_name}`, class_grade: students[j].class_grade, division: students[j].division },
            similarity: Math.round(sim * 10000) / 10000,
            severity: sim >= 0.95 ? 'DUPLICATE' : 'SUSPICIOUS',
          });
        }
      }
    }

    pairs.sort((a, b) => b.similarity - a.similarity);

    res.json({
      success: true,
      data: {
        total_students_checked: students.length,
        duplicate_pairs: pairs.length,
        pairs,
        advice: pairs.length > 0
          ? 'Delete one student from each DUPLICATE pair.'
          : 'No duplicate face embeddings found.',
      },
      message: pairs.length > 0
        ? `Found ${pairs.length} suspicious embedding pair(s).`
        : 'No duplicate embeddings found.',
    });
  } catch (err) {
    next(err);
  }
}

export async function deleteStudent(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { id } = req.params;
    const existing = await queryOne<{ id: string }>(`SELECT id FROM students WHERE id = $1`, [id]);
    if (!existing) return next(new AppError('Student not found', 404));

    await query(`UPDATE students SET status = 'inactive', updated_at = NOW() WHERE id = $1`, [id]);

    // Remove from Redis cache
    try {
      await cacheDelete(id);
    } catch (err) {
      console.warn('[deleteStudent] Redis cache delete failed (non-fatal):', err);
    }

    res.json({ success: true, message: 'Student deactivated successfully' });
  } catch (err) {
    next(err);
  }
}

export async function getStudentAttendance(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { id } = req.params;
    const { page = '1', limit = '30' } = req.query as Record<string, string>;

    const pageNum = Math.max(1, parseInt(page, 10));
    const limitNum = Math.min(100, Math.max(1, parseInt(limit, 10)));
    const offset = (pageNum - 1) * limitNum;

    const student = await queryOne<{ id: string }>(`SELECT id FROM students WHERE id = $1`, [id]);
    if (!student) return next(new AppError('Student not found', 404));

    const countRows = await query<{ count: string }>(
      `SELECT COUNT(*) as count FROM attendance WHERE student_id = $1`,
      [id]
    );
    const total = parseInt(countRows[0]?.count ?? '0', 10);

    const rows = await query(
      `SELECT id, date, time_in, time_out, duration_mins, status, checkin_mode, checkout_mode,
              confidence_in, confidence_out, remarks, created_at
       FROM attendance WHERE student_id = $1
       ORDER BY date DESC
       LIMIT $2 OFFSET $3`,
      [id, limitNum, offset]
    );

    res.json({
      success: true,
      data: {
        records: rows,
        pagination: { page: pageNum, limit: limitNum, total, pages: Math.ceil(total / limitNum) },
      },
      message: 'Attendance history fetched',
    });
  } catch (err) {
    next(err);
  }
}
