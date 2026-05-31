/**
 * Firebase Cloud Messaging — thin, crash-proof wrapper around firebase-admin.
 *
 * firebase-admin is loaded LAZILY via require() inside init(), wrapped in
 * try/catch.  This guarantees the rest of the backend keeps running even if:
 *   - the firebase-admin package is not installed
 *   - FIREBASE_SERVICE_ACCOUNT_JSON is absent or malformed
 *   - Firebase initialisation fails for any reason
 *
 * A static top-level `import` would crash the entire server at startup if the
 * package were missing — which we explicitly avoid here.
 */

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let _admin: any = null;
let _initTried = false;

function init(): boolean {
  if (_admin) return true;
  if (_initTried) return false; // don't retry a known failure every call
  _initTried = true;

  const raw = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  if (!raw) {
    console.warn('[FCM] FIREBASE_SERVICE_ACCOUNT_JSON not set — push notifications disabled');
    return false;
  }

  try {
    // Lazy require — never crashes the server if the package is missing
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const admin = require('firebase-admin');
    const serviceAccount = JSON.parse(raw);
    if (!admin.apps.length) {
      admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
    }
    _admin = admin;
    console.log('[FCM] Firebase Admin SDK initialised');
    return true;
  } catch (err) {
    console.error('[FCM] Firebase init failed — push notifications disabled:', err);
    return false;
  }
}

export interface FcmPayload {
  token: string;
  title: string;
  body:  string;
  data?: Record<string, string>;
}

/**
 * Send a single FCM notification.
 * Never throws — logs on failure and returns false so callers can ignore it.
 */
export async function sendFcm(payload: FcmPayload): Promise<boolean> {
  if (!init()) return false;
  try {
    await _admin.messaging().send({
      token: payload.token,
      notification: { title: payload.title, body: payload.body },
      data: payload.data ?? {},
      android: {
        priority: 'high',
        notification: {
          channelId: 'eduscan_alerts',
          priority:  'max',
          sound:     'default',
          defaultSound: true,
        },
      },
      apns: {
        payload: { aps: { sound: 'default', badge: 1 } },
      },
    });
    return true;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes('registration-token-not-registered') ||
        msg.includes('invalid-registration-token')) {
      console.debug(`[FCM] stale token discarded: ${payload.token.substring(0, 20)}…`);
    } else {
      console.error(`[FCM] send failed: ${msg}`);
    }
    return false;
  }
}
