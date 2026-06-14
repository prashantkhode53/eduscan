/**
 * In-process caches for the face-scan hot path.
 *
 * The academy scan endpoint (scanAcademy) previously transferred every active
 * student's 512-D embedding from Neon and JSON.parsed it on *every* scan. For
 * a few hundred students that is ~1 MB of JSONB + hundreds of parses per scan,
 * all on the event loop. These caches keep the parsed embeddings (as
 * Float64Array) and the academy's match threshold in process memory, refreshed
 * on a short TTL and invalidated immediately when a student's face/status
 * changes. The DB stays the source of truth; the cache only removes repeated
 * identical reads on the latency-critical path.
 */

import { academyQuery, academyQueryOne } from './poolManager';

export interface CachedStudent {
  id: string;
  first_name: string;
  last_name: string;
  mobile: string;
  parent_fcm_token: string | null;
  emb: Float64Array;
}

interface StudentRow {
  id: string;
  first_name: string;
  last_name: string;
  mobile: string;
  face_embedding: unknown;
  parent_fcm_token: string | null;
}

const EMB_TTL_MS    = 60_000;    // embeddings: refresh at most once a minute
const THRESH_TTL_MS = 300_000;   // threshold: changes almost never

const embCache     = new Map<string, { loadedAt: number; rows: CachedStudent[] }>();
const threshCache   = new Map<string, { loadedAt: number; value: number }>();
const dupThreshCache = new Map<string, { loadedAt: number; value: number }>();

/**
 * Active students (with a stored embedding) for an academy, parsed once and
 * reused for up to EMB_TTL_MS. Returns a shared array — callers must treat it
 * as read-only.
 */
export async function getActiveEmbeddings(slug: string): Promise<CachedStudent[]> {
  const hit = embCache.get(slug);
  if (hit && Date.now() - hit.loadedAt < EMB_TTL_MS) return hit.rows;

  const raw = await academyQuery<StudentRow>(
    slug,
    `SELECT id, first_name, last_name, mobile, face_embedding, parent_fcm_token
     FROM students
     WHERE status = 'active' AND face_embedding IS NOT NULL`
  );

  const rows: CachedStudent[] = [];
  for (const s of raw) {
    const parsed = typeof s.face_embedding === 'string'
      ? JSON.parse(s.face_embedding)
      : (s.face_embedding as number[]);
    if (!Array.isArray(parsed) || parsed.length === 0) continue;
    rows.push({
      id:               s.id,
      first_name:       s.first_name,
      last_name:        s.last_name,
      mobile:           s.mobile,
      parent_fcm_token: s.parent_fcm_token,
      emb:              Float64Array.from(parsed),
    });
  }

  embCache.set(slug, { loadedAt: Date.now(), rows });
  return rows;
}

/** Academy face-match threshold, cached. Falls back to [fallback] when unset. */
export async function getThreshold(slug: string, fallback = 0.75): Promise<number> {
  const hit = threshCache.get(slug);
  if (hit && Date.now() - hit.loadedAt < THRESH_TTL_MS) return hit.value;

  const row = await academyQueryOne<{ value: string }>(
    slug,
    `SELECT value FROM settings WHERE key = 'face_threshold'`
  );
  const parsed = parseFloat(row?.value ?? String(fallback));
  const value  = Number.isFinite(parsed) ? parsed : fallback;
  threshCache.set(slug, { loadedAt: Date.now(), value });
  return value;
}

/**
 * Academy face-DUPLICATE threshold (used at registration), cached. Stricter
 * than the scan threshold by default — a registration block should require a
 * very high-confidence match. Falls back to [fallback] when unset.
 */
export async function getDuplicateThreshold(slug: string, fallback = 0.88): Promise<number> {
  const hit = dupThreshCache.get(slug);
  if (hit && Date.now() - hit.loadedAt < THRESH_TTL_MS) return hit.value;

  const row = await academyQueryOne<{ value: string }>(
    slug,
    `SELECT value FROM settings WHERE key = 'face_duplicate_threshold'`
  );
  const parsed = parseFloat(row?.value ?? String(fallback));
  const value  = Number.isFinite(parsed) ? parsed : fallback;
  dupThreshCache.set(slug, { loadedAt: Date.now(), value });
  return value;
}

/**
 * Drop the cached embeddings for an academy. Call after any change to a
 * student's face_embedding or status (register, face update, delete) so the
 * next scan reloads a fresh set instead of waiting out the TTL.
 */
export function invalidateScanCache(slug: string): void {
  embCache.delete(slug);
}

/** Drop the cached match threshold for an academy (call when the setting changes). */
export function invalidateThreshold(slug: string): void {
  threshCache.delete(slug);
}
