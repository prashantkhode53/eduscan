/**
 * Attendance Intelligence — read-only controller (v1).
 *
 * Pure SQL aggregation over the existing per-academy `attendance` table; no
 * schema change, no writes. Aggregated facts are fed into the pure, unit-tested
 * scoring core in services/attendanceScoring.ts. Tenancy via academyQuery
 * (SET LOCAL search_path inside a txn — PgBouncer-safe).
 *
 * The one exception to "read-only" is the explicit admin Nudge action, which
 * reuses the existing fire-and-forget sendFcm helper to push a single parent
 * alert — it writes nothing to the DB.
 */

import { Request, Response, NextFunction } from 'express';
import { academyQuery, academyQueryOne } from '../../db/poolManager';
import { AppError } from '../../middleware/errorHandler';
import { sendFcm } from '../../utils/fcm';
import {
  StudentAttendanceFacts,
  WeekdayBuckets,
  computeAttendanceScore,
  assessRisk,
  detectPatterns,
  defaulterStage,
} from '../../services/attendanceScoring';

// Default analysis window (days). Bounded so a hand-typed ?window= can't run away.
const DEFAULT_WINDOW = 56; // 8 weeks
const MAX_WINDOW = 365;

function clampWindow(raw: unknown): number {
  const n = parseInt(String(raw ?? ''), 10);
  if (!Number.isFinite(n)) return DEFAULT_WINDOW;
  return Math.max(7, Math.min(n, MAX_WINDOW));
}

// ── Shared aggregation ──────────────────────────────────────────────────────────

interface RawStudentAgg {
  student_id: string;
  first_name: string;
  last_name: string;
  present_days: number;
  late_days: number;
  recent_present: number;   // present+late in recent half
  recent_open_seen: number; // open days the student had a row in recent half (unused for pct, kept for clarity)
  prior_present: number;
  days_since_last_seen: number | null;
  current_streak: number;
}

/**
 * Number of academy "open days" in the window: distinct dates with ANY non-holiday
 * attendance row across all students. This is the attendance-% denominator.
 * Split into recent/prior halves for trend.
 */
async function getOpenDays(
  slug: string, windowDays: number,
): Promise<{ total: number; recent: number; prior: number; halfStart: string }> {
  const row = await academyQueryOne<{
    total: string; recent: string; prior: string;
  }>(
    slug,
    `WITH open AS (
       SELECT DISTINCT date
       FROM attendance
       WHERE status <> 'holiday'
         AND date >= CURRENT_DATE - MAKE_INTERVAL(days => $1)
         AND date <= CURRENT_DATE
     )
     SELECT
       COUNT(*)                                                                AS total,
       COUNT(*) FILTER (WHERE date >  CURRENT_DATE - MAKE_INTERVAL(days => $2)) AS recent,
       COUNT(*) FILTER (WHERE date <= CURRENT_DATE - MAKE_INTERVAL(days => $2)) AS prior
     FROM open`,
    [windowDays, Math.floor(windowDays / 2)],
  );
  return {
    total:  parseInt(row?.total ?? '0', 10),
    recent: parseInt(row?.recent ?? '0', 10),
    prior:  parseInt(row?.prior ?? '0', 10),
    halfStart: '',
  };
}

/**
 * Per-student aggregation over the window. Returns counts the scoring core needs.
 * `current_streak` = consecutive open days with no present/late row, counting back
 * from the most recent open day. Computed in SQL via a window over open days.
 */
async function aggregateStudents(
  slug: string, windowDays: number, studentId?: string,
): Promise<RawStudentAgg[]> {
  const half = Math.floor(windowDays / 2);
  const params: unknown[] = [windowDays, half];
  let studentFilter = '';
  if (studentId) {
    params.push(studentId);
    studentFilter = `AND s.id = $${params.length}`;
  }

  return academyQuery<RawStudentAgg>(
    slug,
    `
    WITH open AS (   -- academy open days in window (denominator basis)
      SELECT DISTINCT date
      FROM attendance
      WHERE status <> 'holiday'
        AND date >= CURRENT_DATE - MAKE_INTERVAL(days => $1)
        AND date <= CURRENT_DATE
    ),
    att AS (         -- this-window attendance rows per active student
      SELECT a.student_id, a.date, a.status
      FROM attendance a
      WHERE a.status <> 'holiday'
        AND a.date >= CURRENT_DATE - MAKE_INTERVAL(days => $1)
        AND a.date <= CURRENT_DATE
    ),
    seen AS (        -- last present/late date per student
      SELECT student_id, MAX(date) AS last_seen
      FROM att WHERE status IN ('present','late')
      GROUP BY student_id
    ),
    -- consecutive trailing open days with no present/late row → current streak
    streak AS (
      SELECT o.date,
             EXISTS (
               SELECT 1 FROM att a2
               WHERE a2.date = o.date AND a2.status IN ('present','late')
             ) AS any_present
      FROM open o
    )
    SELECT
      s.id   AS student_id,
      s.first_name,
      s.last_name,
      COALESCE(COUNT(*) FILTER (WHERE a.status = 'present'), 0)::int AS present_days,
      COALESCE(COUNT(*) FILTER (WHERE a.status = 'late'), 0)::int    AS late_days,
      COALESCE(COUNT(*) FILTER (
        WHERE a.status IN ('present','late')
          AND a.date > CURRENT_DATE - MAKE_INTERVAL(days => $2)), 0)::int AS recent_present,
      0::int AS recent_open_seen,
      COALESCE(COUNT(*) FILTER (
        WHERE a.status IN ('present','late')
          AND a.date <= CURRENT_DATE - MAKE_INTERVAL(days => $2)), 0)::int AS prior_present,
      (SELECT (CURRENT_DATE - sn.last_seen)::int FROM seen sn WHERE sn.student_id = s.id) AS days_since_last_seen,
      0::int AS current_streak
    FROM students s
    LEFT JOIN att a ON a.student_id = s.id
    WHERE s.status = 'active' ${studentFilter}
    GROUP BY s.id, s.first_name, s.last_name
    ORDER BY s.first_name, s.last_name
    `,
    params,
  );
}

/**
 * Current consecutive-absence streak per student: trailing open days (most recent
 * first) on which the student has no present/late row. Done as a separate, simple
 * query so the main aggregation stays readable.
 */
async function getStreaks(
  slug: string, windowDays: number,
): Promise<Map<string, number>> {
  const rows = await academyQuery<{ student_id: string; streak: string }>(
    slug,
    `
    WITH open AS (
      SELECT DISTINCT date FROM attendance
      WHERE status <> 'holiday'
        AND date >= CURRENT_DATE - MAKE_INTERVAL(days => $1)
        AND date <= CURRENT_DATE
      ORDER BY date DESC
    ),
    ranked AS (   -- open days numbered newest=1
      SELECT date, ROW_NUMBER() OVER (ORDER BY date DESC) AS rn FROM open
    ),
    present_dates AS (
      SELECT DISTINCT student_id, date FROM attendance
      WHERE status IN ('present','late')
        AND date >= CURRENT_DATE - MAKE_INTERVAL(days => $1)
    )
    SELECT s.id AS student_id,
      COALESCE((
        SELECT MIN(r.rn) - 1
        FROM ranked r
        WHERE EXISTS (SELECT 1 FROM present_dates p WHERE p.student_id = s.id AND p.date = r.date)
      ), (SELECT COUNT(*) FROM ranked))::int AS streak
    FROM students s
    WHERE s.status = 'active'`,
    [windowDays],
  );
  const m = new Map<string, number>();
  for (const r of rows) m.set(r.student_id, parseInt(r.streak, 10) || 0);
  return m;
}

/** Convert a raw aggregate + denominators into the pure-core fact shape. */
function toFacts(
  r: RawStudentAgg,
  openTotal: number,
  openRecent: number,
  openPrior: number,
  streak: number,
): StudentAttendanceFacts {
  const attended = r.present_days + r.late_days;
  const recentPct = openRecent > 0 ? (r.recent_present / openRecent) * 100 : 0;
  const priorPct  = openPrior  > 0 ? (r.prior_present  / openPrior)  * 100 : 0;
  return {
    studentId: r.student_id,
    openDays: openTotal,
    presentDays: r.present_days,
    lateDays: r.late_days,
    absentDays: Math.max(0, openTotal - attended),
    daysSinceLastSeen: r.days_since_last_seen,
    currentAbsenceStreak: streak,
    recentAttendancePct: recentPct,
    priorAttendancePct: priorPct,
  };
}

// ── GET /today — admin action list ──────────────────────────────────────────────

export async function getTodayActionList(
  req: Request, res: Response, next: NextFunction,
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const windowDays = clampWindow(req.query['window']);

    const [open, aggs, streaks] = await Promise.all([
      getOpenDays(academySlug, windowDays),
      aggregateStudents(academySlug, windowDays),
      getStreaks(academySlug, windowDays),
    ]);

    if (open.total === 0) {
      res.json({ success: true, data: { window_days: windowDays, open_days: 0, groups: emptyGroups() } });
      return;
    }

    const groups = {
      below_threshold:      [] as ActionItem[],
      consecutive_absences: [] as ActionItem[],
      sharp_drop:           [] as ActionItem[],
      not_seen:             [] as ActionItem[],
    };

    for (const r of aggs) {
      const facts = toFacts(r, open.total, open.recent, open.prior, streaks.get(r.student_id) ?? 0);
      const score = computeAttendanceScore(facts);
      const stage = defaulterStage(score.attendancePct);
      const patterns = detectPatterns(facts, emptyWeekday());

      const item: ActionItem = {
        student_id: r.student_id,
        name: `${r.first_name} ${r.last_name}`.trim(),
        attendance_pct: score.attendancePct,
        band: score.band,
        stage: stage.stage,
        stage_label: stage.label,
        consecutive_absences: facts.currentAbsenceStreak,
        days_since_last_seen: facts.daysSinceLastSeen,
      };

      // Below-threshold flag (defaulter <75 flags for admin per spec).
      if (stage.flagForAdmin) groups.below_threshold.push(item);
      if (facts.currentAbsenceStreak >= 3) groups.consecutive_absences.push(item);
      if (patterns.some((p) => p.key === 'sharp_drop')) groups.sharp_drop.push(item);
      if (facts.daysSinceLastSeen !== null && facts.daysSinceLastSeen >= 5) groups.not_seen.push(item);
    }

    // Most urgent first within each group.
    groups.below_threshold.sort((a, b) => a.attendance_pct - b.attendance_pct);
    groups.consecutive_absences.sort((a, b) => b.consecutive_absences - a.consecutive_absences);
    groups.not_seen.sort((a, b) => (b.days_since_last_seen ?? 0) - (a.days_since_last_seen ?? 0));

    res.json({
      success: true,
      data: { window_days: windowDays, open_days: open.total, groups },
    });
  } catch (err) { next(err); }
}

// ── GET /students — list with score band ────────────────────────────────────────

export async function getStudentScores(
  req: Request, res: Response, next: NextFunction,
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const windowDays = clampWindow(req.query['window']);

    const [open, aggs, streaks] = await Promise.all([
      getOpenDays(academySlug, windowDays),
      aggregateStudents(academySlug, windowDays),
      getStreaks(academySlug, windowDays),
    ]);

    const students = aggs.map((r) => {
      const facts = toFacts(r, open.total, open.recent, open.prior, streaks.get(r.student_id) ?? 0);
      const score = computeAttendanceScore(facts);
      const risk = assessRisk(facts);
      return {
        student_id: r.student_id,
        name: `${r.first_name} ${r.last_name}`.trim(),
        attendance_pct: score.attendancePct,
        score: score.score,
        band: score.band,
        risk: risk.level,
        has_data: score.hasData,
      };
    });

    res.json({
      success: true,
      data: { window_days: windowDays, open_days: open.total, students },
    });
  } catch (err) { next(err); }
}

// ── GET /:studentId/score — full breakdown for one student ───────────────────────

export async function getStudentScoreDetail(
  req: Request, res: Response, next: NextFunction,
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const studentId = req.params['studentId'];
    const windowDays = clampWindow(req.query['window']);

    const [open, aggs, streaks, weekday] = await Promise.all([
      getOpenDays(academySlug, windowDays),
      aggregateStudents(academySlug, windowDays, studentId),
      getStreaks(academySlug, windowDays),
      getWeekdayBuckets(academySlug, windowDays, studentId),
    ]);

    const r = aggs[0];
    if (!r) return next(new AppError('Student not found', 404));

    const facts = toFacts(r, open.total, open.recent, open.prior, streaks.get(studentId) ?? 0);
    const score = computeAttendanceScore(facts);
    const risk = assessRisk(facts);
    const patterns = detectPatterns(facts, weekday);
    const stage = defaulterStage(score.attendancePct);

    res.json({
      success: true,
      data: {
        student_id: r.student_id,
        name: `${r.first_name} ${r.last_name}`.trim(),
        window_days: windowDays,
        open_days: open.total,
        score,
        risk,
        patterns,
        defaulter: stage,
        counts: {
          present: r.present_days,
          late: r.late_days,
          absent: facts.absentDays,
          days_since_last_seen: facts.daysSinceLastSeen,
        },
      },
    });
  } catch (err) { next(err); }
}

// ── GET /defaulters — grouped by stage ──────────────────────────────────────────

export async function getDefaulters(
  req: Request, res: Response, next: NextFunction,
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const windowDays = clampWindow(req.query['window']);

    const [open, aggs, streaks] = await Promise.all([
      getOpenDays(academySlug, windowDays),
      aggregateStudents(academySlug, windowDays),
      getStreaks(academySlug, windowDays),
    ]);

    const defaulters = aggs
      .map((r) => {
        const facts = toFacts(r, open.total, open.recent, open.prior, streaks.get(r.student_id) ?? 0);
        const score = computeAttendanceScore(facts);
        const stage = defaulterStage(score.attendancePct);
        return {
          student_id: r.student_id,
          name: `${r.first_name} ${r.last_name}`.trim(),
          attendance_pct: score.attendancePct,
          band: score.band,
          stage: stage.stage,
          stage_label: stage.label,
          should_alert_parent: stage.shouldAlertParent,
        };
      })
      .filter((d) => d.stage !== 'none' && d.attendance_pct > 0)
      .sort((a, b) => a.attendance_pct - b.attendance_pct);

    res.json({
      success: true,
      data: { window_days: windowDays, open_days: open.total, defaulters },
    });
  } catch (err) { next(err); }
}

// ── POST /:studentId/nudge — manual parent FCM (reuses sendFcm) ──────────────────

export async function nudgeParent(
  req: Request, res: Response, next: NextFunction,
): Promise<void> {
  try {
    const { academySlug, academyName } = req.academyUser!;
    const studentId = req.params['studentId'];

    const student = await academyQueryOne<{
      first_name: string; last_name: string; parent_fcm_token: string | null;
    }>(
      academySlug,
      `SELECT first_name, last_name, parent_fcm_token FROM students WHERE id = $1 AND status = 'active'`,
      [studentId],
    );
    if (!student) return next(new AppError('Student not found', 404));
    if (!student.parent_fcm_token) {
      return next(new AppError('No parent device registered for this student', 409));
    }

    // Optional custom message from the admin; otherwise a sensible default.
    const custom = typeof req.body?.message === 'string' ? req.body.message.trim() : '';
    const body = custom ||
      `Please ensure ${student.first_name} attends regularly. Reach out to ${academyName} if there's a concern.`;

    const ok = await sendFcm({
      token: student.parent_fcm_token,
      title: `Attendance reminder — ${student.first_name}`,
      body,
      data: { type: 'attendance_nudge', studentId },
    });

    res.json({
      success: true,
      data: { delivered: ok },
      message: ok ? 'Reminder sent to parent' : 'Reminder could not be delivered (stale device token)',
    });
  } catch (err) { next(err); }
}

// ── Weekday buckets (for pattern detection on the detail screen) ─────────────────

async function getWeekdayBuckets(
  slug: string, windowDays: number, studentId: string,
): Promise<WeekdayBuckets> {
  // EXTRACT(DOW): 0=Sun..6=Sat. Remap to 0=Mon..6=Sun to match the pure core.
  const rows = await academyQuery<{ dow: string; open_days: string; absences: string }>(
    slug,
    `
    WITH open AS (
      SELECT DISTINCT date FROM attendance
      WHERE status <> 'holiday'
        AND date >= CURRENT_DATE - MAKE_INTERVAL(days => $1)
        AND date <= CURRENT_DATE
    ),
    present_dates AS (
      SELECT DISTINCT date FROM attendance
      WHERE student_id = $2 AND status IN ('present','late')
        AND date >= CURRENT_DATE - MAKE_INTERVAL(days => $1)
    )
    SELECT EXTRACT(DOW FROM o.date)::int AS dow,
           COUNT(*)::int AS open_days,
           COUNT(*) FILTER (WHERE p.date IS NULL)::int AS absences
    FROM open o
    LEFT JOIN present_dates p ON p.date = o.date
    GROUP BY EXTRACT(DOW FROM o.date)`,
    [windowDays, studentId],
  );

  const buckets: WeekdayBuckets = {
    absences: [0, 0, 0, 0, 0, 0, 0],
    openDays: [0, 0, 0, 0, 0, 0, 0],
  };
  for (const r of rows) {
    const sunFirst = parseInt(r.dow, 10);       // 0=Sun..6=Sat
    const monFirst = (sunFirst + 6) % 7;         // 0=Mon..6=Sun
    buckets.openDays[monFirst] = parseInt(r.open_days, 10);
    buckets.absences[monFirst] = parseInt(r.absences, 10);
  }
  return buckets;
}

// ── Small shared types/helpers ──────────────────────────────────────────────────

interface ActionItem {
  student_id: string;
  name: string;
  attendance_pct: number;
  band: string;
  stage: string;
  stage_label: string;
  consecutive_absences: number;
  days_since_last_seen: number | null;
}

function emptyGroups() {
  return { below_threshold: [], consecutive_absences: [], sharp_drop: [], not_seen: [] };
}

function emptyWeekday(): WeekdayBuckets {
  return { absences: [0, 0, 0, 0, 0, 0, 0], openDays: [0, 0, 0, 0, 0, 0, 0] };
}
