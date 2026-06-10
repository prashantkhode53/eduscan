/**
 * Schema migrations for each academy.
 * Creates a dedicated PostgreSQL schema named after the academy slug,
 * then creates all tables within it.
 * Safe to call multiple times — uses IF NOT EXISTS throughout.
 */

import bcrypt from 'bcrypt';
import { v4 as uuidv4 } from 'uuid';
import { sharedPool, academyExec } from './poolManager';

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
    try {
      // academyExec pins the search_path per-transaction (PgBouncer-safe).
      await academyExec(slug, `
        ALTER TABLE IF EXISTS students
          ADD COLUMN IF NOT EXISTS dob                        DATE,
          ADD COLUMN IF NOT EXISTS gender                    VARCHAR(10),
          ADD COLUMN IF NOT EXISTS email                     VARCHAR(100),
          ADD COLUMN IF NOT EXISTS parent_name               VARCHAR(100),
          ADD COLUMN IF NOT EXISTS parent_mobile             VARCHAR(15),
          ADD COLUMN IF NOT EXISTS address                   TEXT,
          ADD COLUMN IF NOT EXISTS face_quality              DECIMAL(4,2),
          ADD COLUMN IF NOT EXISTS parent_fcm_token          TEXT,
          ADD COLUMN IF NOT EXISTS updated_at                TIMESTAMPTZ DEFAULT NOW(),
          ADD COLUMN IF NOT EXISTS fallback_password_hash    TEXT,
          ADD COLUMN IF NOT EXISTS fallback_password_enabled BOOLEAN NOT NULL DEFAULT FALSE
      `);
      // Idempotent: create qr_codes table for academies created before this feature.
      await academyExec(slug, `
        CREATE TABLE IF NOT EXISTS qr_codes (
          id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
          name        VARCHAR(100) NOT NULL,
          description TEXT,
          image_data  TEXT NOT NULL,
          is_active   BOOLEAN DEFAULT FALSE,
          created_at  TIMESTAMPTZ DEFAULT NOW(),
          updated_at  TIMESTAMPTZ DEFAULT NOW()
        )
      `);
      // Idempotent: create academic_years table + add FK column to courses.
      await academyExec(slug, `
        CREATE TABLE IF NOT EXISTS academic_years (
          id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
          academic_year_name  VARCHAR(20) NOT NULL,
          start_date          DATE NOT NULL,
          end_date            DATE NOT NULL,
          status              VARCHAR(10) DEFAULT 'active'
                                CHECK (status IN ('active','inactive')),
          is_current_year     BOOLEAN DEFAULT FALSE,
          created_at          TIMESTAMPTZ DEFAULT NOW(),
          updated_at          TIMESTAMPTZ DEFAULT NOW()
        )
      `);
      await academyExec(slug, `
        ALTER TABLE IF EXISTS courses
          ADD COLUMN IF NOT EXISTS academic_year_id UUID REFERENCES academic_years(id) ON DELETE SET NULL
      `);
      // subjects — one row per subject within a course (Physics, Chemistry, …)
      await academyExec(slug, `
        CREATE TABLE IF NOT EXISTS subjects (
          id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
          course_id   UUID REFERENCES courses(id) ON DELETE CASCADE,
          name        VARCHAR(100) NOT NULL,
          default_fee DECIMAL(10,2) NOT NULL DEFAULT 0,
          is_active   BOOLEAN DEFAULT TRUE,
          created_at  TIMESTAMPTZ DEFAULT NOW(),
          updated_at  TIMESTAMPTZ DEFAULT NOW()
        )
      `);
      // student_subjects — primary enrollment table; one row per student×subject
      await academyExec(slug, `
        CREATE TABLE IF NOT EXISTS student_subjects (
          id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
          student_id  VARCHAR(20) REFERENCES students(id) ON DELETE CASCADE,
          subject_id  UUID REFERENCES subjects(id) ON DELETE CASCADE,
          fee_amount  DECIMAL(10,2) NOT NULL,
          start_date  DATE NOT NULL DEFAULT CURRENT_DATE,
          end_date    DATE,
          status      VARCHAR(10) DEFAULT 'active'
                        CHECK (status IN ('active','completed','dropped')),
          created_at  TIMESTAMPTZ DEFAULT NOW(),
          UNIQUE(student_id, subject_id)
        )
      `);
      // fee_records: add subject_id for subject-level fee tracking
      await academyExec(slug, `
        ALTER TABLE IF EXISTS fee_records
          ADD COLUMN IF NOT EXISTS subject_id UUID REFERENCES subjects(id) ON DELETE SET NULL
      `);
      // students: add academic_year_id so edit restore works without re-selection
      await academyExec(slug, `
        ALTER TABLE IF EXISTS students
          ADD COLUMN IF NOT EXISTS academic_year_id UUID REFERENCES academic_years(id) ON DELETE SET NULL
      `);
      // Migration: seed one subject per course using the old string `subject` field as name
      await academyExec(slug, `
        INSERT INTO subjects (course_id, name, default_fee, is_active, created_at, updated_at)
        SELECT c.id,
               COALESCE(NULLIF(TRIM(c.subject), ''), c.name),
               c.default_fee,
               c.is_active,
               c.created_at,
               c.updated_at
        FROM courses c
        WHERE NOT EXISTS (SELECT 1 FROM subjects s WHERE s.course_id = c.id)
      `);
      // Migration: seed student_subjects from existing student_courses enrollments
      await academyExec(slug, `
        INSERT INTO student_subjects (student_id, subject_id, fee_amount, start_date, status, created_at)
        SELECT sc.student_id, sub.id, sc.fee_amount, sc.start_date, sc.status, sc.created_at
        FROM student_courses sc
        JOIN subjects sub ON sub.course_id = sc.course_id AND sub.is_active = TRUE
        ON CONFLICT (student_id, subject_id) DO NOTHING
      `);
      // Indexes for new tables
      await academyExec(slug, `
        CREATE INDEX IF NOT EXISTS idx_subj_course ON subjects(course_id);
        CREATE INDEX IF NOT EXISTS idx_ss_student  ON student_subjects(student_id);
        CREATE INDEX IF NOT EXISTS idx_ss_subject  ON student_subjects(subject_id);
        CREATE INDEX IF NOT EXISTS idx_fr_subject  ON fee_records(subject_id)
      `);
      // Unique partial index: prevents duplicate subject names (case-insensitive) per course
      await academyExec(slug, `
        CREATE UNIQUE INDEX IF NOT EXISTS idx_subj_course_name
        ON subjects(course_id, LOWER(name))
        WHERE is_active = TRUE
      `);
      // users: add lock-tracking columns introduced with the account-unlock feature
      await academyExec(slug, `
        ALTER TABLE IF EXISTS users
          ADD COLUMN IF NOT EXISTS locked_at TIMESTAMPTZ,
          ADD COLUMN IF NOT EXISTS locked_by TEXT
      `);
      // Receipt sequence + table for existing academies
      await academyExec(slug, `CREATE SEQUENCE IF NOT EXISTS fee_receipt_seq START 1 INCREMENT 1`);
      await academyExec(slug, `
        CREATE TABLE IF NOT EXISTS fee_receipts (
          id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
          receipt_number  VARCHAR(20) NOT NULL UNIQUE,
          fee_record_id   UUID REFERENCES fee_records(id) ON DELETE SET NULL,
          student_id      VARCHAR(20) REFERENCES students(id) ON DELETE CASCADE,
          amount_paid     DECIMAL(10,2) NOT NULL,
          payment_mode    VARCHAR(20),
          generated_by    UUID REFERENCES users(id) ON DELETE SET NULL,
          generated_at    TIMESTAMPTZ DEFAULT NOW(),
          fcm_sent        BOOLEAN DEFAULT FALSE
        )
      `);
      await academyExec(slug, `
        CREATE INDEX IF NOT EXISTS idx_receipts_student ON fee_receipts(student_id);
        CREATE INDEX IF NOT EXISTS idx_receipts_gendate ON fee_receipts(generated_at)
      `);
      // Multi-subject receipt support: receipt_id on fee_records + items table
      await academyExec(slug, `
        ALTER TABLE IF EXISTS fee_records
          ADD COLUMN IF NOT EXISTS receipt_id UUID REFERENCES fee_receipts(id) ON DELETE SET NULL
      `);
      await academyExec(slug, `
        UPDATE fee_records fr
        SET receipt_id = rcpt.id
        FROM fee_receipts rcpt
        WHERE rcpt.fee_record_id = fr.id
          AND fr.receipt_id IS NULL
      `);
      await academyExec(slug, `
        CREATE TABLE IF NOT EXISTS fee_receipt_items (
          id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
          receipt_id    UUID NOT NULL REFERENCES fee_receipts(id) ON DELETE CASCADE,
          fee_record_id UUID NOT NULL REFERENCES fee_records(id),
          subject_id    UUID,
          subject_name  TEXT,
          course_id     UUID,
          course_name   TEXT,
          amount_paid   NUMERIC(10,2) NOT NULL,
          created_at    TIMESTAMPTZ DEFAULT NOW()
        )
      `);
      await academyExec(slug, `
        CREATE INDEX IF NOT EXISTS idx_fri_receipt ON fee_receipt_items(receipt_id);
        CREATE INDEX IF NOT EXISTS idx_fri_record  ON fee_receipt_items(fee_record_id)
      `);
      // Per-course configurable due day (1-28 = that day of month; NULL = last day of month)
      await academyExec(slug, `
        ALTER TABLE IF EXISTS courses
          ADD COLUMN IF NOT EXISTS fee_due_day INT DEFAULT NULL
            CHECK (fee_due_day IS NULL OR (fee_due_day >= 1 AND fee_due_day <= 28))
      `);
      ok++;
    } catch (err) {
      console.error(`[Reconcile] schema "${slug}" failed:`, err);
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

    // SET LOCAL must live *inside* the transaction: under PgBouncer transaction
    // pooling a pre-BEGIN session SET can land on a different backend than the
    // CREATE TABLE statements, silently creating the academy's tables in
    // `public` and leaving the new academy permanently broken.
    await client.query('BEGIN');
    await client.query(`SET LOCAL search_path TO "${slug}", public`);

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
        locked_at       TIMESTAMPTZ,
        locked_by       TEXT,
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
        id               VARCHAR(20) PRIMARY KEY,
        user_id          UUID REFERENCES users(id) ON DELETE SET NULL,
        first_name       VARCHAR(50) NOT NULL,
        middle_name      VARCHAR(50),
        last_name        VARCHAR(50) NOT NULL,
        dob              DATE,
        gender           VARCHAR(10),
        blood_group      VARCHAR(5),
        mobile           VARCHAR(15) NOT NULL,
        email            VARCHAR(100),
        parent_name      VARCHAR(100),
        parent_mobile    VARCHAR(15),
        address          TEXT,
        face_embedding             JSONB,
        face_quality               DECIMAL(4,2),
        parent_fcm_token           TEXT,
        academic_year_id           UUID,
        fallback_password_hash     TEXT,
        fallback_password_enabled  BOOLEAN NOT NULL DEFAULT FALSE,
        status                     VARCHAR(10) DEFAULT 'active',
        created_at       TIMESTAMPTZ DEFAULT NOW(),
        updated_at       TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    // Idempotent column addition for academies created before parent-notification feature
    await client.query(`
      ALTER TABLE IF EXISTS students
        ADD COLUMN IF NOT EXISTS parent_fcm_token TEXT
    `);

    // ── Academic Years ────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS academic_years (
        id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        academic_year_name  VARCHAR(20) NOT NULL,
        start_date          DATE NOT NULL,
        end_date            DATE NOT NULL,
        status              VARCHAR(10) DEFAULT 'active'
                              CHECK (status IN ('active','inactive')),
        is_current_year     BOOLEAN DEFAULT FALSE,
        created_at          TIMESTAMPTZ DEFAULT NOW(),
        updated_at          TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    // Now that academic_years exists, wire the FK on students (students was
    // created first because it has no references to academic_years at table
    // creation time — the FK must be added afterward).
    await client.query(`
      ALTER TABLE students
        ADD CONSTRAINT fk_students_academic_year
        FOREIGN KEY (academic_year_id) REFERENCES academic_years(id) ON DELETE SET NULL
    `);

    // ── Courses ───────────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS courses (
        id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        academic_year_id UUID REFERENCES academic_years(id) ON DELETE SET NULL,
        name             VARCHAR(100) NOT NULL,
        description      TEXT,
        subject          VARCHAR(50),
        duration_months  INT,
        default_fee      DECIMAL(10,2) DEFAULT 0,
        schedule         VARCHAR(20) DEFAULT 'monthly'
                           CHECK (schedule IN ('monthly','quarterly','onetime')),
        is_active        BOOLEAN DEFAULT TRUE,
        created_at       TIMESTAMPTZ DEFAULT NOW(),
        updated_at       TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    // ── Subjects ──────────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS subjects (
        id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        course_id   UUID REFERENCES courses(id) ON DELETE CASCADE,
        name        VARCHAR(100) NOT NULL,
        default_fee DECIMAL(10,2) NOT NULL DEFAULT 0,
        is_active   BOOLEAN DEFAULT TRUE,
        created_at  TIMESTAMPTZ DEFAULT NOW(),
        updated_at  TIMESTAMPTZ DEFAULT NOW()
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

    // ── Student-Subject enrollment ────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS student_subjects (
        id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        student_id  VARCHAR(20) REFERENCES students(id) ON DELETE CASCADE,
        subject_id  UUID REFERENCES subjects(id) ON DELETE CASCADE,
        fee_amount  DECIMAL(10,2) NOT NULL,
        start_date  DATE NOT NULL DEFAULT CURRENT_DATE,
        end_date    DATE,
        status      VARCHAR(10) DEFAULT 'active'
                      CHECK (status IN ('active','completed','dropped')),
        created_at  TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE(student_id, subject_id)
      )
    `);

    // ── Fee records ───────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS fee_records (
        id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        student_id    VARCHAR(20) REFERENCES students(id) ON DELETE CASCADE,
        course_id     UUID REFERENCES courses(id) ON DELETE SET NULL,
        subject_id    UUID REFERENCES subjects(id) ON DELETE SET NULL,
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

    // ── Receipt sequence + table ──────────────────────────────────────────
    await client.query(`CREATE SEQUENCE IF NOT EXISTS fee_receipt_seq START 1 INCREMENT 1`);
    await client.query(`
      CREATE TABLE IF NOT EXISTS fee_receipts (
        id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        receipt_number  VARCHAR(20) NOT NULL UNIQUE,
        fee_record_id   UUID REFERENCES fee_records(id) ON DELETE SET NULL,
        student_id      VARCHAR(20) REFERENCES students(id) ON DELETE CASCADE,
        amount_paid     DECIMAL(10,2) NOT NULL,
        payment_mode    VARCHAR(20),
        generated_by    UUID REFERENCES users(id) ON DELETE SET NULL,
        generated_at    TIMESTAMPTZ DEFAULT NOW(),
        fcm_sent        BOOLEAN DEFAULT FALSE
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

    // ── QR Codes ─────────────────────────────────────────────────────────
    await client.query(`
      CREATE TABLE IF NOT EXISTS qr_codes (
        id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        name        VARCHAR(100) NOT NULL,
        description TEXT,
        image_data  TEXT NOT NULL,
        is_active   BOOLEAN DEFAULT FALSE,
        created_at  TIMESTAMPTZ DEFAULT NOW(),
        updated_at  TIMESTAMPTZ DEFAULT NOW()
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
    await client.query(`CREATE INDEX IF NOT EXISTS idx_subj_course  ON subjects(course_id)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_ss_student   ON student_subjects(student_id)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_ss_subject   ON student_subjects(subject_id)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_fr_subject      ON fee_records(subject_id)`);
    await client.query(`
      CREATE UNIQUE INDEX IF NOT EXISTS idx_subj_course_name
      ON subjects(course_id, LOWER(name))
      WHERE is_active = TRUE
    `);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_receipts_student ON fee_receipts(student_id)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_receipts_gendate ON fee_receipts(generated_at)`);

    // Multi-subject receipt support
    await client.query(`
      ALTER TABLE IF EXISTS fee_records
        ADD COLUMN IF NOT EXISTS receipt_id UUID REFERENCES fee_receipts(id) ON DELETE SET NULL
    `);
    await client.query(`
      CREATE TABLE IF NOT EXISTS fee_receipt_items (
        id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        receipt_id    UUID NOT NULL REFERENCES fee_receipts(id) ON DELETE CASCADE,
        fee_record_id UUID NOT NULL REFERENCES fee_records(id),
        subject_id    UUID,
        subject_name  TEXT,
        course_id     UUID,
        course_name   TEXT,
        amount_paid   NUMERIC(10,2) NOT NULL,
        created_at    TIMESTAMPTZ DEFAULT NOW()
      )
    `);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_fri_receipt ON fee_receipt_items(receipt_id)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_fri_record  ON fee_receipt_items(fee_record_id)`);

    // Per-course configurable due day (1-28 = that day of month; NULL = last day of month)
    await client.query(`
      ALTER TABLE IF EXISTS courses
        ADD COLUMN IF NOT EXISTS fee_due_day INT DEFAULT NULL
          CHECK (fee_due_day IS NULL OR (fee_due_day >= 1 AND fee_due_day <= 28))
    `);

    await client.query('COMMIT');
    console.log(`[Migration] Schema "${slug}" created successfully`);
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch (_) {}
    throw err;
  } finally {
    client.release();
  }

  // Seed admin user outside the schema-creation transaction.
  // academyExec pins the search_path per-transaction (PgBouncer-safe).
  const userId = uuidv4();
  const hash   = await bcrypt.hash(admin.password, 12);
  await academyExec(
    slug,
    `INSERT INTO users (id, role, name, email, phone, password_hash)
     VALUES ($1, 'admin', $2, $3, $4, $5)
     ON CONFLICT (email) DO NOTHING`,
    [userId, admin.name, admin.email, admin.phone, hash]
  );

  return { userId };
}
