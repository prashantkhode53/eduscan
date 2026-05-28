import { Request, Response, NextFunction } from 'express';
import { query, queryOne } from '../db/pool';
import { Student, ApiResponse, AttendanceSummary } from '../types';
import { AppError } from '../middleware/errorHandler';
import { generateStudentId } from '../utils/studentIdGenerator';
import { validateEmbedding } from '../utils/validators';
import { cosineSimilarity } from '../utils/faceMatch';

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
    const body = req.body as Partial<Student> & { face_embedding: unknown };
    const embedding = validateEmbedding(body.face_embedding);

    const required: (keyof Student)[] = [
      'first_name', 'last_name', 'dob', 'gender', 'institution',
      'academic_year', 'class_grade', 'division', 'admission_date',
      'parent_name', 'mobile',
    ];
    for (const field of required) {
      if (!body[field]) throw new AppError(`Field '${field}' is required`, 400);
    }

    // ── Duplicate face detection ──────────────────────────────────────────
    // Compare the incoming embedding against every active student.
    // Similarity ≥ 0.88 means the faces are nearly identical — almost certainly
    // the same physical person trying to register a second account.
    const DUPE_THRESHOLD = 0.88;
    const existingForDupe = await query<{
      id: string; first_name: string; last_name: string; face_embedding: unknown;
    }>(`SELECT id, first_name, last_name, face_embedding FROM students WHERE status = 'active'`);

    for (const s of existingForDupe) {
      const raw = s.face_embedding;
      let stored: number[];
      try {
        stored = typeof raw === 'string' ? JSON.parse(raw) : Array.isArray(raw) ? (raw as number[]) : [];
      } catch {
        stored = [];
      }
      if (stored.length === 0) continue;
      const sim = cosineSimilarity(embedding, stored);
      if (sim >= DUPE_THRESHOLD) {
        throw new AppError(
          `Face already registered — ${(sim * 100).toFixed(1)}% match with ${s.first_name} ${s.last_name} (ID: ${s.id}). Re-capture with a clearer image or contact admin if this is a different student.`,
          409
        );
      }
    }

    const id = await generateStudentId();

    const rollNo = body.roll_no != null ? parseInt(String(body.roll_no), 10) : null;
    const faceQuality = body.face_quality != null ? parseFloat(String(body.face_quality)) : null;

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
    const body = req.body as Partial<Student> & { face_embedding?: unknown };

    const existing = await queryOne<{ id: string }>(`SELECT id FROM students WHERE id = $1`, [id]);
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

    if (body.face_embedding !== undefined) {
      const embedding = validateEmbedding(body.face_embedding);
      fields.push(`face_embedding = $${idx++}`);
      values.push(JSON.stringify(embedding));
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
 * Admin diagnostic: returns all pairs of active students whose stored face
 * embeddings are suspiciously similar (cosine ≥ 0.85).  A high score means
 * the same physical face was likely registered under two different IDs —
 * the admin should delete one record.
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

    // Parse all embeddings once
    const students = rows.map(s => {
      const raw = s.face_embedding;
      let emb: number[];
      try { emb = typeof raw === 'string' ? JSON.parse(raw) : Array.isArray(raw) ? (raw as number[]) : []; }
      catch { emb = []; }
      return { ...s, emb };
    }).filter(s => s.emb.length > 0);

    const SUSPICIOUS_THRESHOLD = 0.85;
    const pairs: Array<{
      studentA: { id: string; name: string; class_grade: string; division: string };
      studentB: { id: string; name: string; class_grade: string; division: string };
      similarity: number;
      severity: string;
    }> = [];

    for (let i = 0; i < students.length; i++) {
      for (let j = i + 1; j < students.length; j++) {
        const sim = cosineSimilarity(students[i].emb, students[j].emb);
        if (sim >= SUSPICIOUS_THRESHOLD) {
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
          ? 'Delete one student from each DUPLICATE pair. Students with SUSPICIOUS similarity may need re-registration.'
          : 'No duplicate face embeddings found.',
      },
      message: pairs.length > 0
        ? `Found ${pairs.length} suspicious embedding pair(s). Duplicate registrations must be removed.`
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
