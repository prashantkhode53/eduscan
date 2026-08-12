/**
 * One-Click Attendance — mark a whole class from group photo(s).
 *
 * Flow (3 endpoints):
 *   GET  /attendance/group-scan/roster?course_id=...
 *        -> the course's active students (id, name, has_face) plus today's
 *           checked_in / checked_out flags, so the review screen can show who
 *           was NOT detected and who is eligible for a group check-out.
 *   POST /attendance/group-scan/photo   { course_id, image_base64 }
 *        -> detect every face in ONE photo (Python /embed/group), match each
 *           against the course roster's cached embeddings, return matches.
 *           NO attendance is written here — the app accumulates unique
 *           students across multiple photos of the same classroom.
 *   POST /attendance/group-scan/approve { course_id, mode, entries: [{student_id, confidence}] }
 *        -> admin approved the reviewed list.
 *           mode 'checkin'  (default): bulk-upsert attendance, set time_in
 *                                      (checkin_mode 'face_group').
 *           mode 'checkout'          : set time_out + duration_mins
 *                                      (checkout_mode 'face_group') for the
 *                                      students who are checked in but not
 *                                      yet checked out.
 *           Either way, parent FCM pushes are fired for the affected students.
 *
 * Photos are sent one-per-request deliberately: express.json is capped at
 * 5 MB, and per-photo requests give the app real progress + partial results.
 */

import { Request, Response, NextFunction } from 'express';
import { academyQuery } from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';
import { groupEmbed } from '../../utils/insightface';
import {
  matchGroupFaces,
  sanitizeApproveEntries,
  parseApproveMode,
  MAX_APPROVE_ENTRIES,
  RawApproveEntry,
  CleanApproveEntry,
} from '../../utils/groupMatch';
import { getActiveEmbeddings, getThreshold } from '../../db/scanCache';
import { sendFcm } from '../../utils/fcm';

// Same UTC -> IST 12-hour formatting used by the single-face scan path.
function to12Hour(timeStr: string): string {
  const [hStr, mStr = '00'] = timeStr.split(':');
  const h = parseInt(hStr, 10);
  const m = parseInt(mStr, 10);
  if (Number.isNaN(h) || Number.isNaN(m)) return timeStr;
  const istTotal = (h * 60 + m + 330) % (24 * 60);
  const istH = Math.floor(istTotal / 60);
  const istM = istTotal % 60;
  const ampm = istH >= 12 ? 'PM' : 'AM';
  const h12  = istH % 12 === 0 ? 12 : istH % 12;
  return `${h12.toString().padStart(2, '0')}:${istM.toString().padStart(2, '0')} ${ampm}`;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface RosterRow {
  id: string;
  first_name: string;
  last_name: string;
  has_face: boolean;
  checked_in: boolean;   // has a time_in today
  checked_out: boolean;  // has a time_out today
}

/** Server-clock date, the same "today" every attendance write in this file uses. */
function todayStr(now: Date = new Date()): string {
  return now.toISOString().split('T')[0];
}

async function loadCourseRoster(
  slug: string, courseId: string, today: string = todayStr()
): Promise<RosterRow[]> {
  return academyQuery<RosterRow>(
    slug,
    `SELECT s.id, s.first_name, s.last_name,
            (s.face_embedding IS NOT NULL) AS has_face,
            (a.time_in  IS NOT NULL)       AS checked_in,
            (a.time_out IS NOT NULL)       AS checked_out
     FROM students s
     JOIN student_courses sc ON sc.student_id = s.id
     LEFT JOIN attendance a ON a.student_id = s.id AND a.date = $2
     WHERE sc.course_id = $1
       AND sc.status = 'active'
       AND s.status  = 'active'
     ORDER BY s.first_name, s.last_name`,
    [courseId, today]
  );
}

function fullName(r: { first_name: string; last_name: string }): string {
  return `${r.first_name} ${r.last_name}`.trim();
}

// ── GET /api/academy/attendance/group-scan/roster ─────────────────────────────

export async function groupScanRoster(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const courseId = req.query.course_id as string | undefined;
    if (!courseId || !UUID_RE.test(courseId)) {
      return next(new AppError('A valid course_id is required', 400));
    }

    const roster = await loadCourseRoster(academySlug, courseId);
    res.json({
      success: true,
      data: {
        course_id: courseId,
        total: roster.length,
        with_face: roster.filter(r => r.has_face).length,
        checked_in: roster.filter(r => r.checked_in).length,
        checked_out: roster.filter(r => r.checked_out).length,
        students: roster,
      },
    });
  } catch (err) { next(err); }
}

// ── POST /api/academy/attendance/group-scan/photo ─────────────────────────────

export async function groupScanPhoto(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { course_id, image_base64 } = req.body as {
      course_id?: string;
      image_base64?: string;
    };

    if (!course_id || !UUID_RE.test(course_id)) {
      return next(new AppError('A valid course_id is required', 400));
    }
    if (!image_base64 || typeof image_base64 !== 'string') {
      return next(new AppError('image_base64 is required', 400));
    }

    // 1. Every face in the photo -> one embedding each.
    let group;
    try {
      group = await groupEmbed(image_base64);
    } catch (err) {
      console.error('[group-scan] InsightFace error:', err);
      res.status(503).json({
        success: false,
        message: 'Face recognition service unavailable. Please try again.',
      });
      return;
    }

    if (!group.success || group.faces.length === 0) {
      res.json({
        success: true,
        data: {
          faces_detected: group.faces_detected ?? 0,
          faces_usable: 0,
          matches: [],
          unmatched_faces: 0,
          message: group.reason === 'no_face_detected'
            ? 'No faces detected in this photo.'
            : 'No usable faces in this photo (too small or blurry). Move closer and retake.',
        },
      });
      return;
    }

    // 2. Candidate embeddings = academy cache ∩ course roster.
    //    Restricting to the course roster both speeds matching and removes
    //    false positives against look-alike students from other courses.
    const [allStudents, roster, threshold] = await Promise.all([
      getActiveEmbeddings(academySlug),
      loadCourseRoster(academySlug, course_id),
      getThreshold(academySlug, 0.60),
    ]);
    const rosterIds = new Set(roster.map(r => r.id));
    const candidates = allStudents.filter(s => rosterIds.has(s.id));

    if (candidates.length === 0) {
      res.json({
        success: true,
        data: {
          faces_detected: group.faces_detected,
          faces_usable: group.faces_usable,
          matches: [],
          unmatched_faces: group.faces.length,
          message: 'No registered faces in this course. Register student faces first.',
        },
      });
      return;
    }

    // 3. Match every face independently against the course candidates —
    //    pure, unit-tested core (see utils/groupMatch.test.ts).
    const { matches, unmatchedFaces } = matchGroupFaces(
      group.faces, candidates, threshold);

    console.log(
      `[group-scan] photo: faces=${group.faces_usable}/${group.faces_detected} ` +
      `matched=${matches.length} unmatched=${unmatchedFaces} course=${course_id}`
    );

    res.json({
      success: true,
      data: {
        faces_detected: group.faces_detected,
        faces_usable:   group.faces_usable,
        matches,
        unmatched_faces: unmatchedFaces,
        threshold,
      },
    });
  } catch (err) { next(err); }
}

// ── POST /api/academy/attendance/group-scan/approve ───────────────────────────

export async function groupScanApprove(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug, academyName, userId } = req.academyUser!;
    const { course_id, entries } = req.body as {
      course_id?: string;
      entries?: RawApproveEntry[];
    };
    const mode = parseApproveMode((req.body as { mode?: unknown }).mode);

    if (!course_id || !UUID_RE.test(course_id)) {
      return next(new AppError('A valid course_id is required', 400));
    }
    if (!Array.isArray(entries) || entries.length === 0) {
      return next(new AppError('entries must be a non-empty array', 400));
    }
    if (entries.length > MAX_APPROVE_ENTRIES) {
      return next(new AppError(`Too many entries in one approval (max ${MAX_APPROVE_ENTRIES})`, 400));
    }

    const now     = new Date();
    const today   = todayStr(now);
    const timeStr = now.toTimeString().split(' ')[0]; // HH:MM:SS

    // Only students actually enrolled in this course can be marked through it.
    // Sanitisation (roster check, dedupe, confidence clamping) is a pure,
    // unit-tested function — see utils/groupMatch.test.ts.
    const roster = await loadCourseRoster(academySlug, course_id, today);
    const rosterIds = new Set(roster.map(r => r.id));
    const { entries: clean, skipped } = sanitizeApproveEntries(entries, rosterIds);
    if (clean.length === 0) {
      return next(new AppError('No entries belong to this course', 400));
    }

    if (mode === 'checkout') {
      await approveCheckOut({
        res, next, academySlug, academyName, courseId: course_id,
        roster, clean, skipped, today, timeStr,
      });
      return;
    }

    // Single batched upsert — one round-trip, atomic within the statement, so
    // a mid-list failure can never leave half a class marked. COALESCE keeps
    // an earlier kiosk/face check-in time if one already exists — group
    // approval must never erase a real check-in.
    const values: string[] = [];
    const params: unknown[] = [today, timeStr, userId];
    let p = params.length;
    for (const e of clean) {
      values.push(`($${++p}, $1, $2, 'present', $${++p}, $${++p}, $3)`);
      params.push(e.student_id, e.mode, e.confidence);
    }
    await academyQuery(
      academySlug,
      `INSERT INTO attendance (student_id, date, time_in, status, checkin_mode, confidence_in, marked_by)
       VALUES ${values.join(', ')}
       ON CONFLICT (student_id, date) DO UPDATE
         SET time_in       = COALESCE(attendance.time_in, EXCLUDED.time_in),
             status        = 'present',
             checkin_mode  = CASE WHEN attendance.time_in IS NULL
                                  THEN EXCLUDED.checkin_mode
                                  ELSE attendance.checkin_mode END,
             confidence_in = COALESCE(attendance.confidence_in, EXCLUDED.confidence_in),
             marked_by     = COALESCE(attendance.marked_by, EXCLUDED.marked_by)`,
      params
    );
    const marked = clean.length;

    console.log(`[group-scan] APPROVED check-in: ${marked} students course=${course_id} by=${userId}`);

    // Fire-and-forget parent notifications (only for students we have tokens for).
    const validIds = clean.map(e => e.student_id);
    void (async () => {
      try {
        const tokens = await loadParentTokens(academySlug, validIds);
        for (const t of tokens) {
          void sendFcm({
            token: t.parent_fcm_token,
            title: `${t.first_name} marked present ✅`,
            body:  `${academyName} • ${to12Hour(timeStr)} (class photo attendance)`,
            data:  { type: 'attendance', action: 'checkin', studentId: t.id, time: timeStr },
          });
        }
      } catch (err) {
        console.error('[group-scan] FCM batch error:', err);
      }
    })();

    res.json({
      success: true,
      data: {
        mode: 'checkin',
        marked,
        skipped,
        date: today,
        time_in: timeStr,
      },
      message: `Attendance recorded for ${marked} student${marked === 1 ? '' : 's'}.`,
    });
  } catch (err) { next(err); }
}

// ── Check-out half of the approval ────────────────────────────────────────────

/**
 * Group check-out.
 *
 * A check-out only makes sense for a student who is already checked in today
 * and has not been checked out yet, so the approved list is split three ways:
 *   - eligible          -> time_out + duration_mins written
 *   - not checked in    -> reported back, nothing written
 *   - already checked out -> reported back, existing time_out preserved
 *
 * Never overwriting an existing time_out mirrors the check-in invariant: a
 * group approval must not erase a real kiosk/face scan.
 */
async function approveCheckOut(ctx: {
  res: Response;
  next: NextFunction;
  academySlug: string;
  academyName: string;
  courseId: string;
  roster: RosterRow[];
  clean: CleanApproveEntry[];
  skipped: number;
  today: string;
  timeStr: string;
}): Promise<void> {
  const { res, next, academySlug, academyName, courseId, roster, clean, skipped, today, timeStr } = ctx;

  const byId = new Map(roster.map(r => [r.id, r]));
  const eligible: CleanApproveEntry[] = [];
  const notCheckedIn: RosterRow[] = [];
  const alreadyOut: RosterRow[] = [];

  for (const e of clean) {
    const r = byId.get(e.student_id)!;      // sanitize guaranteed roster membership
    if (!r.checked_in)       notCheckedIn.push(r);
    else if (r.checked_out)  alreadyOut.push(r);
    else                     eligible.push(e);
  }

  if (eligible.length === 0) {
    const why = [
      notCheckedIn.length ? `${notCheckedIn.length} not checked in today` : '',
      alreadyOut.length   ? `${alreadyOut.length} already checked out`    : '',
    ].filter(Boolean).join(', ');
    return next(new AppError(
      `No one can be checked out right now (${why || 'no eligible students'}). ` +
      `Record check-in first, then check out.`, 400));
  }

  // Single batched UPDATE ... FROM (VALUES ...) — one round-trip, atomic.
  // duration_mins is computed in SQL from each student's own time_in.
  const values: string[] = [];
  const params: unknown[] = [today, timeStr];
  let p = params.length;
  for (const e of eligible) {
    values.push(`($${++p}::varchar, $${++p}::varchar, $${++p}::decimal)`);
    params.push(e.student_id, e.mode, e.confidence);
  }
  const updated = await academyQuery<{ student_id: string; duration_mins: number | null }>(
    academySlug,
    `UPDATE attendance a
        SET time_out       = $2::time,
            checkout_mode  = v.mode,
            confidence_out = v.conf,
            duration_mins  = GREATEST(0, ROUND(EXTRACT(EPOCH FROM ($2::time - a.time_in)) / 60))::int
       FROM (VALUES ${values.join(', ')}) AS v(student_id, mode, conf)
      WHERE a.student_id = v.student_id
        AND a.date       = $1
        AND a.time_in    IS NOT NULL
        AND a.time_out   IS NULL
    RETURNING a.student_id, a.duration_mins`,
    params
  );

  const marked = updated.length;
  console.log(
    `[group-scan] APPROVED check-out: ${marked} students course=${courseId} ` +
    `no_checkin=${notCheckedIn.length} already_out=${alreadyOut.length}`
  );

  // Fire-and-forget parent notifications, with each student's own duration.
  const durationById = new Map(updated.map(u => [u.student_id, u.duration_mins ?? 0]));
  void (async () => {
    try {
      const tokens = await loadParentTokens(academySlug, [...durationById.keys()]);
      for (const t of tokens) {
        const mins = durationById.get(t.id) ?? 0;
        const h = Math.floor(mins / 60);
        const dur = h > 0 ? `${h}h ${mins % 60}m` : `${mins}m`;
        void sendFcm({
          token: t.parent_fcm_token,
          title: `${t.first_name} checked out 🏠`,
          body:  `${academyName} • ${to12Hour(timeStr)} (${dur}) • class photo attendance`,
          data:  { type: 'attendance', action: 'checkout', studentId: t.id, time: timeStr },
        });
      }
    } catch (err) {
      console.error('[group-scan] FCM batch error:', err);
    }
  })();

  res.json({
    success: true,
    data: {
      mode: 'checkout',
      marked,
      skipped,
      date: today,
      time_out: timeStr,
      not_checked_in:      notCheckedIn.map(r => ({ student_id: r.id, name: fullName(r) })),
      already_checked_out: alreadyOut.map(r  => ({ student_id: r.id, name: fullName(r) })),
    },
    message: `Check-out recorded for ${marked} student${marked === 1 ? '' : 's'}.`,
  });
}

function loadParentTokens(slug: string, ids: string[]) {
  return academyQuery<{ id: string; first_name: string; parent_fcm_token: string }>(
    slug,
    `SELECT id, first_name, parent_fcm_token FROM students
     WHERE id = ANY($1) AND parent_fcm_token IS NOT NULL`,
    [ids]
  );
}
