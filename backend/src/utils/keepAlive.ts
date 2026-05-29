import { query } from '../db/pool';
import { cacheReconcile } from './insightface';

const BACKEND_INTERVAL_MS     = 14 * 60 * 1000;  // 14 min — prevent backend sleep
const INSIGHTFACE_INTERVAL_MS = 10 * 60 * 1000;  // 10 min — prevent Python sleep
const RECONCILE_INTERVAL_MS   = 60 * 60 * 1000;  // 1 hour — stale cache cleanup
const RECONCILE_STARTUP_MS    = 35 * 1000;        // 35 s  — let InsightFace finish waking

async function pingBackend(serverUrl: string): Promise<void> {
  try {
    const res  = await fetch(`${serverUrl}/api/health`, { signal: AbortSignal.timeout(10_000) });
    const data = await res.json() as { status: string };
    console.log(`💓 Backend keep-alive: ${data.status}`);
  } catch {
    console.warn('⚠️  Backend keep-alive ping failed');
  }
}

async function pingInsightFace(insightfaceUrl: string): Promise<void> {
  try {
    const res  = await fetch(`${insightfaceUrl}/health`, { signal: AbortSignal.timeout(15_000) });
    const data = await res.json() as { ready: boolean };
    console.log(`🧠 InsightFace keep-alive: ready=${data.ready}`);
  } catch {
    console.warn('⚠️  InsightFace keep-alive ping failed (may still be waking)');
  }
}

async function reconcileCache(insightfaceUrl: string): Promise<void> {
  try {
    // Fetch only IDs of students who have a face embedding stored
    const rows = await query<{ id: string }>(
      `SELECT id FROM students WHERE status = 'active' AND face_embedding IS NOT NULL`
    );
    const validIds = rows.map(r => r.id);
    const { kept, removed } = await cacheReconcile(validIds);
    if (removed > 0) {
      console.log(`🧹 Cache reconcile: ${removed} stale entries removed, ${kept} kept`);
    }
  } catch {
    // Non-fatal — runs again next hour
    console.warn('⚠️  Cache reconcile failed (will retry next hour)');
  }
}

export function startKeepAlive(serverUrl: string): void {
  const insightfaceUrl = process.env.INSIGHTFACE_URL;

  // Backend self-ping
  setInterval(() => pingBackend(serverUrl), BACKEND_INTERVAL_MS);
  console.log(`💓 Backend keep-alive started — every 14 min`);

  if (insightfaceUrl) {
    // Warm-up ping immediately + every 10 min
    pingInsightFace(insightfaceUrl);
    setInterval(() => pingInsightFace(insightfaceUrl), INSIGHTFACE_INTERVAL_MS);
    console.log(`🧠 InsightFace keep-alive started — every 10 min`);

    // Reconcile: wait 35s for InsightFace to finish cold-start, then run hourly
    setTimeout(() => {
      reconcileCache(insightfaceUrl);
      setInterval(() => reconcileCache(insightfaceUrl), RECONCILE_INTERVAL_MS);
      console.log(`🧹 Cache reconcile scheduled — every 1 hour`);
    }, RECONCILE_STARTUP_MS);
  } else {
    console.warn('⚠️  INSIGHTFACE_URL not set — InsightFace keep-alive and reconcile disabled');
  }
}
