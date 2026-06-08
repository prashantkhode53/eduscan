import { Request, Response, NextFunction } from 'express';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { query, queryOne } from '../db/pool';
import { sharedPool, academyQueryOne, academyExec } from '../db/poolManager';
import { runAcademyMigrations } from '../db/academyMigrations';
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
