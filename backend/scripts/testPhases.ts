/**
 * EduScan Academy — Phase 1-4 Integration Test
 *
 * Run:  npx ts-node scripts/testPhases.ts
 *
 * Tests all academy endpoints against the live backend.
 * Student registration (which needs InsightFace) is validated for correct
 * error responses; a mock student is seeded directly via DB so fee tests
 * have real data to work with.
 */

import dotenv from 'dotenv';
import path from 'path';
dotenv.config({ path: path.join(__dirname, '../.env') });

import { Pool } from 'pg';

const BASE_URL = process.env.TEST_BASE_URL ?? 'https://eduscan-j4cg.onrender.com';
const RUN_ID   = Date.now().toString(36);

// Mutable test state
let token       = '';
let academySlug = '';
let courseId1   = '';
let courseId2   = '';
let studentId   = '';
let feeRecordId = '';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: { rejectUnauthorized: false },
});

// ── Terminal colours ──────────────────────────────────────────────────────────
const C = {
  green:  '\x1b[32m',
  red:    '\x1b[31m',
  yellow: '\x1b[33m',
  cyan:   '\x1b[36m',
  bold:   '\x1b[1m',
  reset:  '\x1b[0m',
};

let passed = 0;
let failed = 0;

function log(label: string, ok: boolean, detail?: string) {
  const icon = ok ? `${C.green}✓${C.reset}` : `${C.red}✗${C.reset}`;
  const det  = detail ? `  ${C.yellow}(${detail})${C.reset}` : '';
  console.log(`  ${icon} ${label}${det}`);
  if (ok) passed++; else failed++;
}

// ── HTTP helper ───────────────────────────────────────────────────────────────

async function api(
  method: string,
  urlPath: string,
  body?: object
): Promise<{ status: number; data: any }> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;

  const res = await fetch(`${BASE_URL}${urlPath}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });

  let data: any = {};
  try { data = await res.json(); } catch (_) {}
  return { status: res.status, data };
}

// ── Phase 1 — Academy Registration ───────────────────────────────────────────

async function phase1() {
  console.log(`\n${C.bold}${C.cyan}Phase 1 — Academy Registration${C.reset}`);

  const email = `test_${RUN_ID}@eduscan.test`;

  const r = await api('POST', '/api/academy/register', {
    academy_name: `Test Academy ${RUN_ID}`,
    admin_name:   'Test Admin',
    email,
    phone:        '9876543210',
    password:     'Test@1234',
    address:      '123 Test Street, Pune',
  });
  log('Register new academy → 201',          r.status === 201,        `status ${r.status}`);
  log('Response includes JWT token',         !!r.data?.data?.token);
  log('Response includes academy slug',      !!r.data?.data?.academy?.slug);

  if (r.data?.data?.token) {
    token       = r.data.data.token;
    academySlug = r.data.data.academy.slug;
  }

  const dup = await api('POST', '/api/academy/register', {
    academy_name: 'Duplicate Academy',
    admin_name:   'Admin',
    email,  // same email
    phone:        '9999999999',
    password:     'Test@1234',
  });
  log('Duplicate email → 409',               dup.status === 409,      `status ${dup.status}`);

  const bad = await api('POST', '/api/academy/register', { academy_name: 'X' });
  log('Missing required fields → 400',       bad.status === 400,      `status ${bad.status}`);

  const shortPw = await api('POST', '/api/academy/register', {
    academy_name: 'Short PW Academy',
    admin_name:   'Admin',
    email:        `short_${RUN_ID}@test.com`,
    phone:        '9000000001',
    password:     'abc',
  });
  log('Short password → 400',                shortPw.status === 400,  `status ${shortPw.status}`);
}

// ── Phase 2 — Login & Profile ─────────────────────────────────────────────────

async function phase2() {
  console.log(`\n${C.bold}${C.cyan}Phase 2 — Login & Profile${C.reset}`);

  const email = `test_${RUN_ID}@eduscan.test`;

  const r = await api('POST', '/api/academy/login', {
    email,
    password:     'Test@1234',
    academy_slug: academySlug,
  });
  log('Login with valid credentials → 200',  r.status === 200,        `status ${r.status}`);
  log('Login returns fresh JWT',             !!r.data?.data?.token);
  log('Login returns academy metadata',      !!r.data?.data?.academy?.slug);
  if (r.data?.data?.token) token = r.data.data.token;

  const wrongPw = await api('POST', '/api/academy/login', {
    email, password: 'WrongPassword!1', academy_slug: academySlug,
  });
  log('Wrong password → 401',               wrongPw.status === 401,  `status ${wrongPw.status}`);

  const badSlug = await api('POST', '/api/academy/login', {
    email, password: 'Test@1234', academy_slug: 'does_not_exist_xyz',
  });
  log('Unknown academy slug → 404',          badSlug.status === 404,  `status ${badSlug.status}`);

  const profile = await api('GET', '/api/academy/profile');
  log('GET /profile → 200',                  profile.status === 200,  `status ${profile.status}`);
  log('Profile contains academy name',       !!profile.data?.data?.name);
  log('Profile contains slug',               !!profile.data?.data?.slug);

  const saved = token; token = '';
  const unauth = await api('GET', '/api/academy/profile');
  log('No token → 401',                      unauth.status === 401,   `status ${unauth.status}`);
  token = saved;
}

// ── Phase 3a — Courses ────────────────────────────────────────────────────────

async function phase3_courses() {
  console.log(`\n${C.bold}${C.cyan}Phase 3a — Courses${C.reset}`);

  const c1 = await api('POST', '/api/academy/courses', {
    name: 'Mathematics Advanced', subject: 'Math',
    duration_months: 12, default_fee: 2500, schedule: 'monthly',
  });
  log('Create Mathematics course → 201',     c1.status === 201,       `status ${c1.status}`);
  courseId1 = c1.data?.data?.id ?? '';

  const c2 = await api('POST', '/api/academy/courses', {
    name: 'Science', subject: 'Physics/Chemistry',
    duration_months: 12, default_fee: 3000, schedule: 'monthly',
  });
  log('Create Science course → 201',         c2.status === 201,       `status ${c2.status}`);
  courseId2 = c2.data?.data?.id ?? '';

  const c3 = await api('POST', '/api/academy/courses', {
    name: 'English', subject: 'Language',
    duration_months: 6, default_fee: 1500, schedule: 'monthly',
  });
  log('Create English course → 201',         c3.status === 201,       `status ${c3.status}`);
  const courseId3 = c3.data?.data?.id ?? '';

  const list = await api('GET', '/api/academy/courses');
  log('List courses → 200',                  list.status === 200,     `status ${list.status}`);
  log('3 courses in list',                   list.data?.data?.length === 3, `got ${list.data?.data?.length}`);

  const upd = await api('PUT', `/api/academy/courses/${courseId1}`, {
    name: 'Mathematics Advanced', default_fee: 2800,
  });
  log('Update course fee → 200',             upd.status === 200,      `status ${upd.status}`);
  log('Updated fee reflected in response',   Number(upd.data?.data?.default_fee) === 2800);

  const noName = await api('POST', '/api/academy/courses', { subject: 'History' });
  log('Create course without name → 400',    noName.status === 400,   `status ${noName.status}`);

  // Delete English (no enrollments yet)
  const del = await api('DELETE', `/api/academy/courses/${courseId3}`);
  log('Delete course (no enrollments) → 200', del.status === 200,     `status ${del.status}`);

  const list2 = await api('GET', '/api/academy/courses');
  log('Deleted course not in list',          list2.data?.data?.length === 2, `got ${list2.data?.data?.length}`);
}

// ── Phase 3b — Student API without InsightFace ────────────────────────────────

async function phase3_students_api() {
  console.log(`\n${C.bold}${C.cyan}Phase 3b — Student API (validation & error paths)${C.reset}`);

  const list = await api('GET', '/api/academy/students');
  log('List students → 200',                 list.status === 200,     `status ${list.status}`);
  log('Empty student list initially',        list.data?.data?.total === 0, `total ${list.data?.data?.total}`);

  const stats = await api('GET', '/api/academy/students/stats');
  log('GET /stats → 200',                    stats.status === 200,    `status ${stats.status}`);
  log('Stats show 0 students initially',     stats.data?.data?.total_students === 0);

  // Missing mobile
  const noMobile = await api('POST', '/api/academy/students', {
    first_name: 'John', last_name: 'Doe',
    courses: [{ course_id: courseId1, fee_amount: 2800 }],
    face_images: ['abc'],
  });
  log('Register without mobile → 400',       noMobile.status === 400, `status ${noMobile.status}`);

  // No courses
  const noCourses = await api('POST', '/api/academy/students', {
    first_name: 'John', last_name: 'Doe', mobile: '9876543210',
    courses: [], face_images: ['abc'],
  });
  log('Register without courses → 400',      noCourses.status === 400, `status ${noCourses.status}`);

  // Empty face_images
  const noFace = await api('POST', '/api/academy/students', {
    first_name: 'John', last_name: 'Doe', mobile: '9876543210',
    courses: [{ course_id: courseId1, fee_amount: 2800 }],
    face_images: [],
  });
  log('Register with empty face_images → 400', noFace.status === 400, `status ${noFace.status}`);

  // Fake image — InsightFace should reject gracefully
  const fakeImg = await api('POST', '/api/academy/students', {
    first_name: 'John', last_name: 'Doe', mobile: '9876543210',
    courses: [{ course_id: courseId1, fee_amount: 2800 }],
    face_images: ['data:image/jpeg;base64,/9j/4AAQSk='],
  });
  log(
    `Fake image → 422 or 500 (InsightFace unavailable expected)`,
    [422, 500].includes(fakeImg.status),
    `status ${fakeImg.status}`
  );
}

// ── Phase 3c — Seed mock student via DB ──────────────────────────────────────

async function phase3_seedStudent() {
  console.log(`\n${C.bold}${C.cyan}Phase 3c — Seed mock student directly via DB${C.reset}`);

  const client = await pool.connect();
  try {
    await client.query(`SET search_path TO "${academySlug}", public`);

    studentId = `ACF-${new Date().getFullYear()}-00001`;
    const mockEmbedding = JSON.stringify(
      Array.from({ length: 512 }, () => Math.random() - 0.5)
    );

    // Check if parent_mobile column exists (may not exist on older schema versions)
    const cols = await client.query<{ column_name: string }>(
      `SELECT column_name FROM information_schema.columns
       WHERE table_schema = $1 AND table_name = 'students'`,
      [academySlug]
    );
    const colNames = cols.rows.map(r => r.column_name);
    const hasParentMobile = colNames.includes('parent_mobile');

    if (hasParentMobile) {
      await client.query(
        `INSERT INTO students
           (id, first_name, last_name, dob, gender,
            mobile, email, parent_name, parent_mobile,
            address, face_embedding, face_quality, status)
         VALUES ($1,'Rahul','Sharma','2010-06-15','male',
                 '9876500001','rahul@test.com','Priya Sharma','9876500002',
                 '10 MG Road, Pune', $2, 0.92, 'active')
         ON CONFLICT (id) DO NOTHING`,
        [studentId, mockEmbedding]
      );
    } else {
      await client.query(
        `INSERT INTO students
           (id, first_name, last_name, dob, gender,
            mobile, email, parent_name,
            address, face_embedding, face_quality, status)
         VALUES ($1,'Rahul','Sharma','2010-06-15','male',
                 '9876500001','rahul@test.com','Priya Sharma',
                 '10 MG Road, Pune', $2, 0.92, 'active')
         ON CONFLICT (id) DO NOTHING`,
        [studentId, mockEmbedding]
      );
    }

    // Enrol in both active courses
    for (const [cid, fee] of [[courseId1, 2800], [courseId2, 3000]] as const) {
      await client.query(
        `INSERT INTO student_courses (student_id, course_id, fee_amount, start_date)
         VALUES ($1, $2, $3, CURRENT_DATE)
         ON CONFLICT (student_id, course_id) DO NOTHING`,
        [studentId, cid, fee]
      );
    }

    log(`Seeded student "Rahul Sharma" (${studentId})`, true);

    // Verify via REST
    const list = await api('GET', '/api/academy/students');
    log('Student visible via GET /students',  list.data?.data?.total >= 1, `total: ${list.data?.data?.total}`);

    const stats = await api('GET', '/api/academy/students/stats');
    log('Stats show 1 active student',        stats.data?.data?.total_students === 1);

    const detail = await api('GET', `/api/academy/students/${studentId}`);
    log('GET /students/:id → 200',            detail.status === 200,   `status ${detail.status}`);
    log('Student has 2 enrolled courses',     detail.data?.data?.courses?.length === 2, `courses: ${detail.data?.data?.courses?.length}`);

    // Unknown student
    const notFound = await api('GET', '/api/academy/students/NONEXISTENT-ID');
    log('Unknown student ID → 404',           notFound.status === 404, `status ${notFound.status}`);

  } catch (err) {
    log('DB seed', false, String(err));
  } finally {
    try { await client.query('SET search_path TO public'); } catch (_) {}
    client.release();
  }
}

// ── Phase 4 — Fees Management ────────────────────────────────────────────────

async function phase4_fees() {
  console.log(`\n${C.bold}${C.cyan}Phase 4 — Fees Management${C.reset}`);

  // Generate this month's fees for all active enrollments
  const gen1 = await api('POST', '/api/academy/fees/generate', {});
  log('Generate monthly fees → 200',         gen1.status === 200,     `status ${gen1.status}`);
  log('2 fee records generated (2 courses)', gen1.data?.data?.generated === 2, `generated: ${gen1.data?.data?.generated}`);

  // Idempotent second call
  const gen2 = await api('POST', '/api/academy/fees/generate', {});
  log('Second generate is idempotent → 0',   gen2.data?.data?.generated === 0, `generated: ${gen2.data?.data?.generated}`);

  // List all fees
  const list = await api('GET', '/api/academy/fees');
  log('List fees → 200',                     list.status === 200,     `status ${list.status}`);
  log('2 fee records in list',               list.data?.data?.records?.length === 2, `records: ${list.data?.data?.records?.length}`);
  log('Summary total_due > 0',               list.data?.data?.summary?.total_due > 0, `total_due: ${list.data?.data?.summary?.total_due}`);
  log('Summary count_pending = 2',           list.data?.data?.summary?.count_pending === 2);

  feeRecordId = list.data?.data?.records?.[0]?.id ?? '';

  // Filter by student
  const byStudent = await api('GET', `/api/academy/fees?student_id=${studentId}`);
  log('Filter fees by student_id → 2',       byStudent.data?.data?.records?.length === 2);

  // Get fees for student
  const studentFees = await api('GET', `/api/academy/fees/student/${studentId}`);
  log('GET /fees/student/:id → 200',         studentFees.status === 200, `status ${studentFees.status}`);
  log('Student has 2 fee records',           studentFees.data?.data?.records?.length === 2);
  log('Student total_due > 0',               studentFees.data?.data?.totals?.total_due > 0);

  // Collect partial payment
  const p1 = await api('POST', '/api/academy/fees/collect', {
    fee_record_id: feeRecordId,
    amount_paid:   1000,
    payment_mode:  'cash',
    remarks:       'First instalment',
  });
  log('Collect partial (₹1000) → 200',       p1.status === 200,       `status ${p1.status}`);
  log('Status becomes partial',              p1.data?.data?.status === 'partial', `status: ${p1.data?.data?.status}`);

  // Pay remaining
  const p2 = await api('POST', '/api/academy/fees/collect', {
    fee_record_id: feeRecordId,
    amount_paid:   9999,
    payment_mode:  'upi',
  });
  log('Overpay remaining → status paid',     p2.data?.data?.status === 'paid', `status: ${p2.data?.data?.status}`);

  // Double-collect on paid record
  const p3 = await api('POST', '/api/academy/fees/collect', {
    fee_record_id: feeRecordId,
    amount_paid:   100,
    payment_mode:  'cash',
  });
  log('Collect on paid record → 409',        p3.status === 409,       `status ${p3.status}`);

  // Invalid amount
  const badAmt = await api('POST', '/api/academy/fees/collect', {
    fee_record_id: feeRecordId,
    amount_paid:   0,
    payment_mode:  'cash',
  });
  log('Zero amount_paid → 400',              badAmt.status === 400,   `status ${badAmt.status}`);

  // Backdate second fee record so mark-overdue picks it up
  const dbClient = await pool.connect();
  try {
    await dbClient.query(`SET search_path TO "${academySlug}", public`);
    // Verify fee_records exists before touching it directly
    const tbls = await dbClient.query<{ table_name: string }>(
      `SELECT table_name FROM information_schema.tables
       WHERE table_schema = $1 AND table_name = 'fee_records'`,
      [academySlug]
    );
    if (tbls.rows.length === 0) {
      log('Backdated pending fee by 5 days for overdue test', false, 'fee_records not found — run migrations first');
    } else {
      await dbClient.query(
        `UPDATE fee_records
         SET due_date = CURRENT_DATE - INTERVAL '5 days'
         WHERE student_id = $1 AND status = 'pending'`,
        [studentId]
      );
      log('Backdated pending fee by 5 days for overdue test', true);
    }
  } finally {
    try { await dbClient.query('SET search_path TO public'); } catch (_) {}
    dbClient.release();
  }

  const markOD = await api('POST', '/api/academy/fees/mark-overdue', {});
  log('Mark overdue → 200',                  markOD.status === 200,   `status ${markOD.status}`);
  log('1 record marked overdue',             markOD.data?.data?.updated === 1, `updated: ${markOD.data?.data?.updated}`);

  // Filter by overdue
  const odList = await api('GET', '/api/academy/fees?status=overdue');
  log('Filter status=overdue returns 1',     odList.data?.data?.records?.length === 1, `count: ${odList.data?.data?.records?.length}`);

  // Filter by paid
  const paidList = await api('GET', '/api/academy/fees?status=paid');
  log('Filter status=paid returns 1',        paidList.data?.data?.records?.length === 1, `count: ${paidList.data?.data?.records?.length}`);
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  console.log(`${C.bold}\n╔════════════════════════════════════════════╗`);
  console.log(`║  EduScan Academy — Phase 1–4 Test Suite    ║`);
  console.log(`╚════════════════════════════════════════════╝${C.reset}`);
  console.log(`  Target : ${BASE_URL}`);
  console.log(`  Run ID : ${RUN_ID}`);

  // Wake up Render (it may be sleeping on free tier)
  process.stdout.write('\n  Waking up backend...');
  try {
    const health = await fetch(`${BASE_URL}/api/health`, { signal: AbortSignal.timeout(30_000) });
    const hData  = await health.json() as any;
    process.stdout.write(
      health.status === 200
        ? ` ${C.green}ready${C.reset} (db: ${hData.db})\n`
        : ` ${C.red}${health.status}${C.reset}\n`
    );
    if (health.status !== 200) { await pool.end(); process.exit(1); }
  } catch (err) {
    process.stdout.write(` ${C.red}unreachable${C.reset} — ${err}\n`);
    await pool.end(); process.exit(1);
  }

  await phase1();
  await phase2();
  await phase3_courses();
  await phase3_students_api();
  await phase3_seedStudent();
  await phase4_fees();

  const total = passed + failed;
  console.log(`\n${C.bold}════════════════════════════════════════════`);
  console.log(
    `  Results: ${C.green}${passed} passed${C.reset}  ` +
    `${failed > 0 ? C.red : ''}${failed} failed${failed > 0 ? C.reset : ''}  (${total} total)`
  );
  console.log(`════════════════════════════════════════════${C.reset}\n`);

  await pool.end();
  process.exit(failed > 0 ? 1 : 0);
}

main().catch(err => { console.error(err); process.exit(1); });
