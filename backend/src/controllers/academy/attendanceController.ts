import { Request, Response, NextFunction } from 'express';
import { academyQuery, academyQueryOne } from '../../db/poolManager';
import { batchEmbed } from '../../utils/insightface';
import { cosineSimilarity } from '../../utils/faceMatch';

interface StudentRow {
  id: string;
  first_name: string;
  last_name: string;
  mobile: string;
  face_embedding: unknown;
}

interface AttendanceRow {
  id: string;
  time_in: string | null;
  time_out: string | null;
  duration_mins: number | null;
}

function minutesSince(prevTime: string, curTime: string): number {
  const [ph, pm, ps = 0] = prevTime.split(':').map(Number);
  const [ch, cm, cs = 0] = curTime.split(':').map(Number);
  return (ch * 60 + cm + cs / 60) - (ph * 60 + pm + ps / 60);
}

// ── POST /api/academy/attendance/scan ─────────────────────────────────────────

export async function scanAcademy(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { image_base64, mode } = req.body as {
      image_base64?: string;
      mode?: string;
    };

    if (!image_base64 || typeof image_base64 !== 'string') {
      res.status(400).json({ success: false, message: 'image_base64 is required' });
      return;
    }
    if (mode !== 'checkin' && mode !== 'checkout') {
      res.status(400).json({ success: false, message: "mode must be 'checkin' or 'checkout'" });
      return;
    }

    const now     = new Date();
    const today   = now.toISOString().split('T')[0];
    const timeStr = now.toTimeString().split(' ')[0]; // HH:MM:SS

    // 1. Extract 512-D ArcFace embedding from the scan image
    let embed;
    try {
      embed = await batchEmbed([image_base64]);
    } catch (err) {
      console.error('[academy/scan] InsightFace error:', err);
      res.status(503).json({
        success: false,
        action: 'error',
        message: 'Face recognition service unavailable. Please try again.',
      });
      return;
    }

    if (!embed.success || !embed.embedding) {
      res.json({
        success: false,
        action: 'unknown',
        message: embed.reason === 'no_face_detected'
          ? 'No face detected. Look directly at the camera.'
          : 'Face detection failed. Ensure your face is clearly visible.',
      });
      return;
    }

    const incoming = embed.embedding;

    // 2. Load all active academy students with stored face embeddings
    const students = await academyQuery<StudentRow>(
      academySlug,
      `SELECT id, first_name, last_name, mobile, face_embedding
       FROM students
       WHERE status = 'active' AND face_embedding IS NOT NULL`
    );

    if (students.length === 0) {
      res.json({
        success: false,
        action: 'unknown',
        message: 'No registered faces found. Register students with face data first.',
      });
      return;
    }

    // 3. Cosine similarity matching
    const settingRow = await academyQueryOne<{ value: string }>(
      academySlug,
      `SELECT value FROM settings WHERE key = 'face_threshold'`
    );
    const threshold = parseFloat(settingRow?.value ?? '0.75');

    let best: { student: StudentRow; confidence: number } | null = null;
    let secondBest = 0;

    for (const s of students) {
      const raw = s.face_embedding;
      const embedding: number[] = typeof raw === 'string'
        ? JSON.parse(raw)
        : (raw as number[]);
      if (!Array.isArray(embedding) || embedding.length === 0) continue;

      const score = cosineSimilarity(incoming, embedding);
      if (!best || score > best.confidence) {
        secondBest = best?.confidence ?? 0;
        best = { student: s, confidence: score };
      } else if (score > secondBest) {
        secondBest = score;
      }
    }

    if (!best || best.confidence < threshold) {
      res.json({
        success: false,
        action: 'unknown',
        confidence: best?.confidence ?? 0,
        message: best && best.confidence > 0
          ? `No match found. Best score: ${(best.confidence * 100).toFixed(1)}%`
          : 'Face not recognised. Not registered in this academy.',
      });
      return;
    }

    // Ambiguous match guard: top-2 scores within 2% of each other
    if (secondBest >= threshold && (best.confidence - secondBest) < 0.02) {
      res.json({
        success: false,
        action: 'ambiguous',
        confidence: best.confidence,
        message: `Ambiguous match (gap ${((best.confidence - secondBest) * 100).toFixed(1)}%). Try again with better lighting.`,
      });
      return;
    }

    const student    = best.student;
    const confidence = Math.round(best.confidence * 10000) / 10000;

    // 4. Load enrolled courses for display
    const courses = await academyQuery<{ name: string }>(
      academySlug,
      `SELECT c.name FROM courses c
       JOIN student_courses sc ON sc.course_id = c.id
       WHERE sc.student_id = $1 AND sc.status = 'active'
       ORDER BY c.name LIMIT 3`,
      [student.id]
    );
    const courseNames = courses.map(c => c.name).join(', ');

    const studentPayload = {
      id:         student.id,
      first_name: student.first_name,
      last_name:  student.last_name,
      courses:    courseNames,
    };

    // 5. Duplicate-scan prevention (10-minute window)
    const existing = await academyQueryOne<AttendanceRow>(
      academySlug,
      `SELECT id, time_in, time_out, duration_mins FROM attendance
       WHERE student_id = $1 AND date = $2`,
      [student.id, today]
    );

    if (mode === 'checkin' && existing?.time_in) {
      const diffMins = minutesSince(existing.time_in, timeStr);
      if (diffMins >= 0 && diffMins < 10) {
        res.json({
          success: true,
          action: 'duplicate',
          student: studentPayload,
          time_in: existing.time_in,
          confidence,
          message: `Already checked in at ${existing.time_in} (${Math.floor(diffMins)}m ago).`,
        });
        return;
      }
    }
    if (mode === 'checkout' && existing?.time_out) {
      const diffMins = minutesSince(existing.time_out, timeStr);
      if (diffMins >= 0 && diffMins < 10) {
        res.json({
          success: true,
          action: 'duplicate',
          student: studentPayload,
          time_in:       existing.time_in,
          time_out:      existing.time_out,
          duration_mins: existing.duration_mins,
          confidence,
          message: `Already checked out at ${existing.time_out} (${Math.floor(diffMins)}m ago).`,
        });
        return;
      }
    }

    // 6. Write attendance record
    if (mode === 'checkin') {
      await academyQuery(
        academySlug,
        `INSERT INTO attendance (student_id, date, time_in, status, checkin_mode, confidence_in)
         VALUES ($1, $2, $3, 'present', 'face_auto', $4)
         ON CONFLICT (student_id, date) DO UPDATE
           SET time_in = $3, status = 'present', checkin_mode = 'face_auto', confidence_in = $4`,
        [student.id, today, timeStr, confidence]
      );
      console.log(`[academy/scan] CHECK-IN: ${student.id} at ${timeStr} score=${confidence}`);
      res.json({
        success: true,
        action: 'checkin',
        student: studentPayload,
        time_in: timeStr,
        confidence,
        message: `Face matched! Check-in recorded for ${student.first_name} ${student.last_name}`,
      });
      return;
    }

    // Checkout — requires a prior check-in
    if (!existing?.time_in) {
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
    const durationMins  = Math.max(
      0,
      Math.round(
        (oh * 60 + om + (os_ ?? 0) / 60) - (ih * 60 + im + (is_ ?? 0) / 60)
      )
    );

    await academyQuery(
      academySlug,
      `UPDATE attendance
       SET time_out = $1, duration_mins = $2, checkout_mode = 'face_auto', confidence_out = $3
       WHERE student_id = $4 AND date = $5`,
      [timeStr, durationMins, confidence, student.id, today]
    );

    console.log(`[academy/scan] CHECK-OUT: ${student.id} at ${timeStr} duration=${durationMins}m`);
    res.json({
      success: true,
      action: 'checkout',
      student: studentPayload,
      time_in:       existing.time_in,
      time_out:      timeStr,
      duration_mins: durationMins,
      confidence,
      message: `Face matched! Check-out for ${student.first_name} ${student.last_name}. Duration: ${Math.floor(durationMins / 60)}h ${durationMins % 60}m`,
    });
  } catch (err) { next(err); }
}
