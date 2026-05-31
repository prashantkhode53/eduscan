/**
 * Schema migrations for each academy.
 * Creates a dedicated PostgreSQL schema named after the academy slug,
 * then creates all tables within it.
 * Safe to call multiple times — uses IF NOT EXISTS throughout.
 */

import bcrypt from 'bcrypt';
import { v4 as uuidv4 } from 'uuid';
import { sharedPool } from './poolManager';

/**
 * Boot-time reconciliation for ALL existing academy schemas.
 *
 * Academies created with an older schema version may be missing columns that
 * newer features write to (e.g. parent_fcm_token, or personal-info columns if
 * the students table predates them).  CREATE TABLE IF NOT EXISTS never alters
 * an existing table, so we add the columns idempotently here on every boot.
 */
export async function reconcileAcademySchemas(): Promise<void> {
  let slugs: { slug: string }[] = [];
  try {
    const { rows } = await sharedPool.query<{ slug: string }>(
      `SELECT slug FROM academies WHERE status = 'active'`
    );
    slugs = rows;
  } catch (err) {
    console.error('[Reconcile] could not list academies:', err);
    return;
  }

  let ok = 0;
  for (const { slug } of slugs) {
    if (!/^[a-z0-9_]{1,63}$/.test(slug)) continue;
    const client = await sharedPool.connect();
    try {
      await client.query(`SET search_path TO "${slug}", public`);
      await client.query(`
        ALTER TABLE IF EXISTS students
          ADD COLUMN IF NOT EXISTS dob              DATE,
          ADD COLUMN IF NOT EXISTS gender           VARCHAR(10),
          ADD COLUMN IF NOT EXISTS email            VARCHAR(100),
          ADD COLUMN IF NOT EXISTS parent_name      VARCHAR(100),
          ADD COLUMN IF NOT EXISTS parent_mobile    VARCHAR(15),
          ADD COLUMN IF NOT EXISTS address          TEXT,
          ADD COLUMN IF NOT EXISTS face_quality     DECIMAL(4,2),
          ADD COLUMN IF NOT EXISTS parent_fcm_token TEXT,
          ADD COLUMN IF NOT EXISTS updated_at       TIMESTAMPTZ DEFAULT NOW()
      `);
      ok++;
    } catch (err) {
      console.error(`[Reconcile] schema "${slug}" failed:`, err);
    } finally {
      try { await client.query('SET search_path TO public'); } catch (_) {}
      client.release();
    }
  }
  console.log(`[Reconcile] ${ok}/${slugs.length} academy schema(s) reconciled`);
}

export interface AcademyAdminSeed {
  name: string;
  email: string;
  phone: string;
  password: string;
}

export async function runAcademyMigrations(
  slug: string,
  admin: AcademyAdminSeed
): Promise<{ userId: string }> {
  const client = await sharedPool.connect();
  try {
    // 1 — Create schema
    await client.query(`CREATE SCHEMA IF NOT EXISTS "${slug}"`);
    await client.query(`SET search_path TO "${slug}", public`);

    await client.query('BEGIN');

    await client.query(`CREATE EXTENSION IF NOT EXISTS "pgcrypto"`);

    // ── Users ─────────────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS users (
        id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        role            VARCHAR(20) NOT NULL
                          CHECK (role IN ('admin','teacher','student','parent')),
        name            VARCHAR(100) NOT NULL,
        email           VARCHAR(100) UNIQUE NOT NULL,
        phone           VARCHAR(15),
        password_hash   TEXT NOT NULL,
        avatar_url      TEXT,
        fcm_token       TEXT,
        is_active       BOOLEAN DEFAULT TRUE,
        failed_attempts INT DEFAULT 0,
        last_login      TIMESTAMPTZ,
        otp_code        VARCHAR(6),
        otp_expires_at  TIMESTAMPTZ,
        created_at      TIMESTAMPTZ DEFAULT NOW(),
        updated_at      TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    // ── Students ──────────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS students (
        id              VARCHAR(20) PRIMARY KEY,
        user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
        first_name      VARCHAR(50) NOT NULL,
        middle_name     VARCHAR(50),
        last_name       VARCHAR(50) NOT NULL,
        dob             DATE,
        gender          VARCHAR(10),
        blood_group     VARCHAR(5),
        mobile          VARCHAR(15) NOT NULL,
        email           VARCHAR(100),
        parent_name     VARCHAR(100),
        parent_mobile   VARCHAR(15),
        address         TEXT,
        face_embedding    JSONB,
        face_quality      DECIMAL(4,2),
        parent_fcm_token  TEXT,
        status            VARCHAR(10) DEFAULT 'active',
        created_at        TIMESTAMPTZ DEFAULT NOW(),
        updated_at        TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    // Idempotent column addition for academies created before parent-notification feature
    await client.query(`
      ALTER TABLE IF EXISTS students
        ADD COLUMN IF NOT EXISTS parent_fcm_token TEXT
    `);

    // ── Courses ───────────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS courses (
        id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        name            VARCHAR(100) NOT NULL,
        description     TEXT,
        subject         VARCHAR(50),
        duration_months INT,
        default_fee     DECIMAL(10,2) DEFAULT 0,
        schedule        VARCHAR(20) DEFAULT 'monthly'
                          CHECK (schedule IN ('monthly','quarterly','onetime')),
        is_active       BOOLEAN DEFAULT TRUE,
        created_at      TIMESTAMPTZ DEFAULT NOW(),
        updated_at      TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    // ── Student-Course enrollment ─────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS student_courses (
        id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        student_id  VARCHAR(20) REFERENCES students(id) ON DELETE CASCADE,
        course_id   UUID REFERENCES courses(id) ON DELETE CASCADE,
        fee_amount  DECIMAL(10,2) NOT NULL,
        start_date  DATE NOT NULL DEFAULT CURRENT_DATE,
        end_date    DATE,
        status      VARCHAR(10) DEFAULT 'active'
                      CHECK (status IN ('active','completed','dropped')),
        created_at  TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE(student_id, course_id)
      )
    `);

    // ── Fee records ───────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS fee_records (
        id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        student_id    VARCHAR(20) REFERENCES students(id) ON DELETE CASCADE,
        course_id     UUID REFERENCES courses(id) ON DELETE SET NULL,
        amount_due    DECIMAL(10,2) NOT NULL,
        amount_paid   DECIMAL(10,2) DEFAULT 0,
        due_date      DATE NOT NULL,
        paid_date     DATE,
        status        VARCHAR(10) DEFAULT 'pending'
                        CHECK (status IN ('pending','paid','overdue','partial')),
        remarks       TEXT,
        collected_by  UUID REFERENCES users(id) ON DELETE SET NULL,
        created_at    TIMESTAMPTZ DEFAULT NOW(),
        updated_at    TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    // ── Attendance ────────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS attendance (
        id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        student_id      VARCHAR(20) REFERENCES students(id) ON DELETE CASCADE,
        date            DATE NOT NULL,
        time_in         TIME,
        time_out        TIME,
        duration_mins   INT,
        status          VARCHAR(10) DEFAULT 'absent'
                          CHECK (status IN ('present','absent','late','holiday')),
        checkin_mode    VARCHAR(15) DEFAULT 'face_auto',
        checkout_mode   VARCHAR(15) DEFAULT 'not_recorded',
        confidence_in   DECIMAL(4,2),
        confidence_out  DECIMAL(4,2),
        remarks         TEXT,
        marked_by       UUID REFERENCES users(id) ON DELETE SET NULL,
        created_at      TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE(student_id, date)
      )
    `);

    // ── Messages ──────────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS messages (
        id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        sender_id   UUID REFERENCES users(id) ON DELETE SET NULL,
        receiver_id UUID REFERENCES users(id) ON DELETE CASCADE,
        group_type  VARCHAR(30),
        subject     VARCHAR(200),
        body        TEXT NOT NULL,
        type        VARCHAR(20) DEFAULT 'message'
                      CHECK (type IN ('message','announcement','alert','homework','fee_reminder')),
        read_at     TIMESTAMPTZ,
        created_at  TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    // ── Notifications ─────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS notifications (
        id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id     UUID REFERENCES users(id) ON DELETE CASCADE,
        title       VARCHAR(200) NOT NULL,
        body        TEXT NOT NULL,
        type        VARCHAR(30) DEFAULT 'info',
        data_json   JSONB,
        is_read     BOOLEAN DEFAULT FALSE,
        created_at  TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    // ── Settings ──────────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS settings (
        key        VARCHAR(50) PRIMARY KEY,
        value      TEXT NOT NULL,
        updated_at TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    await client.query(`
      INSERT INTO settings (key, value) VALUES
        ('kiosk_api_key',    gen_random_uuid()::text),
        ('face_threshold',   '0.75'),
        ('auto_mark_absent', 'true'),
        ('app_version',      '1.0.0')
      ON CONFLICT (key) DO NOTHING
    `);

    // ── Indexes ───────────────────────────────────────────────────────────
    await client.query(`CREATE INDEX IF NOT EXISTS idx_att_date     ON attendance(date)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_att_student  ON attendance(student_id)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_sc_student   ON student_courses(student_id)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_sc_course    ON student_courses(course_id)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_fee_student  ON fee_records(student_id)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_fee_status   ON fee_records(status)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_fee_due      ON fee_records(due_date)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_notif_user   ON notifications(user_id, is_read)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_msg_receiver ON messages(receiver_id)`);

    await client.query('COMMIT');
    console.log(`[Migration] Schema "${slug}" created successfully`);
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    try { await client.query('SET search_path TO public'); } catch (_) {}
    client.release();
  }

  // Seed admin user outside transaction
  const userId = uuidv4();
  const hash   = await bcrypt.hash(admin.password, 12);
  const adminClient = await sharedPool.connect();
  try {
    await adminClient.query(`SET search_path TO "${slug}", public`);
    await adminClient.query(
      `INSERT INTO users (id, role, name, email, phone, password_hash)
       VALUES ($1, 'admin', $2, $3, $4, $5)
       ON CONFLICT (email) DO NOTHING`,
      [userId, admin.name, admin.email, admin.phone, hash]
    );
  } finally {
    try { await adminClient.query('SET search_path TO public'); } catch (_) {}
    adminClient.release();
  }

  return { userId };
}
