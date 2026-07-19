/**
 * Unit tests for the One-Click Attendance matching core.
 *
 * Uses Node's built-in test runner — no jest/vitest dependency.
 * Run:  npm test
 *
 * Embedding trick: cosineSimilarity on axis-aligned unit vectors is exact
 * (identical axis -> 1.0, different axis -> 0.0), and mixing axes gives
 * precisely controllable scores, so every threshold/margin case can be
 * asserted deterministically without a real face model.
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  matchGroupFaces,
  sanitizeApproveEntries,
  GROUP_MATCH_MARGIN,
  MatchCandidate,
} from './groupMatch';

const DIM = 8;

/** Unit vector along one axis. */
function axis(i: number): number[] {
  const v = new Array(DIM).fill(0);
  v[i] = 1;
  return v;
}

/**
 * A vector whose cosine similarity with axis(i) is exactly `score`
 * (and orthogonal leakage goes to the last axis).
 */
function towards(i: number, score: number): number[] {
  const v = new Array(DIM).fill(0);
  v[i] = score;
  v[DIM - 1] = Math.sqrt(1 - score * score);
  return v;
}

function cand(id: string, axisIdx: number, name = id): MatchCandidate {
  return { id, first_name: name, last_name: 'T', emb: axis(axisIdx) };
}

const BBOX = [0, 0, 50, 50];
const face = (emb: number[]) => ({ bbox: BBOX, embedding: emb });

// ── matchGroupFaces ───────────────────────────────────────────────────────────

test('exact match above threshold is returned with confidence 1.0', () => {
  const r = matchGroupFaces([face(axis(0))], [cand('A', 0), cand('B', 1)], 0.6);
  assert.equal(r.matches.length, 1);
  assert.equal(r.matches[0].student_id, 'A');
  assert.equal(r.matches[0].confidence, 1);
  assert.equal(r.unmatchedFaces, 0);
});

test('a face below threshold never matches', () => {
  // similarity with A = 0.55 < threshold 0.6
  const r = matchGroupFaces([face(towards(0, 0.55))], [cand('A', 0)], 0.6);
  assert.equal(r.matches.length, 0);
  assert.equal(r.unmatchedFaces, 1);
});

test('score exactly at threshold matches (>= semantics, same as single scan)', () => {
  // Use the *computed* similarity as the threshold so binary-float rounding
  // of 0.6 can never flip the comparison.
  const emb = towards(0, 0.6);
  const { cosineSimilarity } = require('./faceMatch');
  const th = cosineSimilarity(emb, axis(0));
  const r = matchGroupFaces([face(emb)], [cand('A', 0)], th);
  assert.equal(r.matches.length, 1);
});

test('ambiguous match (top-2 both above threshold, gap < margin) is rejected', () => {
  // Face equidistant-ish from A and B: sim(A)=0.71, sim(B)=0.70 -> gap 0.01 < 0.02
  const v = new Array(DIM).fill(0);
  v[0] = 0.71; v[1] = 0.70;
  const norm = Math.hypot(...v);
  const emb = v.map(x => x / norm); // normalising scales both sims equally -> gap ratio holds
  const r = matchGroupFaces([face(emb)], [cand('A', 0), cand('B', 1)], 0.6);
  assert.equal(r.matches.length, 0);
  assert.equal(r.unmatchedFaces, 1);
});

test('clear winner with runner-up below threshold is NOT ambiguous', () => {
  // sim(A)=0.9; sim(B)=0 -> margin check must not fire even though gap logic runs
  const r = matchGroupFaces([face(towards(0, 0.9))], [cand('A', 0), cand('B', 1)], 0.6);
  assert.equal(r.matches.length, 1);
  assert.equal(r.matches[0].student_id, 'A');
});

test('single-candidate roster skips the ambiguity gate', () => {
  const r = matchGroupFaces([face(towards(0, 0.8))], [cand('A', 0)], 0.6, GROUP_MATCH_MARGIN);
  assert.equal(r.matches.length, 1);
});

test('two faces of the same student dedupe to the higher confidence', () => {
  const faces = [face(towards(0, 0.7)), face(towards(0, 0.95))];
  const r = matchGroupFaces(faces, [cand('A', 0)], 0.6);
  assert.equal(r.matches.length, 1);
  assert.ok(Math.abs(r.matches[0].confidence - 0.95) < 1e-9);
  assert.equal(r.unmatchedFaces, 1); // the duplicate face counts as unmatched
});

test('dedupe keeps first bbox when the later face scores lower', () => {
  const hi = { bbox: [1, 1, 2, 2], embedding: towards(0, 0.95) };
  const lo = { bbox: [3, 3, 4, 4], embedding: towards(0, 0.7) };
  const r = matchGroupFaces([hi, lo], [cand('A', 0)], 0.6);
  assert.deepEqual(r.matches[0].bbox, [1, 1, 2, 2]);
});

test('multiple students in one photo all match independently', () => {
  const faces = [face(axis(0)), face(axis(1)), face(axis(2))];
  const cands = [cand('B', 1, 'Bina'), cand('A', 0, 'Asha'), cand('C', 2, 'Chirag')];
  const r = matchGroupFaces(faces, cands, 0.6);
  assert.equal(r.matches.length, 3);
  // sorted by first name
  assert.deepEqual(r.matches.map(m => m.first_name), ['Asha', 'Bina', 'Chirag']);
});

test('empty candidate list matches nothing and counts all faces unmatched', () => {
  const r = matchGroupFaces([face(axis(0)), face(axis(1))], [], 0.6);
  assert.equal(r.matches.length, 0);
  assert.equal(r.unmatchedFaces, 2);
});

test('empty face list returns an empty, valid result', () => {
  const r = matchGroupFaces([], [cand('A', 0)], 0.6);
  assert.deepEqual(r, { matches: [], unmatchedFaces: 0 });
});

test('confidence is rounded to 4 decimal places', () => {
  const r = matchGroupFaces([face(towards(0, 0.876543))], [cand('A', 0)], 0.6);
  const s = String(r.matches[0].confidence).split('.')[1] ?? '';
  assert.ok(s.length <= 4, `confidence ${r.matches[0].confidence} has >4 dp`);
});

// ── sanitizeApproveEntries ────────────────────────────────────────────────────

const ROSTER = new Set(['S1', 'S2', 'S3']);

test('valid face entry passes through with clamped, rounded confidence', () => {
  const { entries, skipped } = sanitizeApproveEntries(
    [{ student_id: 'S1', confidence: 0.87654 }], ROSTER);
  assert.equal(skipped, 0);
  assert.deepEqual(entries, [
    { student_id: 'S1', checkin_mode: 'face_group', confidence: 0.88 },
  ]);
});

test('manual entry gets manual mode and null confidence', () => {
  const { entries } = sanitizeApproveEntries(
    [{ student_id: 'S2', manual: true, confidence: 0.99 }], ROSTER);
  assert.deepEqual(entries, [
    { student_id: 'S2', checkin_mode: 'face_group_m', confidence: null },
  ]);
});

test('students not on the course roster are skipped', () => {
  const { entries, skipped } = sanitizeApproveEntries(
    [{ student_id: 'INTRUDER', confidence: 0.9 }, { student_id: 'S3' }], ROSTER);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].student_id, 'S3');
  assert.equal(skipped, 1);
});

test('duplicate student_ids collapse to the first occurrence', () => {
  const { entries, skipped } = sanitizeApproveEntries(
    [{ student_id: 'S1', confidence: 0.7 }, { student_id: 'S1', confidence: 0.9 }],
    ROSTER);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].confidence, 0.7);
  assert.equal(skipped, 1);
});

test('malformed entries (missing/non-string id, weird confidence) are safe', () => {
  const { entries, skipped } = sanitizeApproveEntries(
    [
      {},                                        // no id
      { student_id: 42 },                        // non-string id
      { student_id: 'S1', confidence: 'high' },  // non-numeric conf -> 0
      { student_id: 'S2', confidence: Infinity },// non-finite -> 0
      { student_id: 'S3', confidence: 7 },       // >1 -> clamped to 1
    ],
    ROSTER);
  assert.equal(skipped, 2);
  assert.deepEqual(entries.map(e => e.confidence), [0, 0, 1]);
});

test('negative confidence clamps to 0', () => {
  const { entries } = sanitizeApproveEntries(
    [{ student_id: 'S1', confidence: -0.4 }], ROSTER);
  assert.equal(entries[0].confidence, 0);
});
