/**
 * Pure matching core for One-Click (group photo) Attendance.
 *
 * Extracted from the controller so the security- and correctness-critical
 * logic — threshold gating, ambiguity margins, per-student dedupe, and
 * approve-payload sanitisation — is unit-testable without a database,
 * Express, or the InsightFace service. The controller stays a thin I/O shell.
 *
 * Tested in groupMatch.test.ts (run with `npm test`).
 */

import { cosineSimilarity } from './faceMatch';

/** Minimal shape of a candidate the matcher needs (CachedStudent satisfies it). */
export interface MatchCandidate {
  id: string;
  first_name: string;
  last_name: string;
  emb: ArrayLike<number>;
}

export interface GroupFaceInput {
  bbox: number[];
  embedding: number[];
}

export interface GroupMatch {
  student_id: string;
  first_name: string;
  last_name: string;
  confidence: number;
  bbox: number[];
}

export interface GroupMatchResult {
  matches: GroupMatch[];     // unique students, sorted by first name
  unmatchedFaces: number;    // below threshold, ambiguous, or duplicate faces
}

/** Top-2 gap below which a match is considered ambiguous (same as single scan). */
export const GROUP_MATCH_MARGIN = 0.02;

/**
 * Match every face from a group photo against the candidate embeddings.
 *
 * Guarantees:
 *  - a face below `threshold` never matches;
 *  - a face whose top-2 candidates are both >= threshold and within `margin`
 *    of each other is rejected as ambiguous (prevents sibling/look-alike
 *    misattribution — the admin can mark those students manually);
 *  - one student appears at most once; extra faces resolving to the same
 *    student keep the highest confidence and count as unmatched;
 *  - confidences are rounded to 4 decimal places.
 */
export function matchGroupFaces(
  faces: GroupFaceInput[],
  candidates: MatchCandidate[],
  threshold: number,
  margin: number = GROUP_MATCH_MARGIN,
): GroupMatchResult {
  const byStudent = new Map<string, GroupMatch>();
  let unmatched = 0;

  for (const face of faces) {
    let best: { cand: MatchCandidate; score: number } | null = null;
    let secondBest = 0;

    for (const c of candidates) {
      const score = cosineSimilarity(face.embedding, c.emb);
      if (!best || score > best.score) {
        secondBest = best?.score ?? 0;
        best = { cand: c, score };
      } else if (score > secondBest) {
        secondBest = score;
      }
    }

    const ambiguous =
      best !== null &&
      candidates.length > 1 &&
      secondBest >= threshold &&
      (best.score - secondBest) < margin;

    if (!best || best.score < threshold || ambiguous) {
      unmatched++;
      continue;
    }

    const conf = Math.round(best.score * 10000) / 10000;
    const prev = byStudent.get(best.cand.id);
    if (!prev) {
      byStudent.set(best.cand.id, {
        student_id: best.cand.id,
        first_name: best.cand.first_name,
        last_name:  best.cand.last_name,
        confidence: conf,
        bbox: face.bbox,
      });
    } else {
      // Duplicate face of an already-matched student — keep the best score,
      // count the extra face as unmatched so the UI stats stay honest.
      if (conf > prev.confidence) {
        prev.confidence = conf;
        prev.bbox = face.bbox;
      }
      unmatched++;
    }
  }

  const matches = [...byStudent.values()]
    .sort((a, b) => a.first_name.localeCompare(b.first_name));

  return { matches, unmatchedFaces: unmatched };
}

// ── Approve payload sanitisation ──────────────────────────────────────────────

export interface RawApproveEntry {
  student_id?: unknown;
  confidence?: unknown;
  manual?: unknown;
}

export interface CleanApproveEntry {
  student_id: string;
  checkin_mode: 'face_group' | 'face_group_m';
  confidence: number | null;   // null for manual entries
}

/** Hard cap on students approved in one request. */
export const MAX_APPROVE_ENTRIES = 500;

/**
 * Validate and normalise the approve payload against the course roster.
 *
 * Guarantees:
 *  - only students actually on the (active) course roster survive;
 *  - duplicated student_ids collapse to one entry (first occurrence wins);
 *  - confidence is coerced to a number in [0, 1] and rounded to 2 dp
 *    (matches the DECIMAL(4,2) column); anything non-numeric becomes 0;
 *  - manual entries carry mode 'face_group_m' and a null confidence.
 *
 * Returns the clean entries plus how many raw entries were skipped.
 */
export function sanitizeApproveEntries(
  raw: RawApproveEntry[],
  rosterIds: ReadonlySet<string>,
): { entries: CleanApproveEntry[]; skipped: number } {
  const seen = new Set<string>();
  const entries: CleanApproveEntry[] = [];
  let skipped = 0;

  for (const e of raw) {
    const sid = e.student_id;
    if (typeof sid !== 'string' || !rosterIds.has(sid) || seen.has(sid)) {
      skipped++;
      continue;
    }
    seen.add(sid);

    const manual = e.manual === true;
    let conf: number | null = null;
    if (!manual) {
      const n = typeof e.confidence === 'number' && Number.isFinite(e.confidence)
        ? e.confidence : 0;
      conf = Math.round(Math.min(1, Math.max(0, n)) * 100) / 100;
    }

    entries.push({
      student_id: sid,
      checkin_mode: manual ? 'face_group_m' : 'face_group',
      confidence: conf,
    });
  }

  return { entries, skipped };
}
