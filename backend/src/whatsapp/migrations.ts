import { pool } from '../db/pool';

export async function runWhatsAppMigrations(): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

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

    await client.query(`
      CREATE TABLE IF NOT EXISTS whatsapp_sessions (
        id           SERIAL      PRIMARY KEY,
        event_type   VARCHAR(50) NOT NULL,
        session_info JSONB,
        created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_wa_sessions_type ON whatsapp_sessions(event_type)`);

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
