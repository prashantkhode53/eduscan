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
 * Convert a lock key string to a stable pair of signed int4 classid/objid for
 * the two-arg `pg_advisory_xact_lock(int4, int4)` overload.
 *
 * We compute this in Node.js (not via hashtext() in SQL) because hashtext()
 * returns int4 and casting to int8 triggers PG error 42883 on Neon/PgBouncer.
 * We deliberately use the (int4, int4) overload — NOT (bigint) — because a
 * single bigint argument requires either a runtime cast or a typed parameter,
 * and on PgBouncer transaction-mode connections that surfaces as 42883
 * (overload ambiguity, small positive ints) or 42P08 (indeterminate parameter
 * type for `$1::bigint`). Two plain int4 values bind unambiguously as JS
 * numbers with no cast, so neither error can occur.
 *
 * SHA-256 → first 4 bytes = classid (int4), next 4 bytes = objid (int4),
 * both read as signed so they always fit Postgres' int4 range.
 */
export function slugToLockId(key: string): { classId: number; objId: number } {
  const buf = createHash('sha256').update(key).digest();
  return {
    classId: buf.readInt32BE(0),
    objId:   buf.readInt32BE(4),
  };
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
      ${hasExclude ? 'AND s.id <> $1' : ''}
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
