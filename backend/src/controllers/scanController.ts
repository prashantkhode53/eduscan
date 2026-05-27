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

/** Positive minutes elapsed from prevTime to curTime (TIME strings "HH:MM:SS"). */
function minutesSince(prevTime: string, curTime: string): number {
  const [ph, pm, ps = 0] = prevTime.split(':').map(Number);
  const [ch, cm, cs = 0] = curTime.split(':').map(Number);
  const prev = ph * 60 + pm + ps / 60;
  const cur  = ch * 60 + cm + cs / 60;
  return cur - prev; // negative means curTime is before prevTime (rare edge)
}

export async function scan(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { embedding, mode, timestamp } = req.body;

    // ── Validate input ─────────────────────────────────────────────────────
    if (!embedding || !Array.isArray(embedding) || embedding.length !== 128) {
      res.status(400).json({
        success: false,
        message: 'Invalid face embedding: must be an array of 128 numbers',
      });
      return;
    }
    if (mode !== 'checkin' && mode !== 'checkout') {
      res.status(400).json({
        success: false,
        message: "mode must be 'checkin' or 'checkout'",
      });
      return;
    }

    // ── Load settings ──────────────────────────────────────────────────────
    const settingsRows = await query<{ key: string; value: string }>(
      `SELECT key, value FROM settings`
    );
    const settings: Record<string, string> = {};
    for (const row of settingsRows) settings[row.key] = row.value;

    // Face recognition threshold — default 0.75 (requires good match quality)
    const threshold = parseFloat(settings['face_threshold'] ?? '0.75');

    const scanTime = timestamp ? new Date(timestamp) : new Date();
    const today    = scanTime.toISOString().split('T')[0];
    const timeStr  = scanTime.toTimeString().split(' ')[0]; // HH:MM:SS

    console.log(`[scan] mode=${mode} time=${timeStr} threshold=${threshold}`);

    // ── Load ALL active students ───────────────────────────────────────────
    const students = await query<StudentRow>(
      `SELECT id, first_name, last_name, class_grade, division, roll_no, face_embedding
       FROM students WHERE status = 'active'`
    );

    if (students.length === 0) {
      res.json({
        success: false,
        action: 'unknown',
        message: 'No registered students found. Please register students first.',
      });
      return;
    }

    // ── Face matching: find best cosine-similarity match ───────────────────
    let best: { student: StudentRow; confidence: number } | null = null;
    let secondBestScore = 0;
    const topMatches: Array<{ id: string; name: string; score: number }> = [];

    for (const s of students) {
      const raw = s.face_embedding;
      let storedEmb: number[];
      try {
        storedEmb = typeof raw === 'string' ? JSON.parse(raw) : Array.isArray(raw) ? (raw as number[]) : [];
      } catch {
        storedEmb = [];
      }
      if (storedEmb.length === 0) continue;

      const score = cosineSimilarity(embedding as number[], storedEmb);
      topMatches.push({ id: s.id, name: `${s.first_name} ${s.last_name}`, score });

      if (score > (best?.confidence ?? 0)) {
        secondBestScore = best?.confidence ?? 0;
        best = { student: s, confidence: Math.round(score * 10000) / 10000 };
      } else if (score > secondBestScore) {
        secondBestScore = score;
      }
    }

    // Log top-3 for debugging
    topMatches.sort((a, b) => b.score - a.score);
    const top3 = topMatches.slice(0, 3);
    console.log(`[scan] top-3 matches: ${top3.map(m => `${m.name}=${m.score.toFixed(4)}`).join(', ')}`);
    console.log(`[scan] best=${best?.confidence ?? 'none'} threshold=${threshold} students=${students.length}`);

    // ── Threshold check ────────────────────────────────────────────────────
    if (!best || best.confidence < threshold) {
      const bestScore = best?.confidence ?? 0;
      console.log(`[scan] REJECTED: best_score=${bestScore.toFixed(4)} < threshold=${threshold}`);
      res.json({
        success: false,
        action: 'unknown',
        confidence: bestScore,
        message: bestScore > 0
          ? `No registered face found. Best match score: ${(bestScore * 100).toFixed(1)}% (required: ${(threshold * 100).toFixed(0)}%)`
          : 'Unknown face detected. No registered face found.',
      });
      return;
    }

    // ── Margin check — reject ambiguous matches ────────────────────────────
    // Require a minimum gap between the top-2 scores to prevent cases like
    // "Shrikant's face scored 0.76 against Komal K's stored embedding."
    const margin = best.confidence - secondBestScore;
    const minMargin = 0.08;
    if (students.length > 1 && margin < minMargin) {
      console.log(`[scan] AMBIGUOUS: best=${best.confidence.toFixed(4)} second=${secondBestScore.toFixed(4)} gap=${margin.toFixed(4)} < ${minMargin}`);
      res.json({
        success: false,
        action: 'unknown',
        confidence: best.confidence,
        message: `Ambiguous face match (${(best.confidence * 100).toFixed(1)}%, gap ${(margin * 100).toFixed(1)}%). Please face the camera directly and re-scan.`,
      });
      return;
    }

    console.log(`[scan] MATCHED: ${best.student.first_name} ${best.student.last_name} score=${best.confidence}`);

    const student = best.student;
    const studentPayload = {
      id:          student.id,
      first_name:  student.first_name,
      last_name:   student.last_name,
      class_grade: student.class_grade,
      division:    student.division,
      roll_no:     student.roll_no,
    };

    // ── Get today's attendance record ──────────────────────────────────────
    const existing = await queryOne<AttendanceRow>(
      `SELECT id, time_in, time_out, duration_mins, status
       FROM attendance WHERE student_id = $1 AND date = $2`,
      [student.id, today]
    );

    // ── 10-minute duplicate prevention ────────────────────────────────────
    // If the same student scanned within the last 10 minutes in the same mode,
    // return duplicate so they don't get double-recorded by accident.
    if (mode === 'checkin' && existing?.time_in) {
      const diffMins = minutesSince(existing.time_in, timeStr);
      if (diffMins >= 0 && diffMins < 10) {
        console.log(`[scan] DUPLICATE check-in: ${student.id} ${Math.floor(diffMins)}m ago`);
        res.json({
          success: true,
          action: 'duplicate',
          student: studentPayload,
          time_in: existing.time_in,
          confidence: best.confidence,
          message: `Already checked in at ${existing.time_in} (${Math.floor(diffMins)} min ago). Duplicate scan blocked for 10 minutes.`,
        });
        return;
      }
    }
    if (mode === 'checkout' && existing?.time_out) {
      const diffMins = minutesSince(existing.time_out, timeStr);
      if (diffMins >= 0 && diffMins < 10) {
        console.log(`[scan] DUPLICATE check-out: ${student.id} ${Math.floor(diffMins)}m ago`);
        res.json({
          success: true,
          action: 'duplicate',
          student: studentPayload,
          time_in: existing.time_in,
          time_out: existing.time_out,
          duration_mins: existing.duration_mins,
          confidence: best.confidence,
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
        [student.id, today, timeStr, best.confidence]
      );

      const recordedTimeIn = rows[0]?.time_in ?? timeStr;
      console.log(`[scan] CHECK-IN recorded: ${student.id} at ${recordedTimeIn}`);

      res.json({
        success: true,
        action: 'checkin',
        student: studentPayload,
        time_in: recordedTimeIn,
        confidence: best.confidence,
        message: `Face matched successfully! Check-in recorded for ${student.first_name} ${student.last_name} at ${recordedTimeIn}`,
      });
      return;
    }

    // ── Process check-out ──────────────────────────────────────────────────
    if (!existing?.time_in) {
      console.log(`[scan] CHECKOUT without check-in: ${student.id}`);
      res.json({
        success: false,
        action: 'error',
        student: studentPayload,
        confidence: best.confidence,
        message: 'No check-in found for today. Please check in first.',
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

    console.log(`[scan] CHECK-OUT recorded: ${student.id} at ${timeStr} duration=${durationMins}m`);

    res.json({
      success: true,
      action: 'checkout',
      student: studentPayload,
      time_in: existing.time_in,
      time_out: timeStr,
      duration_mins: durationMins,
      confidence: best.confidence,
      message: `Face matched successfully! Check-out recorded for ${student.first_name} ${student.last_name}. Duration: ${Math.floor(durationMins / 60)}h ${durationMins % 60}m`,
    });
  } catch (err) {
    next(err);
  }
}
