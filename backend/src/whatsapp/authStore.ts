import path from 'path';
import fs from 'fs/promises';
import { query } from '../db/pool';

/**
 * PostgreSQL-backed session store for whatsapp-web.js RemoteAuth.
 *
 * whatsapp-web.js calls these four methods during the session lifecycle:
 *
 *   sessionExists → before boot: does the DB have a saved session?
 *   extract       → before boot: write session zip from DB → temp dir
 *   save          → after auth + every backupSyncIntervalMs: zip auth dir → DB
 *   delete        → on explicit logout: remove from DB
 *
 * Because the session is in Neon PostgreSQL (not on Render's ephemeral disk),
 * it survives deploys, restarts, and reconnects. QR is scanned exactly once.
 */
export class PostgresSessionStore {
  // wwebjs writes the zip here; we read/write from this path
  private readonly _tempDir: string;

  constructor() {
    this._tempDir = path.join(process.cwd(), '.wwebjs_temp');
  }

  // ── Store interface ───────────────────────────────────────────────────────

  async sessionExists({ session }: { session: string }): Promise<boolean> {
    try {
      const rows = await query<{ exists: boolean }>(
        `SELECT EXISTS(
           SELECT 1 FROM whatsapp_sessions_data WHERE session_id = $1
         ) AS exists`,
        [session],
      );
      const found = rows[0]?.exists === true;
      console.log(`[wa-auth] sessionExists(${session}): ${found}`);
      return found;
    } catch (err) {
      console.error('[wa-auth] sessionExists error:', _msg(err));
      return false;  // treat DB error as "no session" → show QR
    }
  }

  async save({ session }: { session: string }): Promise<void> {
    const zipPath = path.join(this._tempDir, `${session}.zip`);
    try {
      const data = await fs.readFile(zipPath);
      await query(
        `INSERT INTO whatsapp_sessions_data (session_id, session_data, updated_at)
         VALUES ($1, $2, NOW())
         ON CONFLICT (session_id)
         DO UPDATE SET session_data = EXCLUDED.session_data, updated_at = NOW()`,
        [session, data],
      );
      console.log(`[wa-auth] Session saved → DB (${_kb(data)} KB)`);
    } catch (err) {
      console.error('[wa-auth] save error:', _msg(err));
      // Non-fatal: next backup attempt will retry
    }
  }

  async extract({ session }: { session: string }): Promise<void> {
    try {
      const rows = await query<{ session_data: Buffer }>(
        `SELECT session_data FROM whatsapp_sessions_data WHERE session_id = $1`,
        [session],
      );
      if (!rows[0]?.session_data) {
        throw new Error(`No session row found in DB for session_id="${session}"`);
      }
      await fs.mkdir(this._tempDir, { recursive: true });
      const zipPath = path.join(this._tempDir, `${session}.zip`);
      await fs.writeFile(zipPath, rows[0].session_data);
      console.log(`[wa-auth] Session extracted ← DB (${_kb(rows[0].session_data)} KB)`);
    } catch (err) {
      console.error('[wa-auth] extract error:', _msg(err));
      throw err;  // rethrow so wwebjs falls back to QR
    }
  }

  async delete({ session }: { session: string }): Promise<void> {
    try {
      await query(
        `DELETE FROM whatsapp_sessions_data WHERE session_id = $1`,
        [session],
      );
      console.log(`[wa-auth] Session deleted from DB`);
    } catch (err) {
      console.error('[wa-auth] delete error:', _msg(err));
    }
  }
}

function _msg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function _kb(buf: Buffer): number {
  return Math.round(buf.length / 1024);
}
