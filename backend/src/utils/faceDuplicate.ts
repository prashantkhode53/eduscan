/**
 * Schema-scoped face-duplicate detection.
 *
 * Business rule: a face must be unique *within an academy schema*. The same
 * face may exist in different academies (independent enrollment spaces), so
 * matching must never cross schema boundaries.
 *
 * Why this exists (vs. the old approach): the previous duplicate check used the
 * InsightFace Redis `/match`, which returns the single global best match across
 * ALL academies and is then schema-filtered. That has two holes:
 *   1. Cross-academy masking — if the same face scores higher in another
 *      academy, that match hides a genuine same-schema duplicate, so the
 *      registration is wrongly allowed.
 *   2. Cache dependency — a student whose `cacheUpsert` failed (it is non-fatal)
 *      is absent from Redis and therefore invisible to the check.
 *
 * This module compares the candidate embedding against THIS academy's active
 * faces straight from PostgreSQL (the source of truth), so both holes close.
 */

import { createHash } from 'crypto';
import { PoolClient } from 'pg';
import { academyQuery } from '../db/poolManager';
import { cosineSimilarity } from './faceMatch';

/** Stable per-academy key component for pg_advisory_xact_lock. */
export const FACE_LOCK_KEY = 'face_register';

/**
 * Convert a lock key string to a stable int64 for pg_advisory_xact_lock.
 *
 * We compute this in Node.js (not via hashtext() in SQL) because hashtext()
 * returns int4 and the cast to int8 triggers PG error 42883 on Neon/PgBouncer
 * transaction-mode connections that resolve function overloads differently.
 * SHA-256 → take first 8 bytes as a signed BigInt → clamp to JS safe integer.
 */
export function slugToLockId(key: string): string {
  const buf = createHash('sha256').update(key).digest();
  // Read first 8 bytes as a signed 64-bit big-endian integer.
  const hi = buf.readInt32BE(0);
  const lo = buf.readUInt32BE(4);
  const big = (BigInt(hi) << 32n) | BigInt(lo);
  return big.toString();
}

export interface DuplicateMatch {
  student_id: string;
  student_name: string;
  confidence: number;       // rounded cosine similarity in [0,1]
  courses: string[];
  registered_at: string | null;
}

interface DupRow {
  id: string;
  first_name: string;
  last_name: string;
  created_at: string | null;
  face_embedding: unknown;
  course_names: string[];
}

function selectSql(hasExclude: boolean): string {
  return `
    SELECT s.id, s.first_name, s.last_name, s.created_at, s.face_embedding,
           COALESCE(
             json_agg(c.name ORDER BY c.name) FILTER (WHERE c.id IS NOT NULL),
             '[]'
           ) AS course_names
    FROM students s
    LEFT JOIN student_courses sc ON sc.student_id = s.id AND sc.status = 'active'
    LEFT JOIN courses c ON c.id = sc.course_id
    WHERE s.status = 'active' AND s.face_embedding IS NOT NULL
      ${hasExclude ? 'AND s.id <> $1::uuid' : ''}
    GROUP BY s.id`;
}

function pickBest(rows: DupRow[], incoming: number[], threshold: number): DuplicateMatch | null {
  let best: DuplicateMatch | null = null;
  for (const r of rows) {
    const emb = typeof r.face_embedding === 'string'
      ? JSON.parse(r.face_embedding)
      : (r.face_embedding as number[]);
    if (!Array.isArray(emb) || emb.length !== incoming.length) continue;

    const score = cosineSimilarity(incoming, emb);
    if (score >= threshold && (!best || score > best.confidence)) {
      best = {
        student_id:    r.id,
        student_name:  `${r.first_name} ${r.last_name}`.trim(),
        confidence:    Math.round(score * 10000) / 10000,
        courses:       r.course_names ?? [],
        registered_at: r.created_at ?? null,
      };
    }
  }
  return best;
}

/**
 * Find the best same-schema duplicate of [incoming] at or above [threshold].
 * Runs in its own transaction — use for the fast pre-insert check.
 * Pass [excludeId] to ignore the student being updated (face re-capture).
 */
export async function findSchemaDuplicate(
  slug: string,
  incoming: number[],
  threshold: number,
  excludeId: string | null = null,
): Promise<DuplicateMatch | null> {
  const rows = await academyQuery<DupRow>(
    slug, selectSql(!!excludeId), excludeId ? [excludeId] : []
  );
  return pickBest(rows, incoming, threshold);
}

/**
 * Same as [findSchemaDuplicate] but reuses an existing transaction client
 * (search_path already set by academyTransaction). Call under an advisory lock
 * so the check-then-insert is atomic and race-proof.
 */
export async function findSchemaDuplicateTx(
  client: PoolClient,
  incoming: number[],
  threshold: number,
  excludeId: string | null = null,
): Promise<DuplicateMatch | null> {
  const res = await client.query(selectSql(!!excludeId), excludeId ? [excludeId] : []);
  return pickBest(res.rows as DupRow[], incoming, threshold);
}
