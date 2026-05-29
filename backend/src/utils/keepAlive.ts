const BACKEND_INTERVAL_MS   = 14 * 60 * 1000;  // 14 min — backend self-ping
const INSIGHTFACE_INTERVAL_MS = 10 * 60 * 1000; // 10 min — Python service wakes after 15 min idle

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

export function startKeepAlive(serverUrl: string): void {
  const insightfaceUrl = process.env.INSIGHTFACE_URL;

  // Backend self-ping — prevents Render from sleeping the Node.js service
  setInterval(() => pingBackend(serverUrl), BACKEND_INTERVAL_MS);
  console.log(`💓 Backend keep-alive started — every 14 min`);

  // InsightFace warm-up — keeps Python service from sleeping before face ops
  if (insightfaceUrl) {
    // Ping once immediately on startup so the model is warm before first user action
    pingInsightFace(insightfaceUrl);
    setInterval(() => pingInsightFace(insightfaceUrl), INSIGHTFACE_INTERVAL_MS);
    console.log(`🧠 InsightFace keep-alive started — every 10 min (${insightfaceUrl})`);
  } else {
    console.warn('⚠️  INSIGHTFACE_URL not set — InsightFace keep-alive disabled');
  }
}
