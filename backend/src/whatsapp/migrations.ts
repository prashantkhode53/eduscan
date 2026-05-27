import { pool } from '../db/pool';

export async function runWhatsAppMigrations(): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // ── Message logs ──────────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS whatsapp_logs (
        id              SERIAL       PRIMARY KEY,
        phone_number    VARCHAR(20)  NOT NULL,
        message_type    VARCHAR(50)  NOT NULL,
        message_content TEXT         NOT NULL,
        sent_at         TIMESTAMPTZ,
        delivery_status VARCHAR(20)  NOT NULL DEFAULT 'pending',
        error_message   TEXT,
        retry_count     INT          NOT NULL DEFAULT 0,
        created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
        updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
      )
    `);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_wa_logs_phone      ON whatsapp_logs(phone_number)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_wa_logs_created_at ON whatsapp_logs(created_at)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_wa_logs_status     ON whatsapp_logs(delivery_status)`);

    // ── Event log (qr_generated, connected, disconnected …) ──────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS whatsapp_sessions (
        id           SERIAL      PRIMARY KEY,
        event_type   VARCHAR(50) NOT NULL,
        session_info JSONB,
        created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_wa_sessions_type ON whatsapp_sessions(event_type)`);

    // ── Persistent session storage (RemoteAuth) ───────────────────────────────
    // Stores the whatsapp-web.js session zip in Neon PostgreSQL so sessions
    // survive Render deploys and service restarts without a persistent disk.
    // QR only needs to be scanned once — ever — unless the user logs out.
    await client.query(`
      CREATE TABLE IF NOT EXISTS whatsapp_sessions_data (
        session_id   VARCHAR(100) PRIMARY KEY,
        session_data BYTEA        NOT NULL,
        created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
        updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
      )
    `);

    await client.query('COMMIT');
    console.log('✅ WhatsApp tables ready');
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('❌ WhatsApp migration failed:', err);
    throw err;
  } finally {
    client.release();
  }
}
