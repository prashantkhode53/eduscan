import { Request, Response, NextFunction } from 'express';
import { query, queryOne } from '../db/pool';
import { Attendance, BatchAttendanceRequest, ApiResponse } from '../types';
import { AppError } from '../middleware/errorHandler';

export async function listAttendance(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const {
      date,
      date_from,
      date_to,
      class: classGrade,
      division,
      student_id,
      page = '1',
      limit = '100',
    } = req.query as Record<string, string>;

    const pageNum = Math.max(1, parseInt(page, 10));
    const limitNum = Math.min(500, Math.max(1, parseInt(limit, 10)));
    const offset = (pageNum - 1) * limitNum;

    const conditions: string[] = [];
    const params: unknown[] = [];
    let idx = 1;

    if (date) {
      conditions.push(`a.date = $${idx++}`);
      params.push(date);
    } else {
      if (date_from) { conditions.push(`a.date >= $${idx++}`); params.push(date_from); }
      if (date_to)   { conditions.push(`a.date <= $${idx++}`); params.push(date_to);   }
    }
    if (student_id) { conditions.push(`a.student_id = $${idx++}`); params.push(student_id); }
    if (classGrade) { conditions.push(`s.class_grade = $${idx++}`); params.push(classGrade); }
    if (division)   { conditions.push(`s.division = $${idx++}`);    params.push(division);   }

    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

    const countRows = await query<{ count: string }>(
      `SELECT COUNT(*) as count FROM attendance a JOIN students s ON a.student_id = s.id ${where}`,
      params
    );
    const total = parseInt(countRows[0]?.count ?? '0', 10);

    const rows = await query(
      `SELECT a.*, s.first_name, s.last_name, s.class_grade, s.division, s.roll_no
       FROM attendance a JOIN students s ON a.student_id = s.id
       ${where}
       ORDER BY a.date DESC, s.class_grade, s.roll_no
       LIMIT $${idx} OFFSET $${idx + 1}`,
      [...params, limitNum, offset]
    );

    res.json({
      success: true,
      data: { records: rows, pagination: { page: pageNum, limit: limitNum, total, pages: Math.ceil(total / limitNum) } },
      message: 'Attendance fetched',
    } as ApiResponse<unknown>);
  } catch (err) {
    next(err);
  }
}

export async function createAttendance(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const body = req.body as Partial<Attendance>;
    if (!body.student_id || !body.date) {
      return next(new AppError('student_id and date are required', 400));
    }

    const student = await queryOne<{ id: string }>(`SELECT id FROM students WHERE id = $1`, [body.student_id]);
    if (!student) return next(new AppError('Student not found', 404));

    const adminId = req.admin?.id ?? null;

    const rows = await query<Attendance>(
      `INSERT INTO attendance (student_id, date, time_in, time_out, duration_mins, status,
                               checkin_mode, checkout_mode, confidence_in, confidence_out, remarks, marked_by)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
       ON CONFLICT (student_id, date) DO UPDATE
         SET time_in       = COALESCE(EXCLUDED.time_in, attendance.time_in),
             time_out      = COALESCE(EXCLUDED.time_out, attendance.time_out),
             duration_mins = COALESCE(EXCLUDED.duration_mins, attendance.duration_mins),
             status        = EXCLUDED.status,
             checkin_mode  = EXCLUDED.checkin_mode,
             remarks       = COALESCE(EXCLUDED.remarks, attendance.remarks),
             marked_by     = EXCLUDED.marked_by
       RETURNING *`,
      [
        body.student_id, body.date,
        body.time_in ?? null, body.time_out ?? null, body.duration_mins ?? null,
        body.status ?? 'present',
        body.checkin_mode ?? 'admin_manual', body.checkout_mode ?? 'not_recorded',
        body.confidence_in ?? null, body.confidence_out ?? null,
        body.remarks ?? null, adminId,
      ]
    );

    res.status(201).json({ success: true, data: rows[0], message: 'Attendance recorded' });
  } catch (err) {
    next(err);
  }
}

export async function updateAttendance(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { id } = req.params;
    const body = req.body as Partial<Attendance>;

    const existing = await queryOne<{ id: string }>(`SELECT id FROM attendance WHERE id = $1`, [id]);
    if (!existing) return next(new AppError('Attendance record not found', 404));

    const fields: string[] = [];
    const values: unknown[] = [];
    let idx = 1;

    const allowed: (keyof Attendance)[] = [
      'status', 'time_in', 'time_out', 'duration_mins', 'checkin_mode',
      'checkout_mode', 'confidence_in', 'confidence_out', 'remarks',
    ];
    for (const key of allowed) {
      if (body[key] !== undefined) {
        fields.push(`${key} = $${idx++}`);
        values.push(body[key]);
      }
    }
    if (fields.length === 0) return next(new AppError('No fields to update', 400));

    values.push(id);
    const rows = await query(
      `UPDATE attendance SET ${fields.join(', ')} WHERE id = $${idx} RETURNING *`,
      values
    );

    res.json({ success: true, data: rows[0], message: 'Attendance updated' });
  } catch (err) {
    next(err);
  }
}

export async function batchAttendance(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { records } = req.body as BatchAttendanceRequest;
    if (!Array.isArray(records) || records.length === 0) {
      return next(new AppError('records array is required and must not be empty', 400));
    }

    let inserted = 0;
    for (const rec of records) {
      if (!rec.student_id || !rec.date) continue;
      await query(
        `INSERT INTO attendance (student_id, date, time_in, time_out, duration_mins, status,
                                 checkin_mode, checkout_mode, confidence_in, confidence_out, remarks)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
         ON CONFLICT (student_id, date) DO UPDATE
           SET time_in       = COALESCE(EXCLUDED.time_in, attendance.time_in),
               time_out      = COALESCE(EXCLUDED.time_out, attendance.time_out),
               duration_mins = COALESCE(EXCLUDED.duration_mins, attendance.duration_mins),
               status        = EXCLUDED.status`,
        [
          rec.student_id, rec.date,
          rec.time_in ?? null, rec.time_out ?? null, rec.duration_mins ?? null,
          rec.status ?? 'present',
          rec.checkin_mode ?? 'face_auto', rec.checkout_mode ?? 'not_recorded',
          rec.confidence_in ?? null, rec.confidence_out ?? null, rec.remarks ?? null,
        ]
      );
      inserted++;
    }

    res.json({ success: true, data: { processed: inserted }, message: `${inserted} records synced` });
  } catch (err) {
    next(err);
  }
}

export async function bulkMarkAbsent(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { date, class_grade, division } = req.body as {
      date: string;
      class_grade?: string;
      division?: string;
    };
    if (!date) return next(new AppError('date is required', 400));

    const conditions: string[] = [];
    const params: unknown[] = [date];
    let idx = 2;

    if (class_grade) { conditions.push(`class_grade = $${idx++}`); params.push(class_grade); }
    if (division)    { conditions.push(`division = $${idx++}`);    params.push(division);    }

    const where = conditions.length > 0 ? `AND ${conditions.join(' AND ')}` : '';

    const studentRows = await query<{ id: string }>(
      `SELECT id FROM students WHERE status = 'active' ${where}`,
      params.slice(1)
    );

    let marked = 0;
    for (const s of studentRows) {
      await query(
        `INSERT INTO attendance (student_id, date, status, checkin_mode, checkout_mode)
         VALUES ($1, $2, 'absent', 'admin_manual', 'not_recorded')
         ON CONFLICT (student_id, date) DO NOTHING`,
        [s.id, date]
      );
      marked++;
    }

    res.json({ success: true, data: { marked }, message: `${marked} students marked absent` });
  } catch (err) {
    next(err);
  }
}
