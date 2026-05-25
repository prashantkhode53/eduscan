import { pool } from './pool';
import bcrypt from 'bcrypt';

export async function runMigrations(): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    await client.query(`CREATE EXTENSION IF NOT EXISTS "pgcrypto"`);

    await client.query(`
      CREATE TABLE IF NOT EXISTS admins (
        id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        username        VARCHAR(50) UNIQUE NOT NULL,
        password_hash   TEXT NOT NULL,
        email           VARCHAR(100) UNIQUE NOT NULL,
        full_name       VARCHAR(100),
        role            VARCHAR(20) DEFAULT 'admin',
        is_locked       BOOLEAN DEFAULT FALSE,
        failed_attempts INT DEFAULT 0,
        last_login      TIMESTAMPTZ,
        otp_code        VARCHAR(6),
        otp_expires_at  TIMESTAMPTZ,
        created_at      TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    await client.query(`
      CREATE TABLE IF NOT EXISTS students (
        id                 VARCHAR(20) PRIMARY KEY,
        first_name         VARCHAR(50) NOT NULL,
        middle_name        VARCHAR(50),
        last_name          VARCHAR(50) NOT NULL,
        dob                DATE NOT NULL,
        gender             VARCHAR(10) NOT NULL,
        blood_group        VARCHAR(5),
        nationality        VARCHAR(50),
        govt_id            VARCHAR(30),
        institution        VARCHAR(100) NOT NULL,
        academic_year      VARCHAR(10) NOT NULL,
        class_grade        VARCHAR(10) NOT NULL,
        division           VARCHAR(5) NOT NULL,
        roll_no            INT,
        stream             VARCHAR(50),
        admission_date     DATE NOT NULL,
        parent_name        VARCHAR(100) NOT NULL,
        parent_relation    VARCHAR(20),
        mobile             VARCHAR(15) NOT NULL,
        email              VARCHAR(100),
        address            TEXT,
        known_allergies    TEXT,
        medical_conditions TEXT,
        emergency_contact  VARCHAR(15),
        transport_route    VARCHAR(50),
        face_embedding     JSONB NOT NULL,
        face_quality       DECIMAL(4,2),
        status             VARCHAR(10) DEFAULT 'active',
        created_at         TIMESTAMPTZ DEFAULT NOW(),
        updated_at         TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    await client.query(`
      CREATE TABLE IF NOT EXISTS attendance (
        id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        student_id      VARCHAR(20) REFERENCES students(id) ON DELETE CASCADE,
        date            DATE NOT NULL,
        time_in         TIME,
        time_out        TIME,
        duration_mins   INT,
        status          VARCHAR(10) DEFAULT 'absent',
        checkin_mode    VARCHAR(15) DEFAULT 'face_auto',
        checkout_mode   VARCHAR(15) DEFAULT 'not_recorded',
        confidence_in   DECIMAL(4,2),
        confidence_out  DECIMAL(4,2),
        remarks         TEXT,
        marked_by       UUID REFERENCES admins(id),
        created_at      TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE(student_id, date)
      )
    `);

    await client.query(`
      CREATE TABLE IF NOT EXISTS settings (
        key        VARCHAR(50) PRIMARY KEY,
        value      TEXT NOT NULL,
        updated_at TIMESTAMPTZ DEFAULT NOW()
      )
    `);

    await client.query(`
      INSERT INTO settings (key, value) VALUES
        ('school_name',        'EduScan School'),
        ('school_logo_url',    ''),
        ('school_hours_start', '07:00'),
        ('school_hours_end',   '18:00'),
        ('face_threshold',     '0.35'),
        ('kiosk_api_key',      gen_random_uuid()::text),
        ('auto_mark_absent',   'true'),
        ('absent_alert_days',  '3'),
        ('app_version',        '1.0.0')
      ON CONFLICT (key) DO NOTHING
    `);

    await client.query(`CREATE INDEX IF NOT EXISTS idx_attendance_date       ON attendance(date)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_attendance_student    ON attendance(student_id)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_attendance_date_class ON attendance(date, student_id)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_students_class        ON students(class_grade, division)`);
    await client.query(`CREATE INDEX IF NOT EXISTS idx_students_status       ON students(status)`);

    // Lower face threshold from old default 0.6 → 0.35 on existing deployments
    await client.query(`
      UPDATE settings SET value = '0.35', updated_at = NOW()
      WHERE key = 'face_threshold' AND value = '0.6'
    `);

    await client.query('COMMIT');
    console.log('✅ All migrations completed successfully');
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('❌ Migration failed:', err);
    throw err;
  } finally {
    client.release();
  }

  // Seed default admin outside the transaction so it is always attempted
  const passwordHash = await bcrypt.hash('Admin@123', 10);
  await pool.query(`
    INSERT INTO admins (username, password_hash, email, full_name, role)
    VALUES ('admin', $1, 'admin@eduscan.com', 'Admin', 'admin')
    ON CONFLICT (username) DO NOTHING
  `, [passwordHash]);
  console.log('✅ Default admin seeded');
}
