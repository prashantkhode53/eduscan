import { Request, Response, NextFunction } from 'express';
import { query, queryOne } from '../db/pool';
import { cosineSimilarity } from '../utils/faceMatch';

interface AttendanceRow {
  id: string;
  time_in: string | null;
  time_out: string | null;
  duration_mins: number | null;
  status: string;
}

interface StudentRow {
  id: string;
  first_name: string;
  last_name: string;
  class_grade: string;
  division: string;
  roll_no: number | null;
  face_embedding: unknown;
}

function timeToMinutes(t: string): number {
  const [h, m] = t.split(':').map(Number);
  return h * 60 + m;
}

export async function scan(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { embedding, mode, class_id, timestamp } = req.body;

    if (!embedding || !Array.isArray(embedding) || embedding.length !== 128) {
      res.status(400).json({ success: false, message: 'Invalid face embedding: must be array of 128 numbers' });
      return;
    }
    if (mode !== 'checkin' && mode !== 'checkout') {
      res.status(400).json({ success: false, message: "mode must be 'checkin' or 'checkout'" });
      return;
    }

    // Load settings in one round-trip
    const settingsRows = await query<{ key: string; value: string }>(`SELECT key, value FROM settings`);
    const settings: Record<string, string> = {};
    for (const row of settingsRows) settings[row.key] = row.value;

    const hoursStart = settings['school_hours_start'] ?? '07:00';
    const hoursEnd   = settings['school_hours_end']   ?? '18:00';
    const threshold  = parseFloat(settings['face_threshold'] ?? '0.35');

    // School hours check
    const scanTime   = timestamp ? new Date(timestamp) : new Date();
    const scanMins   = scanTime.getHours() * 60 + scanTime.getMinutes();
    if (scanMins < timeToMinutes(hoursStart) || scanMins > timeToMinutes(hoursEnd)) {
      res.json({
        success: false,
        action: 'outside_hours',
        message: `Scanning is only allowed between ${hoursStart} and ${hoursEnd}`,
      });
      return;
    }

    // Load ALL active students — no class_id filter so every registered student is searchable
    const students = await query<StudentRow>(
      `SELECT id, first_name, last_name, class_grade, division, roll_no, face_embedding
       FROM students WHERE status = 'active'`
    );

    // Find best cosine-similarity match
    let best: { student: StudentRow; confidence: number } | null = null;
    for (const s of students) {
      const raw = s.face_embedding;
      const storedEmb: number[] =
        typeof raw === 'string' ? JSON.parse(raw) : Array.isArray(raw) ? (raw as number[]) : [];
      if (storedEmb.length === 0) continue;

      const score = cosineSimilarity(embedding as number[], storedEmb);
      console.log(`[scan] student=${s.id} score=${score.toFixed(4)} threshold=${threshold}`);

      if (score >= threshold && (!best || score > best.confidence)) {
        best = { student: s, confidence: Math.round(score * 10000) / 10000 };
      }
    }

    console.log(`[scan] class=${class_id} students=${students.length} threshold=${threshold} bestScore=${best?.confidence ?? 'no_match'}`);

    if (!best) {
      res.json({ success: false, action: 'unknown', message: 'Face not recognised. Please register or try again.' });
      return;
    }

    const student  = best.student;
    const today    = scanTime.toISOString().split('T')[0];
    const timeStr  = scanTime.toTimeString().split(' ')[0]; // HH:MM:SS

    const existing = await queryOne<AttendanceRow>(
      `SELECT id, time_in, time_out, duration_mins, status FROM attendance
       WHERE student_id = $1 AND date = $2`,
      [student.id, today]
    );

    const studentPayload = {
      id:          student.id,
      first_name:  student.first_name,
      last_name:   student.last_name,
      class_grade: student.class_grade,
      division:    student.division,
      roll_no:     student.roll_no,
    };

    if (mode === 'checkin') {
      if (existing?.time_in) {
        res.json({
          success: true,
          action: 'duplicate',
          student: studentPayload,
          time_in: existing.time_in,
          message: `Already checked in at ${existing.time_in}. Use check out.`,
        });
        return;
      }

      const rows = await query<{ time_in: string | null }>(
        `INSERT INTO attendance (student_id, date, time_in, status, checkin_mode, confidence_in)
         VALUES ($1, $2, $3, 'present', 'face_auto', $4)
         ON CONFLICT (student_id, date) DO UPDATE
           SET time_in = $3, status = 'present', checkin_mode = 'face_auto', confidence_in = $4
         RETURNING time_in`,
        [student.id, today, timeStr, best.confidence]
      );

      res.json({
        success: true,
        action: 'checkin',
        student: studentPayload,
        time_in: rows[0].time_in ?? timeStr,
        confidence: best.confidence,
        message: `Check-in recorded for ${student.first_name} ${student.last_name}`,
      });
      return;
    }

    // Checkout
    if (!existing?.time_in) {
      res.json({
        success: false,
        action: 'error',
        student: { id: student.id, first_name: student.first_name, last_name: student.last_name },
        message: 'No check-in found for today. Please check in first.',
      });
      return;
    }

    if (existing.time_out) {
      res.json({
        success: true,
        action: 'duplicate',
        student: studentPayload,
        time_in: existing.time_in,
        time_out: existing.time_out,
        duration_mins: existing.duration_mins ?? undefined,
        message: `Already checked out at ${existing.time_out}.`,
      });
      return;
    }

    // Compute duration
    const [ih, im, is_] = existing.time_in.split(':').map(Number);
    const [oh, om, os_] = timeStr.split(':').map(Number);
    const inMins       = ih * 60 + im + (is_ ?? 0) / 60;
    const outMins      = oh * 60 + om + (os_ ?? 0) / 60;
    const durationMins = Math.max(0, Math.round(outMins - inMins));

    await query(
      `UPDATE attendance
       SET time_out = $1, duration_mins = $2, checkout_mode = 'face_auto', confidence_out = $3
       WHERE student_id = $4 AND date = $5`,
      [timeStr, durationMins, best.confidence, student.id, today]
    );

    res.json({
      success: true,
      action: 'checkout',
      student: studentPayload,
      time_in: existing.time_in,
      time_out: timeStr,
      duration_mins: durationMins,
      confidence: best.confidence,
      message: `Check-out recorded. Duration: ${Math.floor(durationMins / 60)}h ${durationMins % 60}m`,
    });
  } catch (err) {
    next(err);
  }
}
