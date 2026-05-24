import { Request, Response, NextFunction } from 'express';
import { query, queryOne } from '../db/pool';
import { Student, ScanRequest, ScanResponse } from '../types';
import { AppError } from '../middleware/errorHandler';
import { findBestMatch } from '../utils/faceMatch';

interface SettingsRow { key: string; value: string; }
interface AttendanceRow {
  id: string;
  time_in: string | null;
  time_out: string | null;
  duration_mins: number | null;
  status: string;
}

function timeToMinutes(t: string): number {
  const [h, m] = t.split(':').map(Number);
  return h * 60 + m;
}

export async function scan(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const body = req.body as ScanRequest;
    const { embedding, mode, class_id, timestamp } = body;

    if (!embedding || !Array.isArray(embedding) || embedding.length !== 128) {
      return next(new AppError('Invalid face embedding: must be array of 128 numbers', 400));
    }
    if (mode !== 'checkin' && mode !== 'checkout') {
      return next(new AppError("mode must be 'checkin' or 'checkout'", 400));
    }
    if (!class_id) return next(new AppError('class_id is required', 400));

    // Load settings
    const settingsRows = await query<SettingsRow>(`SELECT key, value FROM settings`);
    const settings: Record<string, string> = {};
    for (const row of settingsRows) settings[row.key] = row.value;

    const hoursStart = settings['school_hours_start'] ?? '07:00';
    const hoursEnd   = settings['school_hours_end']   ?? '18:00';
    const threshold  = parseFloat(settings['face_threshold'] ?? '0.4');

    // Check school hours
    const scanTime = timestamp ? new Date(timestamp) : new Date();
    const scanMinutes = scanTime.getHours() * 60 + scanTime.getMinutes();
    const startMinutes = timeToMinutes(hoursStart);
    const endMinutes   = timeToMinutes(hoursEnd);

    if (scanMinutes < startMinutes || scanMinutes > endMinutes) {
      const response: ScanResponse = {
        success: false,
        action: 'outside_hours',
        message: `Scanning is only allowed between ${hoursStart} and ${hoursEnd}`,
      };
      res.json(response);
      return;
    }

    // Parse class_id: expected format "grade-division" e.g. "10-A"
    const parts = class_id.split('-');
    const classGrade = parts[0];
    const division = parts[1];

    const conditions: string[] = [`status = 'active'`];
    const params: unknown[] = [];
    let idx = 1;
    if (classGrade) { conditions.push(`class_grade = $${idx++}`); params.push(classGrade); }
    if (division)   { conditions.push(`division = $${idx++}`);    params.push(division);   }

    const students = await query<Student>(
      `SELECT id, first_name, last_name, class_grade, division, roll_no, face_embedding, status,
              mobile, email, institution
       FROM students WHERE ${conditions.join(' AND ')}`,
      params
    );

    // Parse face_embedding JSONB
    const studentsWithEmbedding: Student[] = students.map((s) => ({
      ...s,
      face_embedding: Array.isArray(s.face_embedding)
        ? s.face_embedding
        : (JSON.parse(s.face_embedding as unknown as string) as number[]),
    }));

    const match = findBestMatch(embedding, studentsWithEmbedding, threshold);

    console.log(`[scan] class=${class_id} students=${studentsWithEmbedding.length} threshold=${threshold} bestScore=${match?.confidence ?? 'no_match'}`);

    if (!match) {
      const response: ScanResponse = {
        success: false,
        action: 'unknown',
        message: 'Face not recognised. Please register or try again.',
      };
      res.json(response);
      return;
    }

    const today = scanTime.toISOString().split('T')[0];
    const timeStr = scanTime.toTimeString().split(' ')[0]; // HH:MM:SS

    const existingRecord = await queryOne<AttendanceRow>(
      `SELECT id, time_in, time_out, duration_mins, status FROM attendance
       WHERE student_id = $1 AND date = $2`,
      [match.student.id, today]
    );

    if (mode === 'checkin') {
      if (existingRecord && existingRecord.time_in) {
        const response: ScanResponse = {
          success: true,
          action: 'duplicate',
          student: {
            id: match.student.id,
            first_name: match.student.first_name,
            last_name: match.student.last_name,
            class_grade: match.student.class_grade,
            division: match.student.division,
            roll_no: match.student.roll_no,
          },
          time_in: existingRecord.time_in,
          message: `Already checked in at ${existingRecord.time_in}. Use check out.`,
        };
        res.json(response);
        return;
      }

      const rows = await query<AttendanceRow>(
        `INSERT INTO attendance (student_id, date, time_in, status, checkin_mode, confidence_in)
         VALUES ($1, $2, $3, 'present', 'face_auto', $4)
         ON CONFLICT (student_id, date) DO UPDATE
           SET time_in = $3, status = 'present', checkin_mode = 'face_auto', confidence_in = $4
         RETURNING *`,
        [match.student.id, today, timeStr, match.confidence]
      );

      const response: ScanResponse = {
        success: true,
        action: 'checkin',
        student: {
          id: match.student.id,
          first_name: match.student.first_name,
          last_name: match.student.last_name,
          class_grade: match.student.class_grade,
          division: match.student.division,
          roll_no: match.student.roll_no,
        },
        time_in: rows[0].time_in ?? timeStr,
        message: `Check-in recorded for ${match.student.first_name} ${match.student.last_name}`,
      };
      res.json(response);
      return;
    }

    // Checkout
    if (!existingRecord || !existingRecord.time_in) {
      const response: ScanResponse = {
        success: false,
        action: 'error',
        student: {
          id: match.student.id,
          first_name: match.student.first_name,
          last_name: match.student.last_name,
        },
        message: 'No check-in found for today. Please check in first.',
      };
      res.json(response);
      return;
    }

    if (existingRecord.time_out) {
      const response: ScanResponse = {
        success: true,
        action: 'duplicate',
        student: {
          id: match.student.id,
          first_name: match.student.first_name,
          last_name: match.student.last_name,
          class_grade: match.student.class_grade,
          division: match.student.division,
          roll_no: match.student.roll_no,
        },
        time_in: existingRecord.time_in,
        time_out: existingRecord.time_out,
        duration_mins: existingRecord.duration_mins ?? undefined,
        message: `Already checked out at ${existingRecord.time_out}.`,
      };
      res.json(response);
      return;
    }

    // Compute duration
    const [ih, im, is_] = existingRecord.time_in.split(':').map(Number);
    const [oh, om, os_] = timeStr.split(':').map(Number);
    const inMins = ih * 60 + im + (is_ ?? 0) / 60;
    const outMins = oh * 60 + om + (os_ ?? 0) / 60;
    const durationMins = Math.max(0, Math.round(outMins - inMins));

    await query(
      `UPDATE attendance
       SET time_out = $1, duration_mins = $2, checkout_mode = 'face_auto', confidence_out = $3
       WHERE student_id = $4 AND date = $5`,
      [timeStr, durationMins, match.confidence, match.student.id, today]
    );

    const response: ScanResponse = {
      success: true,
      action: 'checkout',
      student: {
        id: match.student.id,
        first_name: match.student.first_name,
        last_name: match.student.last_name,
        class_grade: match.student.class_grade,
        division: match.student.division,
        roll_no: match.student.roll_no,
      },
      time_in: existingRecord.time_in,
      time_out: timeStr,
      duration_mins: durationMins,
      message: `Check-out recorded. Duration: ${Math.floor(durationMins / 60)}h ${durationMins % 60}m`,
    };
    res.json(response);
  } catch (err) {
    next(err);
  }
}
