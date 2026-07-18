import { Request, Response, NextFunction } from 'express';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { query, queryOne } from '../db/pool';
import { sharedPool, academyQuery, academyQueryOne, academyExec } from '../db/poolManager';
import { runAcademyMigrations } from '../db/academyMigrations';
import { sendOtpEmail } from '../utils/emailService';
import { AppError } from '../middleware/errorHandler';
import { AcademyUser } from '../types';

function slugify(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .substring(0, 60);
}

function jwtSecret(): string {
  const s = process.env.JWT_SECRET;
  if (!s) throw new AppError('JWT_SECRET not configured', 500);
  return s;
}

function issueToken(payload: AcademyUser): string {
  return jwt.sign(payload, jwtSecret(), {
    expiresIn: process.env.JWT_EXPIRES_IN ?? '365d',
  } as import('jsonwebtoken').SignOptions);
}

// ── POST /api/academy/register ────────────────────────────────────────────────

export async function registerAcademy(
  req: Request,
  res: Response,
  next: NextFunction
): Promise<void> {
  try {
    const { academy_name, admin_name, email, phone, password, address } =
      req.body as {
        academy_name: string; admin_name: string; email: string;
        phone: string; password: string; address?: string;
      };

    if (!academy_name || !admin_name || !email || !phone || !password) {
      return next(new AppError('academy_name, admin_name, email, phone, password are required', 400));
    }
    if (password.length < 8) {
      return next(new AppError('Password must be at least 8 characters', 400));
    }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return next(new AppError('Invalid email address', 400));
    }

    // Duplicate check
    const existing = await queryOne(
      `SELECT id FROM academies WHERE admin_email = $1`,
      [email.toLowerCase()]
    );
    if (existing) {
      return next(new AppError('An academy is already registered with this email', 409));
    }

    // Build unique slug (safe for PostgreSQL schema name)
    const baseSlug  = slugify(academy_name);
    const slugTaken = await queryOne(`SELECT id FROM academies WHERE slug = $1`, [baseSlug]);
    const finalSlug = slugTaken ? `${baseSlug}_${Date.now().toString(36)}` : baseSlug;

    // 1 — Create PostgreSQL schema + all tables + seed admin user
    console.log(`[Academy] Creating schema "${finalSlug}" for "${academy_name}"`);
    let userId: string;
    try {
      ({ userId } = await runAcademyMigrations(finalSlug, {
        name:     admin_name,
        email:    email.toLowerCase(),
        phone,
        password,
      }));
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error('[Academy] Schema migration failed:', msg);
      // Clean up partial schema so re-registration works
      try {
        await sharedPool.query(`DROP SCHEMA IF EXISTS "${finalSlug}" CASCADE`);
      } catch (_) {}
      return next(new AppError(`Academy setup failed: ${msg}`, 500));
    }

    // 2 — Register academy in the main registry table
    const academy = await queryOne<{ id: string; name: string; slug: string }>(
      `INSERT INTO academies (name, slug, admin_name, admin_email, phone, address)
       VALUES ($1,$2,$3,$4,$5,$6)
       RETURNING id, name, slug`,
      [academy_name, finalSlug, admin_name, email.toLowerCase(), phone, address ?? null]
    );
    if (!academy) throw new AppError('Failed to persist academy record', 500);

    // 3 — Issue JWT
    const token = issueToken({
      userId,
      academyId:   academy.id,
      academySlug: academy.slug,
      academyName: academy.name,
      role:        'admin',
      name:        admin_name,
      email:       email.toLowerCase(),
      type:        'academy',
    });

    console.log(`[Academy] Registered: ${academy.name} (slug=${finalSlug})`);

    res.status(201).json({
      success: true,
      data: {
        token,
        user:    { id: userId, name: admin_name, email: email.toLowerCase(), role: 'admin' },
        academy: { id: academy.id, name: academy.name, slug: academy.slug },
      },
      message: 'Academy registered successfully',
    });
  } catch (err) {
    next(err);
  }
}

// ── POST /api/academy/login ───────────────────────────────────────────────────

interface UserRow {
  id: string; role: string; name: string; email: string;
  password_hash: string; failed_attempts: number; is_active: boolean;
}

export async function loginAcademyUser(
  req: Request,
  res: Response,
  next: NextFunction
): Promise<void> {
  try {
    const { email, password, academy_slug } =
      req.body as { email: string; password: string; academy_slug: string };

    if (!email || !password || !academy_slug) {
      return next(new AppError('email, password, and academy_slug are required', 400));
    }

    // Resolve academy from main registry
    const academy = await queryOne<{ id: string; name: string; slug: string; status: string }>(
      `SELECT id, name, slug, status FROM academies WHERE slug = $1`,
      [academy_slug.toLowerCase().trim()]
    );
    if (!academy)        return next(new AppError('Academy not found. Check your academy code.', 404));
    if (academy.status !== 'active') {
      return next(new AppError('This academy account is inactive. Contact support.', 403));
    }

    // Query user from academy's schema (helper pins search_path per-transaction)
    const user = await academyQueryOne<UserRow>(
      academy.slug,
      `SELECT id, role, name, email, password_hash, failed_attempts, is_active
       FROM users WHERE email = $1`,
      [email.toLowerCase()]
    );

    if (!user)           return next(new AppError('Invalid credentials', 401));
    if (!user.is_active) return next(new AppError('Account inactive. Contact your academy admin.', 403));

    const match = await bcrypt.compare(password, user.password_hash);
    if (!match) {
      const attempts = user.failed_attempts + 1;
      const lock     = attempts >= 4;
      await academyExec(
        academy.slug,
        `UPDATE users SET
           failed_attempts = $1,
           is_active  = CASE WHEN $2 THEN FALSE ELSE is_active END,
           locked_at  = CASE WHEN $2 THEN NOW()  ELSE locked_at END,
           locked_by  = CASE WHEN $2 THEN 'system' ELSE locked_by END
         WHERE id = $3`,
        [attempts, lock, user.id]
      );
      if (lock) return next(new AppError('Account locked after 4 failed attempts. Contact your academy super admin.', 403));
      return next(new AppError(`Invalid credentials. ${4 - attempts} attempt(s) remaining.`, 401));
    }

    // Reset failed attempts and lock fields on successful login
    await academyExec(
      academy.slug,
      `UPDATE users SET failed_attempts=0, last_login=NOW(), locked_at=NULL, locked_by=NULL WHERE id=$1`,
      [user.id]
    );

    const token = issueToken({
      userId:      user.id,
      academyId:   academy.id,
      academySlug: academy.slug,
      academyName: academy.name,
      role:        user.role as AcademyUser['role'],
      name:        user.name,
      email:       user.email,
      type:        'academy',
    });

    res.json({
      success: true,
      data: {
        token,
        user:    { id: user.id, name: user.name, email: user.email, role: user.role },
        academy: { id: academy.id, name: academy.name, slug: academy.slug },
      },
      message: 'Login successful',
    });
  } catch (err) {
    next(err);
  }
}

// ── Password reset (OTP by email, admins only) ────────────────────────────────
//
// Academy users live in per-schema `users` tables, so every step must also carry
// the academy_slug to locate the right schema. Only role='admin' users may
// self-reset; teachers must ask their academy admin. Mirrors the super-admin
// flow in authController.ts.

/** Resolve an active academy from the shared registry, or null. */
async function findActiveAcademy(
  slug: string
): Promise<{ id: string; name: string; slug: string } | null> {
  const academy = await queryOne<{ id: string; name: string; slug: string; status: string }>(
    `SELECT id, name, slug, status FROM academies WHERE slug = $1`,
    [slug.toLowerCase().trim()]
  );
  if (!academy || academy.status !== 'active') return null;
  return { id: academy.id, name: academy.name, slug: academy.slug };
}

// ── POST /api/academy/forgot-password ─────────────────────────────────────────

export async function forgotPasswordAcademy(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academy_slug, email } = req.body as { academy_slug: string; email: string };
    if (!academy_slug || !email) {
      return next(new AppError('academy_slug and email are required', 400));
    }

    // Always respond success to prevent academy/email enumeration.
    const generic = { success: true, message: 'If that account exists, an OTP has been sent.' };

    const academy = await findActiveAcademy(academy_slug);
    if (!academy) { res.json(generic); return; }

    const user = await academyQueryOne<{ id: string; name: string; email: string }>(
      academy.slug,
      `SELECT id, name, email FROM users
       WHERE email = $1 AND role = 'admin' AND is_active = TRUE`,
      [email.toLowerCase().trim()]
    );
    if (!user) { res.json(generic); return; }

    const otp = Math.floor(100000 + Math.random() * 900000).toString();
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000);

    await academyExec(
      academy.slug,
      `UPDATE users SET otp_code = $1, otp_expires_at = $2 WHERE id = $3`,
      [otp, expiresAt.toISOString(), user.id]
    );

    await sendOtpEmail(user.email, otp, user.name);
    res.json(generic);
  } catch (err) { next(err); }
}

// ── POST /api/academy/verify-otp ──────────────────────────────────────────────

export async function verifyOtpAcademy(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academy_slug, email, otp } = req.body as {
      academy_slug: string; email: string; otp: string;
    };
    if (!academy_slug || !email || !otp) {
      return next(new AppError('academy_slug, email, and otp are required', 400));
    }

    const academy = await findActiveAcademy(academy_slug);
    if (!academy) return next(new AppError('Invalid OTP', 400));

    const user = await academyQueryOne<{
      id: string; otp_code: string | null; otp_expires_at: string | Date | null;
    }>(
      academy.slug,
      `SELECT id, otp_code, otp_expires_at FROM users
       WHERE email = $1 AND role = 'admin' AND is_active = TRUE`,
      [email.toLowerCase().trim()]
    );

    if (!user || !user.otp_code || user.otp_code !== otp) {
      return next(new AppError('Invalid OTP', 400));
    }
    if (!user.otp_expires_at || new Date(user.otp_expires_at) < new Date()) {
      return next(new AppError('OTP has expired. Please request a new one.', 400));
    }

    const resetToken = jwt.sign(
      { userId: user.id, academyId: academy.id, academySlug: academy.slug, purpose: 'academy_reset' },
      jwtSecret(),
      { expiresIn: '15m' } as import('jsonwebtoken').SignOptions
    );

    // One-time use: clear the OTP now that it's been consumed.
    await academyExec(
      academy.slug,
      `UPDATE users SET otp_code = NULL, otp_expires_at = NULL WHERE id = $1`,
      [user.id]
    );

    res.json({ success: true, data: { reset_token: resetToken }, message: 'OTP verified' });
  } catch (err) { next(err); }
}

// ── POST /api/academy/reset-password ──────────────────────────────────────────

export async function resetPasswordAcademy(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { reset_token, new_password } = req.body as {
      reset_token: string; new_password: string;
    };
    if (!reset_token || !new_password) {
      return next(new AppError('reset_token and new_password are required', 400));
    }
    if (new_password.length < 8) {
      return next(new AppError('Password must be at least 8 characters', 400));
    }

    let decoded: { userId: string; academySlug: string; purpose: string };
    try {
      decoded = jwt.verify(reset_token, jwtSecret()) as typeof decoded;
    } catch {
      return next(new AppError('Invalid or expired reset token', 400));
    }
    if (decoded.purpose !== 'academy_reset') {
      return next(new AppError('Invalid reset token', 400));
    }

    const hash = await bcrypt.hash(new_password, 12);
    await academyExec(
      decoded.academySlug,
      `UPDATE users
       SET password_hash = $1, failed_attempts = 0, is_active = TRUE,
           locked_at = NULL, locked_by = NULL, otp_code = NULL, otp_expires_at = NULL
       WHERE id = $2`,
      [hash, decoded.userId]
    );

    res.json({ success: true, message: 'Password updated successfully' });
  } catch (err) { next(err); }
}

// ── GET /api/academy/profile ──────────────────────────────────────────────────

export async function getAcademyProfile(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academyId } = req.academyUser!;
    const academy = await queryOne(
      `SELECT id, name, slug, admin_name, admin_email, phone, address, logo_url, status, created_at
       FROM academies WHERE id = $1`,
      [academyId]
    );
    if (!academy) return next(new AppError('Academy not found', 404));
    res.json({ success: true, data: academy });
  } catch (err) { next(err); }
}

// ── PATCH /api/academy/profile ────────────────────────────────────────────────

export async function updateAcademyProfile(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academyId } = req.academyUser!;
    const { name, phone, address, logo_url } = req.body as {
      name?: string; phone?: string; address?: string; logo_url?: string;
    };
    await query(
      `UPDATE academies
       SET name     = COALESCE($1, name),
           phone    = COALESCE($2, phone),
           address  = COALESCE($3, address),
           logo_url = COALESCE($4, logo_url)
       WHERE id = $5`,
      [name ?? null, phone ?? null, address ?? null, logo_url ?? null, academyId]
    );
    res.json({ success: true, message: 'Academy profile updated' });
  } catch (err) { next(err); }
}

// ── GET /api/academy/settings ─────────────────────────────────────────────────

/**
 * Return this academy's key/value settings (the per-academy `settings` table).
 * Used by the Settings screen and the Face Scan screen to read flags such as
 * `face_scan_secure` (kiosk unlock requires a password).
 */
export async function getAcademySettings(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const rows = await academyQuery<{ key: string; value: string }>(
      academySlug, `SELECT key, value FROM settings ORDER BY key`
    );
    const settings: Record<string, string> = {};
    for (const r of rows) settings[r.key] = r.value;
    res.json({ success: true, data: settings });
  } catch (err) { next(err); }
}

// ── PUT /api/academy/settings ─────────────────────────────────────────────────

// Settings an academy admin is allowed to change from the app. An allow-list
// prevents the endpoint from being used to overwrite arbitrary keys (e.g.
// kiosk_api_key, thresholds managed by the super admin).
const EDITABLE_SETTINGS = new Set(['face_scan_secure']);

/**
 * Upsert a single allow-listed academy setting. Admin-only (Decision Maker).
 */
export async function updateAcademySetting(
  req: Request, res: Response, next: NextFunction
): Promise<void> {
  try {
    const { academySlug } = req.academyUser!;
    const { key, value } = req.body as { key?: string; value?: string };

    if (!key || value === undefined) {
      return next(new AppError('key and value are required', 400));
    }
    if (!EDITABLE_SETTINGS.has(key)) {
      return next(new AppError(`Setting "${key}" is not editable`, 400));
    }

    await academyExec(
      academySlug,
      `INSERT INTO settings (key, value, updated_at)
       VALUES ($1, $2, NOW())
       ON CONFLICT (key) DO UPDATE SET value = $2, updated_at = NOW()`,
      [key, String(value)]
    );
    res.json({ success: true, data: { key, value: String(value) }, message: 'Setting updated' });
  } catch (err) { next(err); }
}
