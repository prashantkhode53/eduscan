import { Request, Response, NextFunction } from 'express';
import bcrypt from 'bcrypt';
import { academyQuery, academyQueryOne } from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';
import { batchEmbed } from '../../utils/insightface';
import { cosineSimilarity } from '../../utils/faceMatch';
import { getActiveEmbeddings, getThreshold, CachedStudent } from '../../db/scanCache';
import { sendFcm } from '../../utils/fcm';

// Converts a "HH:MM:SS" clock string stored in UTC (the attendance TIME columns
// are written from the server clock, which is UTC on Render) → "hh:mm AM/PM" in
// IST for human-readable parent notifications. Adds the +5:30 offset with
// wraparound into the next day.
function to12Hour(timeStr: string): string {
  const [hStr, mStr = '00'] = timeStr.split(':');
  const h = parseInt(hStr, 10);
  const m = parseInt(mStr, 10);
  if (Number.isNaN(h) || Number.isNaN(m)) return timeStr;

  const istTotal = (h * 60 + m + 330) % (24 * 60); // +05:30
  const istH     = Math.floor(istTotal / 60);
  const istM     = istTotal % 60;

  const ampm = istH >= 12 ? 'PM' : 'AM';
  const h12  = istH % 12 === 0 ? 12 : istH % 12;
  return `${h12.toString().padStart(2, '0')}:${istM.toString().padStart(2, '0')} ${ampm}`;
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

    // 1. Extract 512-D ArcFace embedding from the scan image.
    //    12 s timeout: the scan screen only fires once the service is warm, so
    //    a long hang means a degraded service the user should retry.
    let embed;
    try {
      embed = await batchEmbed([image_base64], 12_000);
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

    // 2. Active students with embeddings — served from an in-process cache
    //    (60 s TTL, invalidated on register/face-update/delete) so we don't
    //    transfer and JSON.parse every embedding from Neon on each scan.
    const students = await getActiveEmbeddings(academySlug);

    if (students.length === 0) {
      res.json({
        success: false,
        action: 'unknown',
        message: 'No registered faces found. Register students with face data first.',
      });
      return;
    }

    // 3. Cosine similarity matching (threshold cached in-process too).
    const threshold = await getThreshold(academySlug);

    let best: { student: CachedStudent; confidence: number } | null = null;
    let secondBest = 0;

    for (const s of students) {
      const score = cosineSimilarity(incoming, s.emb);
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

    // 4 + 5. Fetch courses (display only) and today's attendance in parallel so
    //         the display lookup never delays attendance marking.
    const [courses, existing] = await Promise.all([
      academyQuery<{ name: string }>(
        academySlug,
        `SELECT c.name FROM courses c
         JOIN student_courses sc ON sc.course_id = c.id
         WHERE sc.student_id = $1 AND sc.status = 'active'
         ORDER BY c.name LIMIT 3`,
        [student.id]
      ),
      academyQueryOne<AttendanceRow>(
        academySlug,
        `SELECT id, time_in, time_out, duration_mins FROM attendance
         WHERE student_id = $1 AND date = $2`,
        [student.id, today]
      ),
    ]);
    const courseNames = courses.map(c => c.name).join(', ');

    const studentPayload = {
      id:         student.id,
      first_name: student.first_name,
      last_name:  student.last_name,
      courses:    courseNames,
    };

    if (mode === 'checkin' && existing?.time_in) {
      const diffMins = minutesSince(existing.time_in, timeStr);
      if (diffMins >= 0 && diffMins < 10) {
        res.json({
          success: true,
          action: 'duplicate',
          student: studentPayload,
          time_in: existing.time_in,
          confidence,
          threshold,
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
          threshold,
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

      // Fire-and-forget push to parent
      if (student.parent_fcm_token) {
        void sendFcm({
          token: student.parent_fcm_token,
          title: `${student.first_name} checked in ✅`,
          body:  `${req.academyUser!.academyName} • ${to12Hour(timeStr)}`,
          data:  { type: 'attendance', action: 'checkin', studentId: student.id, time: timeStr },
        });
      }

      res.json({
        success: true,
        action: 'checkin',
        student: studentPayload,
        time_in: timeStr,
        confidence,
        threshold,
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

    // Fire-and-forget push to parent
    if (student.parent_fcm_token) {
      const h = Math.floor(durationMins / 60);
      const m = durationMins % 60;
      const dur = h > 0 ? `${h}h ${m}m` : `${m}m`;
      void sendFcm({
        token: student.parent_fcm_token,
        title: `${student.first_name} checked out 🏠`,
        body:  `${req.academyUser!.academyName} • ${to12Hour(timeStr)} (${dur})`,
        data:  { type: 'attendance', action: 'checkout', studentId: student.id, time: timeStr },
      });
    }

    res.json({
      success: true,
      action: 'checkout',
      student: studentPayload,
      time_in:       existing.time_in,
      time_out:      timeStr,
      duration_mins: durationMins,
      confidence,
      threshold,
      message: `Face matched! Check-out for ${student.first_name} ${student.last_name}. Duration: ${Math.floor(durationMins / 60)}h ${durationMins % 60}m`,
    });
  } catch (err) { next(err); }
}

// ── POST /api/academy/attendance/verify-password ──────────────────────────────

/**
 * Re-verify the *currently authenticated* academy user's password. Used to
 * unlock kiosk lock-mode on the attendance scan screen, so a student can't leave
 * the page without an operator's password.
 *
 * Deliberately lightweight vs. login: identifies the user from their JWT (no
 * email/slug in the body) and DOES NOT touch failed_attempts / lockout — a wrong
 * unlock attempt must never lock the operator out of an unattended kiosk.
 */
export async function verifyAcademyPassword(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { userId, academySlug } = req.academyUser!;
    const { password } = req.body as { password?: string };

    if (!password || typeof password !== 'string') {
      return next(new AppError('password is required', 400));
    }

    const user = await academyQueryOne<{ password_hash: string }>(
      academySlug,
      `SELECT password_hash FROM users WHERE id = $1`,
      [userId]
    );
    if (!user) return next(new AppError('User not found', 404));

    const match = await bcrypt.compare(password, user.password_hash);
    res.json({ success: true, data: { valid: match } });
  } catch (err) { next(err); }
}
