import { Request, Response, NextFunction } from 'express';
import bcrypt from 'bcrypt';
import { sharedPool, academyQuery, academyQueryOne, academyExec } from '../db/poolManager';
import { AppError } from '../middleware/errorHandler';
import { cacheDelete } from '../utils/insightface';

// ── Internal: purge a deleted academy's faces from the Redis cache ────────────

/**
 * Collect the student IDs of an academy that have a face cached, so they can be
 * removed from Redis AFTER the schema is dropped. Must run BEFORE the drop while
 * the schema still exists. Returns [] on any error (non-fatal).
 *
 * Why capture-then-delete (not reconcile-against-survivors): student IDs are
 * generated PER ACADEMY (e.g. ACF-2026-00001) and the Redis cache key is just
 * `face_emb:<id>` with no schema scope, so the same id can exist in two
 * academies. Reconciling against surviving IDs would wrongly KEEP a deleted
 * academy's face when another academy happens to share the id. Deleting the
 * captured ids directly removes exactly this academy's faces.
 */
async function collectAcademyFaceIds(slug: string): Promise<string[]> {
  try {
    const rows = await academyQuery<{ id: string }>(
      slug, `SELECT id FROM students WHERE face_embedding IS NOT NULL`
    );
    return rows.map(r => r.id);
  } catch {
    return [];
  }
}

/**
 * Delete the given student IDs from the InsightFace Redis cache. Non-fatal:
 * a cache hiccup must never fail the academy delete, which has already
 * succeeded in PostgreSQL (the hourly reconcile self-heals any leftovers).
 */
async function purgeFaceIdsFromCache(ids: string[]): Promise<void> {
  if (ids.length === 0) return;
  let removed = 0;
  for (const id of ids) {
    try { await cacheDelete(id); removed++; } catch { /* skip — self-heals hourly */ }
  }
  if (removed > 0) {
    console.log(`🧹 Academy delete: removed ${removed}/${ids.length} face(s) from Redis`);
  }
}

// ── Internal: audit log ───────────────────────────────────────────────────────

async function auditLog(
  adminId: string, action: string, targetSlug: string, details: string
): Promise<void> {
  try {
    await sharedPool.query(
      `INSERT INTO super_admin_audit_log (admin_id, action, target_slug, details)
       VALUES ($1, $2, $3, $4)`,
      [adminId, action, targetSlug, details]
    );
  } catch { /* non-fatal — never let logging break an action */ }
}

// ── GET /api/super-admin/academies ────────────────────────────────────────────

export async function listAcademies(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { search = '', status, sort = 'created_at' } =
      req.query as Record<string, string>;

    const conditions: string[] = [];
    const params: unknown[] = [];
    let p = 1;

    if (search.trim()) {
      conditions.push(`(LOWER(name) LIKE $${p} OR LOWER(slug) LIKE $${p})`);
      params.push(`%${search.trim().toLowerCase()}%`);
      p++;
    }
    if (status && ['active', 'inactive'].includes(status)) {
      conditions.push(`status = $${p++}`);
      params.push(status);
    }

    const where    = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
    const sortCol  = sort === 'name' ? 'name' : 'created_at';
    const orderDir = sort === 'name' ? 'ASC' : 'DESC';

    const { rows } = await sharedPool.query(
      `SELECT * FROM academies ${where} ORDER BY ${sortCol} ${orderDir}`,
      params
    );

    // Per-academy student + course counts (safe fallback on schema errors)
    const withStats = await Promise.all(rows.map(async (a) => {
      try {
        const [students, courses] = await Promise.all([
          academyQueryOne<{ count: string }>(
            a.slug, `SELECT COUNT(*) as count FROM students WHERE status != 'deleted'`
          ),
          academyQueryOne<{ count: string }>(
            a.slug, `SELECT COUNT(*) as count FROM courses WHERE is_active = TRUE`
          ),
        ]);
        return {
          ...a,
          student_count: parseInt(students?.count ?? '0') || 0,
          course_count:  parseInt(courses?.count  ?? '0') || 0,
        };
      } catch {
        return { ...a, student_count: 0, course_count: 0 };
      }
    }));

    res.json({ success: true, data: withStats });
  } catch (err) { next(err); }
}

// ── GET /api/super-admin/academies/:slug/stats ────────────────────────────────

export async function getAcademyStats(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { rows } = await sharedPool.query(
      `SELECT * FROM academies WHERE slug = $1`, [slug]
    );
    if (!rows.length) return next(new AppError('Academy not found', 404));
    const academy = rows[0];

    const [total, active, deleted, courses, acYears, attendance, fees] =
      await Promise.all([
        academyQueryOne<{ count: string }>(slug, `SELECT COUNT(*) as count FROM students`),
        academyQueryOne<{ count: string }>(slug, `SELECT COUNT(*) as count FROM students WHERE status = 'active'`),
        academyQueryOne<{ count: string }>(slug, `SELECT COUNT(*) as count FROM students WHERE status = 'deleted'`),
        academyQueryOne<{ count: string }>(slug, `SELECT COUNT(*) as count FROM courses WHERE is_active = TRUE`),
        academyQueryOne<{ count: string }>(slug, `SELECT COUNT(*) as count FROM academic_years`),
        academyQueryOne<{ count: string }>(slug, `SELECT COUNT(*) as count FROM attendance`),
        academyQueryOne<{ total: string }>(slug,
          `SELECT COALESCE(SUM(amount_paid), 0) as total FROM fee_records`),
      ]);

    // Admin login status — resilient: falls back to no lock fields if reconcile
    // hasn't added locked_at / locked_by columns yet (PostgreSQL error 42703)
    let adminLoginStatus: Record<string, unknown> | null = null;
    try {
      const u = await academyQueryOne<{
        id: string; name: string; email: string;
        failed_attempts: number; is_active: boolean;
        locked_at: string | null; locked_by: string | null; last_login: string | null;
      }>(slug, `SELECT id, name, email, failed_attempts, is_active,
                       locked_at, locked_by, last_login
                FROM users WHERE role = 'admin' LIMIT 1`);
      if (u) {
        adminLoginStatus = {
          id:              u.id,
          name:            u.name,
          email:           u.email,
          failed_attempts: u.failed_attempts,
          is_locked:       !u.is_active,
          locked_at:       u.locked_at,
          locked_by:       u.locked_by,
          last_login:      u.last_login,
        };
      }
    } catch {
      // locked_at / locked_by columns not yet present — reconcile pending
      try {
        const u = await academyQueryOne<{
          id: string; name: string; email: string;
          failed_attempts: number; is_active: boolean; last_login: string | null;
        }>(slug, `SELECT id, name, email, failed_attempts, is_active, last_login
                  FROM users WHERE role = 'admin' LIMIT 1`);
        if (u) {
          adminLoginStatus = {
            id:              u.id,
            name:            u.name,
            email:           u.email,
            failed_attempts: u.failed_attempts,
            is_locked:       !u.is_active,
            locked_at:       null,
            locked_by:       null,
            last_login:      u.last_login,
          };
        }
      } catch { /* non-fatal */ }
    }

    res.json({
      success: true,
      data: {
        academy,
        stats: {
          total_students:     parseInt(total?.count     ?? '0') || 0,
          active_students:    parseInt(active?.count    ?? '0') || 0,
          deleted_students:   parseInt(deleted?.count   ?? '0') || 0,
          courses:            parseInt(courses?.count   ?? '0') || 0,
          academic_years:     parseInt(acYears?.count   ?? '0') || 0,
          attendance_records: parseInt(attendance?.count ?? '0') || 0,
          fee_collected:      parseFloat(fees?.total    ?? '0') || 0,
        },
        admin_login_status: adminLoginStatus,
      },
    });
  } catch (err) { next(err); }
}

// ── GET /api/super-admin/academies/:slug/students ─────────────────────────────

export async function getAcademyStudents(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const {
      search = '', status = 'active', page = '1', limit = '50',
    } = req.query as Record<string, string>;

    const { rows: ac } = await sharedPool.query(
      `SELECT id FROM academies WHERE slug = $1`, [slug]
    );
    if (!ac.length) return next(new AppError('Academy not found', 404));

    const offset = (parseInt(page) - 1) * parseInt(limit);
    const searchParam = search.trim() ? `%${search.trim()}%` : '';

    const students = await academyQuery(slug,
      `SELECT s.id, s.first_name, s.last_name, s.mobile, s.email,
              s.parent_name, s.parent_mobile, s.status,
              TO_CHAR(s.created_at, 'YYYY-MM-DD') AS registration_date,
              COALESCE(
                string_agg(DISTINCT c.name, ', ' ORDER BY c.name), ''
              ) AS courses,
              COALESCE(MAX(ay.academic_year_name), '') AS academic_year
       FROM students s
       LEFT JOIN student_courses sc ON sc.student_id = s.id AND sc.status = 'active'
       LEFT JOIN courses c          ON c.id = sc.course_id
       LEFT JOIN academic_years ay  ON ay.id = c.academic_year_id
       WHERE (s.status = $1 OR $1 = 'all')
         AND ($2 = '' OR s.first_name ILIKE $2 OR s.last_name ILIKE $2
              OR s.id ILIKE $2 OR s.mobile ILIKE $2)
       GROUP BY s.id
       ORDER BY s.created_at DESC
       LIMIT $3 OFFSET $4`,
      [status, searchParam, parseInt(limit), offset]
    );

    const total = await academyQueryOne<{ count: string }>(slug,
      `SELECT COUNT(*) as count FROM students
       WHERE (status = $1 OR $1 = 'all')
         AND ($2 = '' OR first_name ILIKE $2 OR last_name ILIKE $2
              OR id ILIKE $2 OR mobile ILIKE $2)`,
      [status, searchParam]
    );

    res.json({
      success: true,
      data: {
        students,
        total: parseInt(total?.count ?? '0') || 0,
        page:  parseInt(page),
        limit: parseInt(limit),
      },
    });
  } catch (err) { next(err); }
}

// ── GET /api/super-admin/academies/:slug/export ───────────────────────────────

export async function exportAcademyStudents(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { rows: ac } = await sharedPool.query(
      `SELECT name FROM academies WHERE slug = $1`, [slug]
    );
    if (!ac.length) return next(new AppError('Academy not found', 404));

    const students = await academyQuery(slug,
      `SELECT s.id, s.first_name, s.last_name, s.mobile, s.email,
              s.parent_name, s.parent_mobile, s.status,
              TO_CHAR(s.created_at, 'YYYY-MM-DD') AS registration_date,
              COALESCE(
                string_agg(DISTINCT c.name, ', ' ORDER BY c.name), ''
              ) AS courses,
              COALESCE(MAX(ay.academic_year_name), '') AS academic_year
       FROM students s
       LEFT JOIN student_courses sc ON sc.student_id = s.id AND sc.status = 'active'
       LEFT JOIN courses c          ON c.id = sc.course_id
       LEFT JOIN academic_years ay  ON ay.id = c.academic_year_id
       GROUP BY s.id
       ORDER BY s.created_at DESC`
    );

    await auditLog(
      req.admin!.id, 'EXPORT_STUDENTS', slug,
      `Exported ${students.length} students from ${ac[0].name}`
    );

    res.json({
      success: true,
      data: { academy_name: ac[0].name as string, students },
    });
  } catch (err) { next(err); }
}

// ── PATCH /api/super-admin/academies/:slug/deactivate ────────────────────────

export async function deactivateAcademy(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { rows } = await sharedPool.query(
      `UPDATE academies SET status = 'inactive'
       WHERE slug = $1 AND status = 'active'
       RETURNING id, name`,
      [slug]
    );
    if (!rows.length) return next(new AppError('Academy not found or already inactive', 404));
    await auditLog(req.admin!.id, 'DEACTIVATE_ACADEMY', slug, `Deactivated: ${rows[0].name}`);
    res.json({ success: true, message: 'Academy deactivated' });
  } catch (err) { next(err); }
}

// ── PATCH /api/super-admin/academies/:slug/activate ──────────────────────────

export async function activateAcademy(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { rows } = await sharedPool.query(
      `UPDATE academies SET status = 'active'
       WHERE slug = $1 AND status = 'inactive'
       RETURNING id, name`,
      [slug]
    );
    if (!rows.length) return next(new AppError('Academy not found or already active', 404));
    await auditLog(req.admin!.id, 'ACTIVATE_ACADEMY', slug, `Activated: ${rows[0].name}`);
    res.json({ success: true, message: 'Academy activated' });
  } catch (err) { next(err); }
}

// ── DELETE /api/super-admin/academies/:slug ───────────────────────────────────

export async function deleteAcademy(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { password, academy_name } =
      req.body as { password: string; academy_name: string };

    if (!password?.trim() || !academy_name?.trim()) {
      return next(new AppError('Password and academy name confirmation are required', 400));
    }

    // Verify super admin password
    const adminRow = await sharedPool.query(
      `SELECT password_hash FROM admins WHERE id = $1`, [req.admin!.id]
    );
    if (!adminRow.rows.length) return next(new AppError('Admin not found', 404));
    const ok = await bcrypt.compare(password, adminRow.rows[0].password_hash);
    if (!ok) return next(new AppError('Incorrect password', 401));

    // Fetch and verify academy name match
    const { rows: ac } = await sharedPool.query(
      `SELECT id, name FROM academies WHERE slug = $1`, [slug]
    );
    if (!ac.length) return next(new AppError('Academy not found', 404));
    if (ac[0].name.trim().toLowerCase() !== academy_name.trim().toLowerCase()) {
      return next(new AppError('Academy name does not match', 400));
    }

    // Slug safety check (defence-in-depth before DROP SCHEMA)
    if (!/^[a-z0-9_]{1,63}$/.test(slug)) {
      return next(new AppError('Invalid academy slug format', 400));
    }

    // Capture this academy's cached face IDs BEFORE dropping the schema — once
    // it's gone we can no longer look them up.
    const faceIds = await collectAcademyFaceIds(slug);

    await sharedPool.query(`DROP SCHEMA IF EXISTS "${slug}" CASCADE`);
    await sharedPool.query(`DELETE FROM academies WHERE slug = $1`, [slug]);

    // Remove this academy's faces from the Redis cache so they can no longer
    // surface in scans. Runs AFTER the DB delete and is non-fatal.
    await purgeFaceIdsFromCache(faceIds);

    await auditLog(
      req.admin!.id, 'DELETE_ACADEMY', slug,
      `Permanently deleted: ${ac[0].name}`
    );

    res.json({ success: true, message: `Academy "${ac[0].name}" permanently deleted` });
  } catch (err) { next(err); }
}

// ── GET /api/super-admin/academies/:slug/login-status ─────────────────────────

export async function getAcademyLoginStatus(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { rows: ac } = await sharedPool.query(
      `SELECT id FROM academies WHERE slug = $1`, [slug]
    );
    if (!ac.length) return next(new AppError('Academy not found', 404));

    const user = await academyQueryOne<{
      id: string; name: string; email: string;
      failed_attempts: number; is_active: boolean;
      locked_at: string | null; locked_by: string | null; last_login: string | null;
    }>(
      slug,
      `SELECT id, name, email, failed_attempts, is_active, locked_at, locked_by, last_login
       FROM users WHERE role = 'admin' LIMIT 1`
    );

    if (!user) return next(new AppError('No admin user found for this academy', 404));

    res.json({
      success: true,
      data: {
        id:              user.id,
        name:            user.name,
        email:           user.email,
        failed_attempts: user.failed_attempts,
        is_locked:       !user.is_active,
        locked_at:       user.locked_at,
        locked_by:       user.locked_by,
        last_login:      user.last_login,
      },
    });
  } catch (err) { next(err); }
}

// ── PATCH /api/super-admin/academies/:slug/unlock-user ────────────────────────

export async function unlockAcademyUser(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { rows: ac } = await sharedPool.query(
      `SELECT name FROM academies WHERE slug = $1`, [slug]
    );
    if (!ac.length) return next(new AppError('Academy not found', 404));

    await academyExec(
      slug,
      `UPDATE users
       SET is_active=TRUE, failed_attempts=0, locked_at=NULL, locked_by=NULL, updated_at=NOW()
       WHERE role='admin'`
    );

    await auditLog(
      req.admin!.id, 'UNLOCK_ACADEMY_USER', slug,
      `Unlocked admin account for ${ac[0].name as string}`
    );

    res.json({ success: true, message: 'Account unlocked successfully' });
  } catch (err) { next(err); }
}

// ── PATCH /api/super-admin/academies/:slug/reset-attempts ─────────────────────

export async function resetLoginAttempts(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { rows: ac } = await sharedPool.query(
      `SELECT name FROM academies WHERE slug = $1`, [slug]
    );
    if (!ac.length) return next(new AppError('Academy not found', 404));

    await academyExec(
      slug,
      `UPDATE users SET failed_attempts=0, updated_at=NOW() WHERE role='admin'`
    );

    await auditLog(
      req.admin!.id, 'RESET_LOGIN_ATTEMPTS', slug,
      `Reset failed login attempts for admin of ${ac[0].name as string}`
    );

    res.json({ success: true, message: 'Login attempts reset successfully' });
  } catch (err) { next(err); }
}

// ── PATCH /api/super-admin/academies/:slug/block-user ────────────────────────

export async function blockAcademyUser(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { rows: ac } = await sharedPool.query(
      `SELECT name FROM academies WHERE slug = $1`, [slug]
    );
    if (!ac.length) return next(new AppError('Academy not found', 404));

    await academyExec(
      slug,
      `UPDATE users
       SET is_active=FALSE, locked_at=NOW(), locked_by=$1, updated_at=NOW()
       WHERE role='admin'`,
      [req.admin!.email]
    );

    await auditLog(
      req.admin!.id, 'BLOCK_ACADEMY_USER', slug,
      `Manually blocked admin account for ${ac[0].name as string}`
    );

    res.json({ success: true, message: 'Account blocked successfully' });
  } catch (err) { next(err); }
}

// ── GET /api/super-admin/academies/:slug/face-threshold ───────────────────────

/**
 * Read this academy's face-match threshold (the scan strictness used by
 * attendanceController.scanAcademy). Stored per-academy in "<slug>".settings
 * under key 'face_threshold'. Falls back to 0.60 if the row is missing.
 */
export async function getFaceThreshold(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { rows: ac } = await sharedPool.query(
      `SELECT id FROM academies WHERE slug = $1`, [slug]
    );
    if (!ac.length) return next(new AppError('Academy not found', 404));

    const row = await academyQueryOne<{ value: string }>(
      slug, `SELECT value FROM settings WHERE key = 'face_threshold'`
    );
    const parsed = parseFloat(row?.value ?? '0.60');
    const value  = Number.isFinite(parsed) ? parsed : 0.60;

    res.json({ success: true, data: { face_threshold: value } });
  } catch (err) { next(err); }
}

// ── PUT /api/super-admin/academies/:slug/face-threshold ───────────────────────

/**
 * Update this academy's face-match threshold. Accepts a number in [0.50, 0.90]
 * (the usable ArcFace range — below 0.50 invites false matches, above 0.90
 * rejects legitimate ones). The backend scan cache picks the new value up
 * within its 5-minute TTL (see scanCache.getThreshold).
 */
export async function setFaceThreshold(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { slug } = req.params;
    const { value } = req.body as { value?: number | string };

    const num = typeof value === 'string' ? parseFloat(value) : value;
    if (typeof num !== 'number' || !Number.isFinite(num) || num < 0.50 || num > 0.90) {
      return next(new AppError('value must be a number between 0.50 and 0.90', 400));
    }
    const rounded = Math.round(num * 100) / 100; // store at 2-decimal precision

    const { rows: ac } = await sharedPool.query(
      `SELECT name FROM academies WHERE slug = $1`, [slug]
    );
    if (!ac.length) return next(new AppError('Academy not found', 404));

    await academyExec(
      slug,
      `INSERT INTO settings (key, value, updated_at)
       VALUES ('face_threshold', $1, NOW())
       ON CONFLICT (key) DO UPDATE SET value = $1, updated_at = NOW()`,
      [String(rounded)]
    );

    await auditLog(
      req.admin!.id, 'SET_FACE_THRESHOLD', slug,
      `Set face_threshold=${rounded} for ${ac[0].name as string}`
    );

    res.json({
      success: true,
      data: { face_threshold: rounded },
      message: `Face threshold set to ${rounded}`,
    });
  } catch (err) { next(err); }
}
