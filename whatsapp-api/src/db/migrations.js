const { query } = require('../config/database');
const logger = require('../utils/logger');

const MIGRATIONS = [
  {
    name: 'create_whatsapp_message_logs',
    sql: `
      CREATE TABLE IF NOT EXISTS whatsapp_message_logs (
        id              SERIAL       PRIMARY KEY,
        phone_number    VARCHAR(20)  NOT NULL,
        message_type    VARCHAR(50)  NOT NULL,
        message_content TEXT         NOT NULL,
        sent_at         TIMESTAMP,
        delivery_status VARCHAR(20)  NOT NULL DEFAULT 'pending',
        error_message   TEXT,
        retry_count     INTEGER      NOT NULL DEFAULT 0,
        created_at      TIMESTAMP    NOT NULL DEFAULT NOW(),
        updated_at      TIMESTAMP    NOT NULL DEFAULT NOW()
      );
      CREATE INDEX IF NOT EXISTS idx_wml_phone      ON whatsapp_message_logs(phone_number);
      CREATE INDEX IF NOT EXISTS idx_wml_created_at ON whatsapp_message_logs(created_at);
      CREATE INDEX IF NOT EXISTS idx_wml_status     ON whatsapp_message_logs(delivery_status);
    `,
  },
  {
    name: 'create_whatsapp_sessions',
    sql: `
      CREATE TABLE IF NOT EXISTS whatsapp_sessions (
        id           SERIAL      PRIMARY KEY,
        event_type   VARCHAR(50) NOT NULL,
        session_info JSONB,
        created_at   TIMESTAMP   NOT NULL DEFAULT NOW()
      );
      CREATE INDEX IF NOT EXISTS idx_ws_event_type ON whatsapp_sessions(event_type);
      CREATE INDEX IF NOT EXISTS idx_ws_created_at ON whatsapp_sessions(created_at);
    `,
  },
];

async function runMigrations() {
  logger.info('Running database migrations...');
  for (const { name, sql } of MIGRATIONS) {
    try {
      await query(sql);
      logger.info(`  ✔ ${name}`);
    } catch (err) {
      logger.error(`  ✘ ${name}: ${err.message}`);
      throw err;
    }
  }
  logger.info('Migrations complete');
}

module.exports = { runMigrations };
