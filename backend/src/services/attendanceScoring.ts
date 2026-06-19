/**
 * Attendance Intelligence — pure scoring core (v1).
 *
 * NO database, NO I/O, NO Date.now() — every function is a pure transform over
 * plain daily-attendance facts so it can be unit-tested in isolation. The
 * controller does all SQL aggregation and passes the results in here.
 *
 * v1 works ONLY from the per-academy daily `attendance` table (one row per
 * student per day). There is no session/subject/test dimension, so there are no
 * per-session features here. See docs/attendance-intelligence-spec.md.
 */

// ── Weights (single source of truth) ───────────────────────────────────────────
// v1 re-normalized weights: only factors with real data. When marks / homework /
// fee modules are confirmed, restore the original 6-factor weighting by editing
// THIS object only — nothing else hard-codes a weight.
export const SCORE_WEIGHTS = {
  attendance:  50,
  punctuality: 25,
  regularity:  25,
} as const;

export type ScoreBand = 'green' | 'yellow' | 'orange' | 'red';
export type RiskLevel = 'low' | 'medium' | 'high';

/**
 * Per-student daily counts over the analysis window, plus the chronological
 * recent/prior split for trend math, and the academy's open-day count (the
 * attendance-% denominator — see spec).
 */
export interface StudentAttendanceFacts {
  studentId: string;
  /** Distinct academy open days in the window (denominator), excludes holidays. */
  openDays: number;
  presentDays: number;   // status='present'
  lateDays: number;      // status='late'
  /**
   * Open days in the window on which this student has NO present/late row, i.e.
   * effective absences. Derived by the controller as openDays - attendedDays so
   * missing rows count as absent (per the chosen denominator).
   */
  absentDays: number;
  /** Days since the student was last seen (present/late). null = never seen. */
  daysSinceLastSeen: number | null;
  /** Longest current run of consecutive absences ending at "today". */
  currentAbsenceStreak: number;
  /** Attendance % in the recent half of the window (for trend). */
  recentAttendancePct: number;
  /** Attendance % in the prior half of the window (for trend). */
  priorAttendancePct: number;
}

export interface ScoreFactor {
  key: 'attendance' | 'punctuality' | 'regularity';
  label: string;
  weight: number;         // effective (re-normalized) weight, 0–100
  value: number;          // 0–100 factor sub-score
  contribution: number;   // value * weight / 100, rounded
  detail: string;
}

export interface AttendanceScore {
  studentId: string;
  score: number;          // 0–100, weighted
  band: ScoreBand;
  attendancePct: number;  // 0–100, the headline %
  factors: ScoreFactor[];
  hasData: boolean;       // false when openDays === 0 (nothing to score)
}

// ── Small helpers ───────────────────────────────────────────────────────────────

const clamp = (n: number, lo = 0, hi = 100): number => Math.max(lo, Math.min(hi, n));
const round1 = (n: number): number => Math.round(n * 10) / 10;

/** Attendance % = (present + late) / openDays. Returns 0 when openDays is 0. */
export function attendancePct(f: Pick<StudentAttendanceFacts,
  'openDays' | 'presentDays' | 'lateDays'>): number {
  if (f.openDays <= 0) return 0;
  return clamp(((f.presentDays + f.lateDays) / f.openDays) * 100);
}

/** Late-day rate among attended days = late / (present + late). 0 when none attended. */
export function lateRate(f: Pick<StudentAttendanceFacts, 'presentDays' | 'lateDays'>): number {
  const attended = f.presentDays + f.lateDays;
  if (attended <= 0) return 0;
  return f.lateDays / attended;
}

export function bandForScore(score: number): ScoreBand {
  if (score >= 85) return 'green';
  if (score >= 70) return 'yellow';
  if (score >= 50) return 'orange';
  return 'red';
}

// ── Factor sub-scores (each 0–100) ──────────────────────────────────────────────

/** Punctuality: 100 when never late, 0 when always late. */
function punctualitySubScore(f: StudentAttendanceFacts): number {
  return clamp((1 - lateRate(f)) * 100);
}

/**
 * Regularity & recent trend: starts at 100, penalizes the current consecutive-
 * absence streak and a recent decline vs the prior window. A streak of 5+ or a
 * 30-point drop each fully consume their share.
 */
function regularitySubScore(f: StudentAttendanceFacts): number {
  // Streak penalty: up to 50 points, saturating at a 5-day run.
  const streakPenalty = clamp((f.currentAbsenceStreak / 5) * 50, 0, 50);
  // Decline penalty: up to 50 points, saturating at a 30-point pct drop.
  const decline = Math.max(0, f.priorAttendancePct - f.recentAttendancePct);
  const declinePenalty = clamp((decline / 30) * 50, 0, 50);
  return clamp(100 - streakPenalty - declinePenalty);
}

// ── Attendance Score ────────────────────────────────────────────────────────────

/**
 * Compute the weighted Attendance Score with a per-factor breakdown.
 *
 * Weights are re-normalized over only the factors that have data. In v1 all three
 * factors always have data once openDays > 0, but the normalization is written
 * generically so future factors can be dropped/added without touching the math.
 */
export function computeAttendanceScore(f: StudentAttendanceFacts): AttendanceScore {
  const pct = round1(attendancePct(f));

  if (f.openDays <= 0) {
    return {
      studentId: f.studentId,
      score: 0,
      band: 'red',
      attendancePct: 0,
      factors: [],
      hasData: false,
    };
  }

  const raw = {
    attendance:  pct,
    punctuality: round1(punctualitySubScore(f)),
    regularity:  round1(regularitySubScore(f)),
  };

  const totalWeight =
    SCORE_WEIGHTS.attendance + SCORE_WEIGHTS.punctuality + SCORE_WEIGHTS.regularity;

  const mk = (
    key: ScoreFactor['key'],
    label: string,
    weight: number,
    value: number,
    detail: string,
  ): ScoreFactor => {
    const effWeight = round1((weight / totalWeight) * 100);
    return {
      key, label, weight: effWeight, value,
      contribution: round1((value * effWeight) / 100),
      detail,
    };
  };

  const factors: ScoreFactor[] = [
    mk('attendance', 'Attendance %', SCORE_WEIGHTS.attendance, raw.attendance,
      `${f.presentDays + f.lateDays}/${f.openDays} open days`),
    mk('punctuality', 'Punctuality', SCORE_WEIGHTS.punctuality, raw.punctuality,
      `${Math.round(lateRate(f) * 100)}% of attended days late`),
    mk('regularity', 'Regularity & trend', SCORE_WEIGHTS.regularity, raw.regularity,
      f.currentAbsenceStreak >= 3
        ? `${f.currentAbsenceStreak}-day absence streak`
        : `${round1(f.recentAttendancePct)}% recent vs ${round1(f.priorAttendancePct)}% prior`),
  ];

  const score = round1(factors.reduce((sum, fac) => sum + fac.contribution, 0));

  return {
    studentId: f.studentId,
    score,
    band: bandForScore(score),
    attendancePct: pct,
    factors,
    hasData: true,
  };
}

// ── Risk band (Low/Med/High — NEVER a percentage) ───────────────────────────────

export interface RiskAssessment {
  studentId: string;
  level: RiskLevel;
  /** Internal 0–100 risk index (higher = riskier); not surfaced as a %. */
  index: number;
  /** Top contributing factors, most significant first. */
  factors: string[];
}

/**
 * Weighted risk index from attendance signals, mapped to Low/Med/High.
 * This is deliberately separate from the Attendance Score: risk emphasizes
 * *recent* danger (streaks, days-since-seen, sharp drops) over the lifetime %.
 */
export function assessRisk(f: StudentAttendanceFacts): RiskAssessment {
  if (f.openDays <= 0) {
    return { studentId: f.studentId, level: 'low', index: 0, factors: ['No attendance data yet'] };
  }

  const pct = attendancePct(f);
  const contributions: { weight: number; risk: number; label: string }[] = [];

  // Low attendance %  (40% of risk)
  contributions.push({
    weight: 40,
    risk: clamp(100 - pct) / 100,
    label: `Attendance ${Math.round(pct)}%`,
  });
  // Downward trend  (20%)
  const drop = Math.max(0, f.priorAttendancePct - f.recentAttendancePct);
  contributions.push({
    weight: 20,
    risk: clamp(drop / 30, 0, 1),
    label: drop >= 10 ? `Down ${Math.round(drop)} pts recently` : 'Stable trend',
  });
  // Consecutive absences  (20%)
  contributions.push({
    weight: 20,
    risk: clamp(f.currentAbsenceStreak / 5, 0, 1),
    label: f.currentAbsenceStreak >= 3 ? `${f.currentAbsenceStreak} absences in a row` : 'No long absence run',
  });
  // Late rate  (10%)
  contributions.push({
    weight: 10,
    risk: lateRate(f),
    label: `${Math.round(lateRate(f) * 100)}% late`,
  });
  // Days since last seen  (10%) — saturates at 7 days
  const dsls = f.daysSinceLastSeen ?? f.openDays;
  contributions.push({
    weight: 10,
    risk: clamp(dsls / 7, 0, 1),
    label: f.daysSinceLastSeen === null ? 'Never seen' : `Not seen ${dsls}d`,
  });

  const index = round1(
    contributions.reduce((sum, c) => sum + c.risk * c.weight, 0)
  );

  const level: RiskLevel = index >= 60 ? 'high' : index >= 30 ? 'medium' : 'low';

  // Surface the factors that actually drive the risk (risk-weighted), top 3.
  const factors = contributions
    .filter((c) => c.risk > 0.15)
    .sort((a, b) => b.risk * b.weight - a.risk * a.weight)
    .slice(0, 3)
    .map((c) => c.label);

  return {
    studentId: f.studentId,
    level,
    index,
    factors: factors.length ? factors : ['No significant risk factors'],
  };
}

// ── Pattern detection (rolling window over daily rows) ──────────────────────────

export type PatternKey =
  | 'monday_absentee'
  | 'weekend_absentee'
  | 'late_comer'
  | 'consecutive_absences'
  | 'sharp_drop'
  | 'not_seen';

export interface DetectedPattern {
  key: PatternKey;
  label: string;
  detail: string;
}

/**
 * Per-weekday absence counts the controller aggregates from daily rows.
 * Index 0 = Monday … 6 = Sunday (ISO-ish; matches the controller's EXTRACT(DOW)
 * remap). `absences[d]` / `openDaysByDow[d]` is that weekday's absence rate.
 */
export interface WeekdayBuckets {
  absences: number[];     // length 7, Mon..Sun
  openDays: number[];     // length 7, Mon..Sun (academy open days by weekday)
}

/**
 * Detect attendance patterns from already-aggregated facts + weekday buckets.
 * Thresholds are intentionally conservative so a badge means something.
 */
export function detectPatterns(
  f: StudentAttendanceFacts,
  weekday: WeekdayBuckets,
): DetectedPattern[] {
  const out: DetectedPattern[] = [];

  // Monday absentee — absence rate on Mondays >= 50% and at least 2 missed.
  const monRate = weekday.openDays[0] > 0 ? weekday.absences[0] / weekday.openDays[0] : 0;
  if (monRate >= 0.5 && weekday.absences[0] >= 2) {
    out.push({ key: 'monday_absentee', label: 'Monday absentee',
      detail: `Absent ${weekday.absences[0]}/${weekday.openDays[0]} Mondays` });
  }

  // Weekend absentee — Sat/Sun combined absence rate >= 50% (academies that run weekends).
  const weOpen = weekday.openDays[5] + weekday.openDays[6];
  const weAbs  = weekday.absences[5] + weekday.absences[6];
  if (weOpen >= 2 && weAbs / weOpen >= 0.5) {
    out.push({ key: 'weekend_absentee', label: 'Weekend absentee',
      detail: `Absent ${weAbs}/${weOpen} weekend days` });
  }

  // Late-comer — late on >50% of attended days.
  if (lateRate(f) > 0.5) {
    out.push({ key: 'late_comer', label: 'Late-comer',
      detail: `${Math.round(lateRate(f) * 100)}% of attended days late` });
  }

  // Consecutive-absence run (>= 3).
  if (f.currentAbsenceStreak >= 3) {
    out.push({ key: 'consecutive_absences', label: 'Consecutive absences',
      detail: `${f.currentAbsenceStreak} days in a row` });
  }

  // Sharp drop — recent window >= 15 pts below prior.
  const drop = f.priorAttendancePct - f.recentAttendancePct;
  if (drop >= 15) {
    out.push({ key: 'sharp_drop', label: 'Sharp drop',
      detail: `${round1(f.recentAttendancePct)}% recent vs ${round1(f.priorAttendancePct)}% prior` });
  }

  // Not seen in X days (>= 5).
  if (f.daysSinceLastSeen !== null && f.daysSinceLastSeen >= 5) {
    out.push({ key: 'not_seen', label: `Not seen ${f.daysSinceLastSeen}d`,
      detail: `Last present ${f.daysSinceLastSeen} days ago` });
  }

  return out;
}

// ── Defaulter workflow stage (thresholds on attendance %) ───────────────────────

export type DefaulterStage =
  | 'none'
  | 'nudge'           // <85 : FCM nudge to parent
  | 'flag'            // <75 : FCM + flag on admin Today list
  | 'counselor_call'  // <65 : counselor-call task
  | 'parent_meeting'  // <50 : parent-meeting task
  | 'recovery_plan';  // <40 : recovery-plan note

export interface DefaulterAction {
  stage: DefaulterStage;
  attendancePct: number;
  /** Whether this stage should push an FCM nudge to the parent. */
  shouldAlertParent: boolean;
  /** Whether this stage should surface a flag on the admin Today list. */
  flagForAdmin: boolean;
  label: string;
}

export function defaulterStage(pct: number): DefaulterAction {
  let stage: DefaulterStage = 'none';
  let label = 'On track';
  let flagForAdmin = false;

  if (pct < 40)      { stage = 'recovery_plan';  label = 'Recovery plan needed'; flagForAdmin = true; }
  else if (pct < 50) { stage = 'parent_meeting'; label = 'Parent meeting';       flagForAdmin = true; }
  else if (pct < 65) { stage = 'counselor_call'; label = 'Counselor call';       flagForAdmin = true; }
  else if (pct < 75) { stage = 'flag';           label = 'At risk — flagged';    flagForAdmin = true; }
  else if (pct < 85) { stage = 'nudge';          label = 'Below 85% — nudge';    flagForAdmin = false; }

  return {
    stage,
    attendancePct: round1(pct),
    shouldAlertParent: stage !== 'none',
    flagForAdmin,
    label,
  };
}
