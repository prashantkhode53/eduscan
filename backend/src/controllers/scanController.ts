import { Request, Response, NextFunction } from 'express';
import { query, queryOne } from '../db/pool';
import { matchFace } from '../utils/insightface';

interface AttendanceRow {
  id: string;
  time_in: string | null;
  time_out: string | null;
  duration_mins: number | null;
  status: string;
}

/** Positive minutes elapsed from prevTime to curTime (TIME strings "HH:MM:SS"). */
function minutesSince(prevTime: string, curTime: string): number {
  const [ph, pm, ps = 0] = prevTime.split(':').map(Number);
  const [ch, cm, cs = 0] = curTime.split(':').map(Number);
  const prev = ph * 60 + pm + ps / 60;
  const cur  = ch * 60 + cm + cs / 60;
  return cur - prev;
}

export async function scan(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { image_base64, mode, timestamp } = req.body as {
      image_base64?: string;
      mode?: string;
      timestamp?: string;
    };

    // ── Validate input ─────────────────────────────────────────────────────
    if (!image_base64 || typeof image_base64 !== 'string') {
      res.status(400).json({ success: false, message: 'image_base64 is required (JPEG as base64 string)' });
      return;
    }
    if (mode !== 'checkin' && mode !== 'checkout') {
      res.status(400).json({ success: false, message: "mode must be 'checkin' or 'checkout'" });
      return;
    }

    const scanTime = timestamp ? new Date(timestamp) : new Date();
    const today   = scanTime.toISOString().split('T')[0];
    const timeStr = scanTime.toTimeString().split(' ')[0]; // HH:MM:SS

    console.log(`[scan] mode=${mode} time=${timeStr}`);

    // ── Face matching via Python InsightFace service ────────────────────────
    let matchResult;
    try {
      matchResult = await matchFace(image_base64);
    } catch (err) {
      console.error('[scan] InsightFace service error:', err);
      res.status(503).json({
        success: false,
        action: 'error',
        message: 'Face recognition service unavailable. Please try again.',
      });
      return;
    }

    // ── Quality / detection failure ────────────────────────────────────────
    if (!matchResult.success || matchResult.matched === undefined) {
      res.json({
        success: false,
        action: 'unknown',
        message: 'Face detection failed. Ensure your face is clearly visible.',
        quality: matchResult.quality ?? 0,
      });
      return;
    }

    // ── No face / quality rejection returned by Python ─────────────────────
    if (!matchResult.matched) {
      const reason = matchResult.reason ?? 'below_threshold';
      const confidence = matchResult.confidence ?? 0;
      console.log(`[scan] NOT MATCHED: reason=${reason} score=${confidence}`);

      if (reason === 'ambiguous_match') {
        res.json({
          success: false,
          action: 'ambiguous',
          confidence,
          message: `Face match is ambiguous (${(confidence * 100).toFixed(1)}%, gap ${((matchResult.margin ?? 0) * 100).toFixed(1)}%). Face the camera directly and try again. If this persists, re-register.`,
        });
        return;
      }

      res.json({
        success: false,
        action: reason === 'no_face_detected' || reason === 'no_registered_faces' ? 'unknown' : 'unknown',
        confidence,
        message: confidence > 0
          ? `No registered face found. Best match score: ${(confidence * 100).toFixed(1)}%`
          : 'Unknown face detected. No registered face found.',
      });
      return;
    }

    // ── Matched ────────────────────────────────────────────────────────────
    const studentId = matchResult.student_id!;
    const confidence = matchResult.confidence!;
    const meta = matchResult.student!;

    console.log(`[scan] MATCHED: ${meta.first_name} ${meta.last_name} score=${confidence}`);

    // Fetch minimal data not stored in Redis (status check)
    const dbStudent = await queryOne<{ id: string; status: string }>(
      `SELECT id, status FROM students WHERE id = $1`,
      [studentId]
    );

    if (!dbStudent || dbStudent.status !== 'active') {
      res.json({
        success: false,
        action: 'unknown',
        message: 'Student not found or inactive.',
      });
      return;
    }

    const studentPayload = {
      id:          studentId,
      first_name:  meta.first_name,
      last_name:   meta.last_name,
      class_grade: meta.class_grade,
      division:    meta.division,
      roll_no:     meta.roll_no,
    };

    // ── Get today's attendance record ──────────────────────────────────────
    const existing = await queryOne<AttendanceRow>(
      `SELECT id, time_in, time_out, duration_mins, status
       FROM attendance WHERE student_id = $1 AND date = $2`,
      [studentId, today]
    );

    // ── 10-minute duplicate prevention ────────────────────────────────────
    if (mode === 'checkin' && existing?.time_in) {
      const diffMins = minutesSince(existing.time_in, timeStr);
      if (diffMins >= 0 && diffMins < 10) {
        console.log(`[scan] DUPLICATE check-in: ${studentId} ${Math.floor(diffMins)}m ago`);
        res.json({
          success: true,
          action: 'duplicate',
          student: studentPayload,
          time_in: existing.time_in,
          confidence,
          message: `Already checked in at ${existing.time_in} (${Math.floor(diffMins)} min ago). Duplicate scan blocked for 10 minutes.`,
        });
        return;
      }
    }
    if (mode === 'checkout' && existing?.time_out) {
      const diffMins = minutesSince(existing.time_out, timeStr);
      if (diffMins >= 0 && diffMins < 10) {
        console.log(`[scan] DUPLICATE check-out: ${studentId} ${Math.floor(diffMins)}m ago`);
        res.json({
          success: true,
          action: 'duplicate',
          student: studentPayload,
          time_in: existing.time_in,
          time_out: existing.time_out,
          duration_mins: existing.duration_mins,
          confidence,
          message: `Already checked out at ${existing.time_out} (${Math.floor(diffMins)} min ago). Duplicate scan blocked for 10 minutes.`,
        });
        return;
      }
    }

    // ── Process check-in ───────────────────────────────────────────────────
    if (mode === 'checkin') {
      const rows = await query<{ time_in: string | null }>(
        `INSERT INTO attendance (student_id, date, time_in, status, checkin_mode, confidence_in)
         VALUES ($1, $2, $3, 'present', 'face_auto', $4)
         ON CONFLICT (student_id, date) DO UPDATE
           SET time_in = $3, status = 'present', checkin_mode = 'face_auto', confidence_in = $4
         RETURNING time_in`,
        [studentId, today, timeStr, confidence]
      );

      const recordedTimeIn = rows[0]?.time_in ?? timeStr;
      console.log(`[scan] CHECK-IN recorded: ${studentId} at ${recordedTimeIn}`);

      res.json({
        success: true,
        action: 'checkin',
        student: studentPayload,
        time_in: recordedTimeIn,
        confidence,
        message: `Face matched! Check-in recorded for ${meta.first_name} ${meta.last_name} at ${recordedTimeIn}`,
      });
      return;
    }

    // ── Process check-out ──────────────────────────────────────────────────
    if (!existing?.time_in) {
      console.log(`[scan] CHECKOUT without check-in: ${studentId}`);
      res.json({
        success: false,
        action: 'error',
        student: studentPayload,
        confidence,
        message: 'No check-in found for today. Please check in first.',
      });
      return;
    }

    const [ih, im, is_] = existing.time_in.split(':').map(Number);
    const [oh, om, os_] = timeStr.split(':').map(Number);
    const inMins        = ih * 60 + im + (is_ ?? 0) / 60;
    const outMins       = oh * 60 + om + (os_ ?? 0) / 60;
    const durationMins  = Math.max(0, Math.round(outMins - inMins));

    await query(
      `UPDATE attendance
       SET time_out = $1, duration_mins = $2, checkout_mode = 'face_auto', confidence_out = $3
       WHERE student_id = $4 AND date = $5`,
      [timeStr, durationMins, confidence, studentId, today]
    );

    console.log(`[scan] CHECK-OUT recorded: ${studentId} at ${timeStr} duration=${durationMins}m`);

    res.json({
      success: true,
      action: 'checkout',
      student: studentPayload,
      time_in: existing.time_in,
      time_out: timeStr,
      duration_mins: durationMins,
      confidence,
      message: `Face matched! Check-out recorded for ${meta.first_name} ${meta.last_name}. Duration: ${Math.floor(durationMins / 60)}h ${durationMins % 60}m`,
    });
  } catch (err) {
    next(err);
  }
}
