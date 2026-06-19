/**
 * Unit tests for the pure attendance-scoring core.
 *
 * Uses Node's built-in test runner — no jest/vitest dependency.
 * Run:  npm test   (→ node --test, after `npm run build` compiles to dist/)
 * or:   npx ts-node --test src/services/attendanceScoring.test.ts
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  StudentAttendanceFacts,
  WeekdayBuckets,
  attendancePct,
  lateRate,
  bandForScore,
  computeAttendanceScore,
  assessRisk,
  detectPatterns,
  defaulterStage,
  SCORE_WEIGHTS,
} from './attendanceScoring';

// Factory: a "perfect" student, override fields per test.
function facts(over: Partial<StudentAttendanceFacts> = {}): StudentAttendanceFacts {
  return {
    studentId: 'ACF-2026-00001',
    openDays: 20,
    presentDays: 20,
    lateDays: 0,
    absentDays: 0,
    daysSinceLastSeen: 0,
    currentAbsenceStreak: 0,
    recentAttendancePct: 100,
    priorAttendancePct: 100,
    ...over,
  };
}

function emptyWeekday(): WeekdayBuckets {
  return { absences: [0, 0, 0, 0, 0, 0, 0], openDays: [0, 0, 0, 0, 0, 0, 0] };
}

// ── attendancePct ───────────────────────────────────────────────────────────────

test('attendancePct: present+late over open days', () => {
  assert.equal(attendancePct({ openDays: 10, presentDays: 8, lateDays: 1 }), 90);
});

test('attendancePct: zero open days → 0 (no divide-by-zero)', () => {
  assert.equal(attendancePct({ openDays: 0, presentDays: 0, lateDays: 0 }), 0);
});

test('attendancePct: clamped to 100', () => {
  assert.equal(attendancePct({ openDays: 5, presentDays: 6, lateDays: 0 }), 100);
});

// ── lateRate ──────────────────────────────────────────────────────────────────

test('lateRate: late over attended days', () => {
  assert.equal(lateRate({ presentDays: 6, lateDays: 4 }), 0.4);
});

test('lateRate: never attended → 0', () => {
  assert.equal(lateRate({ presentDays: 0, lateDays: 0 }), 0);
});

// ── bandForScore ────────────────────────────────────────────────────────────────

test('bandForScore: boundaries', () => {
  assert.equal(bandForScore(85), 'green');
  assert.equal(bandForScore(84.9), 'yellow');
  assert.equal(bandForScore(70), 'yellow');
  assert.equal(bandForScore(69.9), 'orange');
  assert.equal(bandForScore(50), 'orange');
  assert.equal(bandForScore(49.9), 'red');
  assert.equal(bandForScore(0), 'red');
});

// ── computeAttendanceScore ──────────────────────────────────────────────────────

test('score: perfect attendance → 100, green', () => {
  const s = computeAttendanceScore(facts());
  assert.equal(s.score, 100);
  assert.equal(s.band, 'green');
  assert.equal(s.attendancePct, 100);
  assert.equal(s.hasData, true);
  assert.equal(s.factors.length, 3);
});

test('score: weights re-normalize to 100 total', () => {
  const s = computeAttendanceScore(facts());
  const totalWeight = s.factors.reduce((sum, f) => sum + f.weight, 0);
  assert.ok(Math.abs(totalWeight - 100) < 0.5, `weights sum ${totalWeight}`);
});

test('score: no open days → hasData false, score 0, red', () => {
  const s = computeAttendanceScore(facts({ openDays: 0, presentDays: 0 }));
  assert.equal(s.hasData, false);
  assert.equal(s.score, 0);
  assert.equal(s.band, 'red');
  assert.deepEqual(s.factors, []);
});

test('score: 50% attendance, all on time, stable trend', () => {
  // pct=50 → attendance factor 50; punctuality 100; regularity 100.
  // 50*0.5 + 100*0.25 + 100*0.25 = 25 + 25 + 25 = 75
  const s = computeAttendanceScore(facts({
    openDays: 20, presentDays: 10, lateDays: 0, absentDays: 10,
    recentAttendancePct: 50, priorAttendancePct: 50,
  }));
  assert.equal(s.attendancePct, 50);
  assert.equal(s.score, 75);
  assert.equal(s.band, 'yellow');
});

test('score: chronic late lowers punctuality factor', () => {
  const onTime = computeAttendanceScore(facts({ presentDays: 20, lateDays: 0 }));
  const late   = computeAttendanceScore(facts({ presentDays: 0,  lateDays: 20 }));
  const p1 = onTime.factors.find((f) => f.key === 'punctuality')!.value;
  const p2 = late.factors.find((f) => f.key === 'punctuality')!.value;
  assert.equal(p1, 100);
  assert.equal(p2, 0);
  assert.ok(late.score < onTime.score);
});

test('score: absence streak drags regularity down', () => {
  const s = computeAttendanceScore(facts({
    openDays: 20, presentDays: 15, absentDays: 5, currentAbsenceStreak: 5,
    recentAttendancePct: 75, priorAttendancePct: 75,
  }));
  const reg = s.factors.find((f) => f.key === 'regularity')!.value;
  assert.equal(reg, 50); // 5-day streak = full 50-pt streak penalty
});

test('SCORE_WEIGHTS are the v1 50/25/25 split', () => {
  assert.equal(SCORE_WEIGHTS.attendance, 50);
  assert.equal(SCORE_WEIGHTS.punctuality, 25);
  assert.equal(SCORE_WEIGHTS.regularity, 25);
});

// ── assessRisk (Low/Med/High, never a %) ────────────────────────────────────────

test('risk: strong student → low', () => {
  const r = assessRisk(facts());
  assert.equal(r.level, 'low');
  assert.ok(r.index < 30);
});

test('risk: poor attendance + streak + recent drop → high', () => {
  const r = assessRisk(facts({
    openDays: 20, presentDays: 6, lateDays: 0, absentDays: 14,
    currentAbsenceStreak: 5, daysSinceLastSeen: 7,
    recentAttendancePct: 20, priorAttendancePct: 60,
  }));
  assert.equal(r.level, 'high');
  assert.ok(r.factors.length > 0);
  // never exposed as a "%": factors are labels, level is categorical
  assert.ok(['low', 'medium', 'high'].includes(r.level));
});

test('risk: no data → low with explanatory factor', () => {
  const r = assessRisk(facts({ openDays: 0, presentDays: 0 }));
  assert.equal(r.level, 'low');
  assert.deepEqual(r.factors, ['No attendance data yet']);
});

test('risk: never-seen student counts days-since-seen at max', () => {
  const r = assessRisk(facts({
    openDays: 10, presentDays: 0, absentDays: 10,
    daysSinceLastSeen: null, currentAbsenceStreak: 10,
    recentAttendancePct: 0, priorAttendancePct: 0,
  }));
  assert.equal(r.level, 'high');
  assert.ok(r.factors.some((x) => x.toLowerCase().includes('never')));
});

// ── detectPatterns ──────────────────────────────────────────────────────────────

test('patterns: late-comer when >50% attended days late', () => {
  const p = detectPatterns(
    facts({ presentDays: 4, lateDays: 6 }),
    emptyWeekday(),
  );
  assert.ok(p.some((x) => x.key === 'late_comer'));
});

test('patterns: consecutive absences when streak >= 3', () => {
  const p = detectPatterns(facts({ currentAbsenceStreak: 4 }), emptyWeekday());
  assert.ok(p.some((x) => x.key === 'consecutive_absences'));
});

test('patterns: sharp drop when recent >=15 below prior', () => {
  const p = detectPatterns(
    facts({ recentAttendancePct: 60, priorAttendancePct: 90 }),
    emptyWeekday(),
  );
  assert.ok(p.some((x) => x.key === 'sharp_drop'));
});

test('patterns: monday absentee from weekday buckets', () => {
  const wb = emptyWeekday();
  wb.openDays[0] = 4; wb.absences[0] = 3; // Mondays: 3/4 absent
  const p = detectPatterns(facts(), wb);
  assert.ok(p.some((x) => x.key === 'monday_absentee'));
});

test('patterns: not-seen when daysSinceLastSeen >= 5', () => {
  const p = detectPatterns(facts({ daysSinceLastSeen: 6 }), emptyWeekday());
  assert.ok(p.some((x) => x.key === 'not_seen'));
});

test('patterns: clean student → none', () => {
  const p = detectPatterns(facts(), emptyWeekday());
  assert.deepEqual(p, []);
});

// ── defaulterStage ──────────────────────────────────────────────────────────────

test('defaulterStage: thresholds', () => {
  assert.equal(defaulterStage(90).stage, 'none');
  assert.equal(defaulterStage(84.9).stage, 'nudge');
  assert.equal(defaulterStage(74.9).stage, 'flag');
  assert.equal(defaulterStage(64.9).stage, 'counselor_call');
  assert.equal(defaulterStage(49.9).stage, 'parent_meeting');
  assert.equal(defaulterStage(39.9).stage, 'recovery_plan');
});

test('defaulterStage: nudge does not flag admin; flag and below do', () => {
  assert.equal(defaulterStage(80).flagForAdmin, false);
  assert.equal(defaulterStage(70).flagForAdmin, true);
  assert.equal(defaulterStage(30).flagForAdmin, true);
});

test('defaulterStage: on-track does not alert parent', () => {
  assert.equal(defaulterStage(90).shouldAlertParent, false);
  assert.equal(defaulterStage(80).shouldAlertParent, true);
});
