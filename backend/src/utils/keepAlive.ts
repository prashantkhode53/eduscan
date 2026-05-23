// Pings the server every 14 minutes to prevent Render free tier sleep
export function startKeepAlive(serverUrl: string): void {
  const INTERVAL_MS = 14 * 60 * 1000;

  setInterval(async () => {
    try {
      const response = await fetch(`${serverUrl}/api/health`);
      const data = await response.json() as { status: string };
      console.log(`💓 Keep-alive ping: ${data.status} at ${new Date().toISOString()}`);
    } catch (err) {
      console.warn('⚠️  Keep-alive ping failed:', err);
    }
  }, INTERVAL_MS);

  console.log(`💓 Keep-alive started — pinging every 14 minutes`);
}
