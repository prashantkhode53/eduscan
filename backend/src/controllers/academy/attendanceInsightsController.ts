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

// ── Cohort filter (academic year + courses) ─────────────────────────────────────
//
// The Attendance Reports screen picks an academic year and any number of courses
// once, at the top, and every tab reports on that cohort. This narrows WHICH
// STUDENTS are reported on; it deliberately does NOT narrow the academy's open
// days, because open days are the attendance-% denominator and are a property of
// the academy's calendar, not of a course. Filtering them by course would make
// the same student's percentage change depending on which courses were ticked.

export interface Cohort { yearId: string | null; courseIds: string[] }

/** Read `?academic_year_id=` and `?course_ids=a,b,c` (or repeated `course_ids`). */
function readCohort(q: Record<string, unknown>): Cohort {
  const yearId = (q['academic_year_id'] as string | undefined)?.trim() || null;

  const raw = q['course_ids'] ?? q['course_id'];
  const list = Array.isArray(raw) ? raw : String(raw ?? '').split(',');
  const courseIds = [...new Set(
    list.map((v) => String(v).trim()).filter((v) => v !== ''),
  )];

  return { yearId, courseIds };
}

/**
 * SQL predicates restricting the `students s` row set, appending to [params].
 * Returns '' when nothing is selected, so the unfiltered query is unchanged.
 */
function cohortSql(c: Cohort, params: unknown[]): string {
  const parts: string[] = [];
  if (c.yearId) {
    params.push(c.yearId);
    parts.push(`AND s.academic_year_id = $${params.length}`);
  }
  if (c.courseIds.length) {
    params.push(c.courseIds);
    parts.push(`AND EXISTS (
      SELECT 1 FROM student_courses sc
      WHERE sc.student_id = s.id
        AND sc.course_id = ANY($${params.length}::uuid[])
        AND sc.status = 'active')`);
  }
  return parts.join('\n      ');
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
  slug: string, windowDays: number, studentId?: string, cohort?: Cohort,
): Promise<RawStudentAgg[]> {
  const half = Math.floor(windowDays / 2);
  const params: unknown[] = [windowDays, half];
  let studentFilter = '';
  if (studentId) {
    params.push(studentId);
    studentFilter = `AND s.id = $${params.length}`;
  }
  if (cohort) {
    studentFilter += `\n      ${cohortSql(cohort, params)}`;
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
  slug: string, windowDays: number, cohort?: Cohort,
): Promise<Map<string, number>> {
  const params: unknown[] = [windowDays];
  const cohortWhere = cohort ? cohortSql(cohort, params) : '';
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
    WHERE s.status = 'active'
      ${cohortWhere}`,
    params,
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
    const cohort = readCohort(req.query as Record<string, unknown>);

    const [open, aggs, streaks] = await Promise.all([
      getOpenDays(academySlug, windowDays),
      aggregateStudents(academySlug, windowDays, undefined, cohort),
      getStreaks(academySlug, windowDays, cohort),
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
    const cohort = readCohort(req.query as Record<string, unknown>);

    const [open, aggs, streaks] = await Promise.all([
      getOpenDays(academySlug, windowDays),
      aggregateStudents(academySlug, windowDays, undefined, cohort),
      getStreaks(academySlug, windowDays, cohort),
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

/**
 * The reporting period for the single-student detail screen.
 *
 * Two ways to ask for one, in priority order:
 *   ?from=YYYY-MM-DD&to=YYYY-MM-DD   explicit range (what the month picker sends)
 *   ?window=<days>                   rolling N days back from today (the default,
 *                                    and what every other tab uses)
 *
 * Resolving the rolling window to explicit dates here means the rest of the
 * endpoint has exactly one code path, and the response can always tell the app
 * precisely which dates it is showing — the old response only carried a day
 * count, which is why the screen could not label its own period.
 */
interface Period { from: string; to: string; label: string; windowDays: number }

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'];

function ymd(d: Date): string {
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}

/**
 * Human label for a range. A range that covers exactly one calendar month reads
 * as "August 2026"; anything else spells out both ends, so the admin is never
 * looking at an unlabelled figure.
 */
function periodLabel(from: string, to: string): string {
  const f = new Date(`${from}T00:00:00Z`);
  const t = new Date(`${to}T00:00:00Z`);
  const sameMonth = f.getUTCFullYear() === t.getUTCFullYear()
    && f.getUTCMonth() === t.getUTCMonth();
  const isFullMonth = sameMonth
    && f.getUTCDate() === 1
    && t.getUTCDate() === new Date(Date.UTC(t.getUTCFullYear(), t.getUTCMonth() + 1, 0)).getUTCDate();

  if (isFullMonth) return `${MONTHS[f.getUTCMonth()]} ${f.getUTCFullYear()}`;
  const fmt = (d: Date) => `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()].slice(0, 3)} ${d.getUTCFullYear()}`;
  return `${fmt(f)} – ${fmt(t)}`;
}

function resolvePeriod(q: Record<string, unknown>): Period {
  const from = isoDateOrNull(q['from']);
  const to   = isoDateOrNull(q['to']);

  if (from && to && from <= to) {
    const days = Math.round(
      (new Date(`${to}T00:00:00Z`).getTime() - new Date(`${from}T00:00:00Z`).getTime())
      / 86_400_000,
    ) + 1;
    return { from, to, label: periodLabel(from, to), windowDays: days };
  }

  // Rolling window, matching what the other tabs do. CURRENT_DATE on the DB is
  // UTC, so deriving "today" in UTC here keeps the default identical to before.
  const windowDays = clampWindow(q['window']);
  const today = new Date();
  const start = new Date(today.getTime() - windowDays * 86_400_000);
  return {
    from: ymd(start),
    to: ymd(today),
    label: `Last ${windowDays} days`,
    windowDays,
  };
}

/** One row per academy open day in the period, with this student's status (null = absent). */
interface DailyRow { date: Date | string; status: string | null; time_in: string | null }

/**
 * The student's day-by-day record across the period.
 *
 * Every academy open day is returned, not just the days the student has a row
 * for — the LEFT JOIN is what makes a missing row read as an absence, which is
 * the same denominator the other tabs use. One query then feeds the counts, the
 * streak, the weekday buckets AND the trend chart, so all four are guaranteed
 * to agree with each other.
 */
async function getStudentDailySeries(
  slug: string, studentId: string, p: Period,
): Promise<DailyRow[]> {
  return academyQuery<DailyRow>(
    slug,
    `WITH open AS (
       SELECT DISTINCT date
       FROM attendance
       WHERE status <> 'holiday'
         AND date >= $1::date AND date <= $2::date
     )
     SELECT o.date, a.status, a.time_in::text AS time_in
     FROM open o
     LEFT JOIN attendance a
       ON a.student_id = $3 AND a.date = o.date AND a.status <> 'holiday'
     ORDER BY o.date`,
    [p.from, p.to, studentId],
  );
}

/** Name, ID, active course(s) and academic year — the header context. */
async function getStudentHeader(
  slug: string, studentId: string,
): Promise<{ name: string; academic_year: string | null; course_name: string | null } | null> {
  return academyQueryOne(
    slug,
    `SELECT TRIM(s.first_name || ' ' || s.last_name) AS name,
            ay.academic_year_name AS academic_year,
            (
              SELECT STRING_AGG(c.name, ', ' ORDER BY c.name)
              FROM student_courses sc
              JOIN courses c ON c.id = sc.course_id
              WHERE sc.student_id = s.id AND sc.status = 'active'
            ) AS course_name
     FROM students s
     LEFT JOIN academic_years ay ON ay.id = s.academic_year_id
     WHERE s.id = $1`,
    [studentId],
  );
}

/**
 * Derive every fact the pure scoring core needs from the daily series.
 *
 * Doing this in Node rather than SQL keeps the single-student path off the
 * shared aggregation helpers (which the Today/Students/Defaulters tabs use and
 * which only understand a rolling window), and guarantees the numbers on screen
 * are the same ones the chart is drawn from.
 */
function factsFromSeries(
  studentId: string, rows: DailyRow[],
): { facts: StudentAttendanceFacts; weekday: WeekdayBuckets } {
  const attended = (s: string | null): boolean => s === 'present' || s === 'late';

  const openDays    = rows.length;
  const presentDays = rows.filter((r) => r.status === 'present').length;
  const lateDays    = rows.filter((r) => r.status === 'late').length;

  // Chronological halves, for the recent-vs-prior trend the core expects.
  const half        = Math.floor(openDays / 2);
  const prior       = rows.slice(0, half);
  const recent      = rows.slice(half);
  const pct = (list: DailyRow[]): number =>
    list.length === 0 ? 0 : (list.filter((r) => attended(r.status)).length / list.length) * 100;

  // Trailing run of open days with no present/late row.
  let streak = 0;
  for (let i = rows.length - 1; i >= 0; i--) {
    if (attended(rows[i].status)) break;
    streak++;
  }

  // Days since last seen, measured from the period's end so it stays meaningful
  // when the admin is looking at a past month rather than today.
  const lastSeen = [...rows].reverse().find((r) => attended(r.status));
  const asDate = (d: Date | string): Date => (d instanceof Date ? d : new Date(String(d)));
  const daysSinceLastSeen = lastSeen && rows.length
    ? Math.round(
        (asDate(rows[rows.length - 1].date).getTime() - asDate(lastSeen.date).getTime())
        / 86_400_000,
      )
    : null;

  // Weekday buckets, index 0 = Monday … 6 = Sunday, matching the pure core.
  const weekday: WeekdayBuckets = { absences: Array(7).fill(0), openDays: Array(7).fill(0) };
  for (const r of rows) {
    const dow = (asDate(r.date).getUTCDay() + 6) % 7; // Sun=0 → Mon=0
    weekday.openDays[dow]++;
    if (!attended(r.status)) weekday.absences[dow]++;
  }

  return {
    facts: {
      studentId,
      openDays,
      presentDays,
      lateDays,
      absentDays: Math.max(0, openDays - presentDays - lateDays),
      daysSinceLastSeen,
      currentAbsenceStreak: streak,
      recentAttendancePct: pct(recent),
      priorAttendancePct: pct(prior),
    },
    weekday,
  };
}

/** Weekly roll-up of the daily series, for the trend chart's coarser view. */
function weeklyBuckets(rows: DailyRow[]): Array<{
  week_start: string; open_days: number; attended: number; pct: number;
}> {
  const asDate = (d: Date | string): Date => (d instanceof Date ? d : new Date(String(d)));
  const buckets = new Map<string, { open: number; att: number }>();

  for (const r of rows) {
    const d = asDate(r.date);
    // Monday of that week.
    const monday = new Date(d.getTime() - ((d.getUTCDay() + 6) % 7) * 86_400_000);
    const key = ymd(monday);
    const b = buckets.get(key) ?? { open: 0, att: 0 };
    b.open++;
    if (r.status === 'present' || r.status === 'late') b.att++;
    buckets.set(key, b);
  }

  return [...buckets.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([week_start, b]) => ({
      week_start,
      open_days: b.open,
      attended: b.att,
      pct: b.open ? Math.round((b.att / b.open) * 1000) / 10 : 0,
    }));
}

export async function getStudentScoreDetail(
  req: Request, res: Response, next: NextFunction,
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const studentId = req.params['studentId'];
    const period = resolvePeriod(req.query as Record<string, unknown>);

    const [header, rows] = await Promise.all([
      getStudentHeader(academySlug, studentId),
      getStudentDailySeries(academySlug, studentId, period),
    ]);
    if (!header) return next(new AppError('Student not found', 404));

    const { facts, weekday } = factsFromSeries(studentId, rows);
    const score    = computeAttendanceScore(facts);
    const risk     = assessRisk(facts);
    const patterns = detectPatterns(facts, weekday);
    const stage    = defaulterStage(score.attendancePct);

    const onTime = facts.presentDays;
    const attendedDays = facts.presentDays + facts.lateDays;

    res.json({
      success: true,
      data: {
        student_id: studentId,
        name: header.name,
        course: header.course_name ?? '',
        academic_year: header.academic_year ?? '',
        period: {
          from: period.from,
          to: period.to,
          label: period.label,
          days: period.windowDays,
        },
        // Kept for backward compatibility with any caller still reading these.
        window_days: period.windowDays,
        open_days: facts.openDays,
        score,
        risk,
        patterns,
        defaulter: stage,
        counts: {
          working_days: facts.openDays,
          present: facts.presentDays,
          late: facts.lateDays,
          absent: facts.absentDays,
          attended: attendedDays,
          on_time: onTime,
          on_time_pct: attendedDays ? Math.round((onTime / attendedDays) * 1000) / 10 : 0,
          days_since_last_seen: facts.daysSinceLastSeen,
        },
        trend: {
          daily: rows.map((r) => ({
            date: isoDate(r.date),
            status: r.status ?? 'absent',
            time_in: hhmm(r.time_in),
          })),
          weekly: weeklyBuckets(rows),
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
    const cohort = readCohort(req.query as Record<string, unknown>);

    const [open, aggs, streaks] = await Promise.all([
      getOpenDays(academySlug, windowDays),
      aggregateStudents(academySlug, windowDays, undefined, cohort),
      getStreaks(academySlug, windowDays, cohort),
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

// ── GET /overall — consolidated per-day attendance report (grid + Excel) ─────────
//
// One row per (student, date) over the filtered scope, with the columns the
// "Overall Attendance Data" tab needs. The data model stores a single
// attendance row per student/day (UNIQUE(student_id, date)), so:
//   • first_check_in  = time_in    (no punch table → this is the only check-in)
//   • last_check_out  = time_out
//   • total_mins      = duration_mins (server-computed at checkout)
//   • check_in_count  = 1 when there's a time_in, else 0 (no punch log exists)
//   • late_arrival    = status = 'late'
// attendance_pct is the student's present-rate across all of THIS response's
// rows for that student (present+late ÷ non-holiday days in scope) — i.e. it
// respects whatever filters were applied, per the spec's formula.

interface OverallRow {
  student_id: string;
  name: string;
  academic_year: string | null;
  course_name: string | null;
  date: Date | string;
  time_in: string | null;
  time_out: string | null;
  duration_mins: number | null;
  status: string;
  remarks: string | null;
}

const DOW = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/** 'YYYY-MM-DD' from a pg DATE (returned as a JS Date). */
function isoDate(d: Date | string): string {
  const dt = d instanceof Date ? d : new Date(String(d));
  return dt.toISOString().slice(0, 10);
}

/**
 * Validate a query-string date as strict 'YYYY-MM-DD', else null. Guards the
 * SQL date comparisons against malformed input (the value is parameterised, so
 * this is belt-and-suspenders correctness, not an injection concern).
 */
function isoDateOrNull(raw: unknown): string | null {
  const s = String(raw ?? '').trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return null;
  const d = new Date(`${s}T00:00:00Z`);
  return Number.isNaN(d.getTime()) ? null : s;
}

/** IST is a fixed +05:30 from UTC — no DST, no historical drift. */
const IST_OFFSET_MINS = 5 * 60 + 30;

/**
 * 'hh:mm AM/PM' in IST from a pg TIME string ('HH:MM:SS') or null.
 *
 * `attendance.time_in` / `time_out` are TIME columns with no timezone, written
 * from the server clock — UTC on both Render and the Hetzner container. Every
 * other surface that shows these values already adds +05:30 on the way out
 * (`fmtTimeOfDay` in the app, `to12Hour` for parent pushes); this report was the
 * one path that returned the raw stored value, so First Check-In / Last
 * Check-Out read 5h30m early in both the grid and the Excel export.
 *
 * The 12-hour rendering matches `fmtTimeOfDay`, so the report now reads the
 * same way as every other time in the app. Both the on-screen grid and the
 * .xlsx consume this one field verbatim.
 *
 * Wraps into the next day, so 20:00 UTC renders as 01:30 AM rather than 25:30.
 * Midnight and noon render as 12:00 AM / 12:00 PM, not 00:00.
 *
 * Durations are unaffected: `duration_mins` is a difference of two times, and
 * shifting both ends by the same offset leaves it unchanged.
 */
function hhmm(t: string | null): string {
  if (!t) return '';
  const parts = String(t).split(':');
  if (parts.length < 2) return String(t);

  const h = parseInt(parts[0], 10);
  const m = parseInt(parts[1], 10);
  if (Number.isNaN(h) || Number.isNaN(m)) return String(t);

  const ist   = (h * 60 + m + IST_OFFSET_MINS) % (24 * 60);
  const istH  = Math.floor(ist / 60);
  const istM  = ist % 60;
  const ampm  = istH >= 12 ? 'PM' : 'AM';
  const h12   = istH % 12 === 0 ? 12 : istH % 12;
  const pad   = (n: number): string => String(n).padStart(2, '0');
  return `${pad(h12)}:${pad(istM)} ${ampm}`;
}

export async function getOverallAttendance(
  req: Request, res: Response, next: NextFunction,
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const {
      academic_year_id,
      student,        // free-text: id OR name
      from,           // range start 'YYYY-MM-DD' (inclusive)
      to,             // range end   'YYYY-MM-DD' (inclusive)
      status,         // present | absent
    } = req.query as Record<string, string>;
    // course_ids / course_id are read via readCohort below.

    const yearId   = academic_year_id?.trim() || null;
    // Courses are multi-select on the Attendance Reports screen. `course_id` is
    // still honoured so any older client keeps working.
    const courseIds = readCohort(req.query as Record<string, unknown>).courseIds;
    const search   = student?.trim() || null;
    const fromDate = isoDateOrNull(from);
    const toDate   = isoDateOrNull(to);
    const statusF  = status?.trim().toLowerCase() || null;

    if (fromDate && toDate && fromDate > toDate) {
      return next(new AppError('"from" date must be on or before "to" date', 400));
    }

    // Two filter layers:
    //  • cohort filters (year/course/search/date-range) select WHICH students
    //    and WHICH days are in scope; they also scope the attendance-% denominator
    //    ("total working days" within the chosen period), so they come first in
    //    the param list and the percentage query reuses them verbatim.
    //  • status is a pure row filter appended after — it narrows the grid rows
    //    shown but never moves the percentage, so "present ÷ working days" stays
    //    a stable figure regardless of which status the admin is viewing.
    const cohortParams: unknown[] = [];
    const cohort: string[] = [`s.status = 'active'`];     // student-level predicates
    const dateScope: string[] = [`a.status <> 'holiday'`]; // attendance-row predicates shared by both queries

    if (yearId)   { cohortParams.push(yearId);   cohort.push(`s.academic_year_id = $${cohortParams.length}`); }
    if (courseIds.length) { cohortParams.push(courseIds); cohort.push(`EXISTS (
        SELECT 1 FROM student_courses sc
        WHERE sc.student_id = s.id
          AND sc.course_id = ANY($${cohortParams.length}::uuid[])
          AND sc.status = 'active')`); }
    if (search) {
      cohortParams.push(`%${search}%`);
      cohort.push(`(s.id ILIKE $${cohortParams.length}
        OR TRIM(s.first_name || ' ' || s.last_name) ILIKE $${cohortParams.length})`);
    }
    if (fromDate) { cohortParams.push(fromDate); dateScope.push(`a.date >= $${cohortParams.length}`); }
    if (toDate)   { cohortParams.push(toDate);   dateScope.push(`a.date <= $${cohortParams.length}`); }

    // Grid query params = cohort params + status row-filter param.
    const params: unknown[] = [...cohortParams];
    const where = [...cohort, ...dateScope];
    if (statusF && ['present', 'absent'].includes(statusF)) {
      params.push(statusF); where.push(`a.status = $${params.length}`);
    }

    // course_name = the active course(s) the student is enrolled in. Multiple
    // enrolments are joined with ', '. Scoped to the selected year's courses so
    // the label matches the chosen academic year.
    const rows = await academyQuery<OverallRow>(
      academySlug,
      `SELECT
         s.id   AS student_id,
         TRIM(s.first_name || ' ' || s.last_name) AS name,
         ay.academic_year_name AS academic_year,
         (
           SELECT STRING_AGG(c.name, ', ' ORDER BY c.name)
           FROM student_courses sc
           JOIN courses c ON c.id = sc.course_id
           WHERE sc.student_id = s.id AND sc.status = 'active'
             AND (s.academic_year_id IS NULL OR c.academic_year_id = s.academic_year_id)
         ) AS course_name,
         a.date,
         a.time_in::text   AS time_in,
         a.time_out::text  AS time_out,
         a.duration_mins,
         a.status,
         a.remarks
       FROM attendance a
       JOIN students s        ON s.id = a.student_id
       LEFT JOIN academic_years ay ON ay.id = s.academic_year_id
       WHERE ${where.join(' AND ')}
       ORDER BY a.date DESC, s.first_name, s.last_name, s.id`,
      params,
    );

    // Per-student attendance % over the cohort + date-range scope (spec formula:
    // present days ÷ total working days, within the selected period). "Working
    // days" = that student's non-holiday rows in scope; "present" = present or
    // late. Independent of the status row filter so the figure stays stable.
    const pctRows = await academyQuery<{ student_id: string; present: string; total: string }>(
      academySlug,
      `SELECT
         a.student_id,
         COUNT(*) FILTER (WHERE a.status IN ('present','late'))::int AS present,
         COUNT(*)::int                                              AS total
       FROM attendance a
       JOIN students s ON s.id = a.student_id
       WHERE ${[...cohort, ...dateScope].join(' AND ')}
       GROUP BY a.student_id`,
      cohortParams,
    );
    const tally = new Map<string, number>();
    for (const p of pctRows) {
      const total = parseInt(p.total, 10) || 0;
      const present = parseInt(p.present, 10) || 0;
      tally.set(p.student_id, total > 0 ? (present / total) * 100 : 0);
    }

    const records = rows.map((r) => {
      const pct = tally.get(r.student_id) ?? 0;
      const dow = (r.date instanceof Date ? r.date : new Date(String(r.date))).getUTCDay();
      return {
        student_id: r.student_id,
        name: r.name,
        academic_year: r.academic_year ?? '',
        course_name: r.course_name ?? '',
        date: isoDate(r.date),
        day: DOW[dow],
        first_check_in: hhmm(r.time_in),
        last_check_out: hhmm(r.time_out),
        total_mins: r.duration_mins ?? 0,
        status: r.status,
        attendance_pct: Math.round(pct * 100) / 100,
        remarks: r.remarks ?? '',
      };
    });

    res.json({ success: true, data: { records, count: records.length } });
  } catch (err) { next(err); }
}

// Weekday buckets used to be fetched with a dedicated SQL query here. The
// single-student report now derives them from its daily series in
// `factsFromSeries`, which is the only caller that ever needed them and which
// also guarantees the buckets agree with the counts and the trend chart drawn
// from the same rows.

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
