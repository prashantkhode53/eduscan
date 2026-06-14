/**
 * Thin HTTP proxy to the Python InsightFace microservice.
 *
 * INSIGHTFACE_URL defaults to http://localhost:8000 so local docker-compose
 * and Render both work without code changes (Render injects the internal URL).
 */

// Normalise the URL: add https:// if the env var is a bare hostname (Render's
// `property: host` returns just the hostname without a scheme).
const _rawUrl = process.env.INSIGHTFACE_URL ?? 'http://localhost:8000';
const BASE_URL = (_rawUrl.startsWith('http') ? _rawUrl : `https://${_rawUrl}`).replace(/\/$/, '');

export interface EmbedResult {
  success: boolean;
  embedding?: number[];
  quality?: number;
  reason?: string;
  samples_used?: number;
}

export interface MatchResult {
  success: boolean;
  matched: boolean;
  student_id?: string;
  confidence?: number;
  margin?: number;
  quality?: number;
  reason?: string;
  student?: {
    first_name: string;
    last_name: string;
    class_grade: string;
    division: string;
    roll_no: number | null;
  };
}

/**
 * Fire-and-forget GET to /health so the InsightFace service wakes up on
 * Render's free tier before the face-capture step needs it.  Errors are
 * intentionally swallowed — this is best-effort only.
 */
export function warmup(): void {
  fetch(`${BASE_URL}/health`, { signal: AbortSignal.timeout(90_000) })
    .catch(() => { /* ignore — warmup is best-effort */ });
}

/**
 * Probe InsightFace readiness for the scan-screen warmup.
 *
 * Returns:
 *   reachable — the container answered (HTTP responded) within the timeout
 *   ready     — the container answered AND the ArcFace model is loaded
 *
 * On a cold Render container the fetch will time out; we report
 * { reachable:false, ready:false } but the request itself nudges Render to
 * start spinning the container up, so repeated polls converge to ready.
 */
export async function checkReady(timeoutMs = 5_000): Promise<{ reachable: boolean; ready: boolean }> {
  try {
    const res = await fetch(`${BASE_URL}/health`, { signal: AbortSignal.timeout(timeoutMs) });
    if (!res.ok) return { reachable: true, ready: false };
    const data = await res.json() as { ready?: boolean };
    return { reachable: true, ready: data.ready === true };
  } catch {
    return { reachable: false, ready: false };
  }
}

/**
 * Send multiple base64-encoded JPEG images to Python and get back a 512-D
 * averaged ArcFace embedding.  Called during student registration.
 * Timeout is 90 s to survive a cold-start on Render's free tier.
 */
export async function batchEmbed(imagesB64: string[]): Promise<EmbedResult> {
  const response = await fetch(`${BASE_URL}/embed/batch`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ images_b64: imagesB64 }),
    signal: AbortSignal.timeout(90_000),
  });
  if (!response.ok) {
    throw new Error(`InsightFace /embed/batch returned ${response.status}`);
  }
  return response.json() as Promise<EmbedResult>;
}

/**
 * Send a single base64-encoded JPEG to Python for identity matching against
 * the Redis embedding cache.  Called on every attendance scan.
 */
export async function matchFace(imageB64: string): Promise<MatchResult> {
  const imgBuf = Buffer.from(imageB64, 'base64');
  const formData = new FormData();
  formData.append('image', new Blob([imgBuf], { type: 'image/jpeg' }), 'face.jpg');

  const response = await fetch(`${BASE_URL}/match`, {
    method: 'POST',
    body: formData,
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) {
    throw new Error(`InsightFace /match returned ${response.status}`);
  }
  return response.json() as Promise<MatchResult>;
}

/**
 * Upsert a student's embedding in the Redis cache after registration.
 */
export async function cacheUpsert(params: {
  student_id: string;
  embedding: number[];
  first_name: string;
  last_name: string;
  class_grade: string;
  division: string;
  roll_no: number | null;
}): Promise<void> {
  const response = await fetch(`${BASE_URL}/cache/upsert`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(params),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) {
    throw new Error(`InsightFace /cache/upsert returned ${response.status}`);
  }
}

/**
 * Remove a student's embedding from the Redis cache on deletion.
 */
export async function cacheDelete(studentId: string): Promise<void> {
  const response = await fetch(`${BASE_URL}/cache/${encodeURIComponent(studentId)}`, {
    method: 'DELETE',
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) {
    throw new Error(`InsightFace /cache/${studentId} DELETE returned ${response.status}`);
  }
}

/**
 * Trigger a full reload of the Redis cache from PostgreSQL.
 * Useful after bulk imports or cache invalidation.
 */
export async function cacheReload(): Promise<number> {
  const response = await fetch(`${BASE_URL}/cache/reload`, {
    method: 'POST',
    signal: AbortSignal.timeout(60_000),
  });
  if (!response.ok) {
    throw new Error(`InsightFace /cache/reload returned ${response.status}`);
  }
  const body = await response.json() as { loaded?: number };
  return body.loaded ?? 0;
}

/**
 * Reconcile Redis cache against a known list of valid student IDs.
 * Removes only stale entries — far cheaper than a full reload.
 */
export async function cacheReconcile(validIds: string[]): Promise<{ kept: number; removed: number }> {
  const response = await fetch(`${BASE_URL}/cache/reconcile`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ valid_ids: validIds }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) {
    throw new Error(`InsightFace /cache/reconcile returned ${response.status}`);
  }
  const body = await response.json() as { kept?: number; removed?: number };
  return { kept: body.kept ?? 0, removed: body.removed ?? 0 };
}
