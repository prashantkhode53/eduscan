/**
 * Thin HTTP proxy to the Python InsightFace microservice.
 *
 * INSIGHTFACE_URL defaults to http://localhost:8000 so local docker-compose
 * and Render both work without code changes (Render injects the internal URL).
 */

const BASE_URL = (process.env.INSIGHTFACE_URL ?? 'http://localhost:8000').replace(/\/$/, '');

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
 * Send multiple base64-encoded JPEG images to Python and get back a 512-D
 * averaged ArcFace embedding.  Called during student registration.
 */
export async function batchEmbed(imagesB64: string[]): Promise<EmbedResult> {
  const response = await fetch(`${BASE_URL}/embed/batch`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ images_b64: imagesB64 }),
    signal: AbortSignal.timeout(30_000),
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
