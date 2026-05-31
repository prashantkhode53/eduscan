/**
 * Firebase Cloud Messaging — thin wrapper around firebase-admin.
 *
 * Credentials come from FIREBASE_SERVICE_ACCOUNT_JSON env var (the full
 * service-account JSON as a string).  If the var is absent or malformed the
 * module initialises lazily so the rest of the backend still starts cleanly.
 */

import admin from 'firebase-admin';

let _initialised = false;

function init(): boolean {
  if (_initialised) return true;

  const raw = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  if (!raw) {
    console.warn('[FCM] FIREBASE_SERVICE_ACCOUNT_JSON not set — push notifications disabled');
    return false;
  }

  try {
    const serviceAccount = JSON.parse(raw);
    if (!admin.apps.length) {
      admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
    }
    _initialised = true;
    console.log('[FCM] Firebase Admin SDK initialised');
    return true;
  } catch (err) {
    console.error('[FCM] Failed to initialise Firebase Admin SDK:', err);
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
    await admin.messaging().send({
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
    // Stale / unregistered token — log at debug level, not error
    if (msg.includes('registration-token-not-registered') ||
        msg.includes('invalid-registration-token')) {
      console.debug(`[FCM] stale token discarded: ${payload.token.substring(0, 20)}…`);
    } else {
      console.error(`[FCM] send failed: ${msg}`);
    }
    return false;
  }
}
