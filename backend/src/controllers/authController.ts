import { Request, Response, NextFunction } from 'express';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { query, queryOne } from '../db/pool';
import { sendOtpEmail } from '../utils/emailService';
import { AppError } from '../middleware/errorHandler';
import { Admin, ApiResponse, AuthResponse } from '../types';

interface AdminRow {
  id: string;
  username: string;
  password_hash: string;
  email: string;
  full_name: string | null;
  role: string;
  is_locked: boolean;
  failed_attempts: number;
  last_login: string | null;
  created_at: string;
}

function toAdmin(row: AdminRow): Admin {
  return {
    id: row.id,
    username: row.username,
    email: row.email,
    full_name: row.full_name ?? undefined,
    role: row.role,
    is_locked: row.is_locked,
    last_login: row.last_login ?? undefined,
    created_at: row.created_at,
  };
}

export async function login(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { username, password } = req.body as { username: string; password: string };
    if (!username || !password) {
      return next(new AppError('Username and password are required', 400));
    }

    const row = await queryOne<AdminRow>(
      `SELECT id, username, password_hash, email, full_name, role, is_locked, failed_attempts, last_login, created_at
       FROM admins WHERE username = $1`,
      [username]
    );

    if (!row) {
      return next(new AppError('Invalid credentials', 401));
    }

    if (row.is_locked) {
      return next(new AppError('Account locked due to too many failed attempts. Contact super admin.', 403));
    }

    const passwordMatch = await bcrypt.compare(password, row.password_hash);
    if (!passwordMatch) {
      const newAttempts = row.failed_attempts + 1;
      const lockAccount = newAttempts >= 5;
      await query(
        `UPDATE admins SET failed_attempts = $1, is_locked = $2 WHERE id = $3`,
        [newAttempts, lockAccount, row.id]
      );
      if (lockAccount) {
        return next(new AppError('Account locked after 5 failed attempts.', 403));
      }
      return next(new AppError(`Invalid credentials. ${5 - newAttempts} attempt(s) remaining.`, 401));
    }

    await query(
      `UPDATE admins SET failed_attempts = 0, last_login = NOW() WHERE id = $1`,
      [row.id]
    );

    const secret = process.env.JWT_SECRET;
    if (!secret) throw new AppError('JWT_SECRET not configured', 500);

    const admin = toAdmin(row);
    const token = jwt.sign(admin, secret, {
      expiresIn: process.env.JWT_EXPIRES_IN ?? '365d',
    } as jwt.SignOptions);

    const response: ApiResponse<AuthResponse> = {
      success: true,
      data: { token, admin },
      message: 'Login successful',
    };
    res.json(response);
  } catch (err) {
    next(err);
  }
}

export async function forgotPassword(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { email } = req.body as { email: string };
    if (!email) return next(new AppError('Email is required', 400));

    const row = await queryOne<AdminRow>(
      `SELECT id, username, full_name, email FROM admins WHERE email = $1`,
      [email]
    );

    // Always respond success to prevent email enumeration
    if (!row) {
      res.json({ success: true, message: 'If that email exists, an OTP has been sent.' });
      return;
    }

    const otp = Math.floor(100000 + Math.random() * 900000).toString();
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000);

    await query(
      `UPDATE admins SET otp_code = $1, otp_expires_at = $2 WHERE id = $3`,
      [otp, expiresAt.toISOString(), row.id]
    );

    await sendOtpEmail(row.email, otp, row.full_name ?? row.username);
    res.json({ success: true, message: 'OTP sent to registered email address.' });
  } catch (err) {
    next(err);
  }
}

export async function verifyOtp(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { email, otp } = req.body as { email: string; otp: string };
    if (!email || !otp) return next(new AppError('Email and OTP are required', 400));

    const row = await queryOne<{
      id: string;
      otp_code: string;
      otp_expires_at: string;
    }>(
      `SELECT id, otp_code, otp_expires_at FROM admins WHERE email = $1`,
      [email]
    );

    if (!row || row.otp_code !== otp) {
      return next(new AppError('Invalid OTP', 400));
    }
    if (new Date(row.otp_expires_at) < new Date()) {
      return next(new AppError('OTP has expired. Please request a new one.', 400));
    }

    const secret = process.env.JWT_SECRET;
    if (!secret) throw new AppError('JWT_SECRET not configured', 500);
    const resetToken = jwt.sign({ id: row.id, purpose: 'reset' }, secret, { expiresIn: '15m' });

    await query(`UPDATE admins SET otp_code = NULL, otp_expires_at = NULL WHERE id = $1`, [row.id]);

    res.json({ success: true, data: { reset_token: resetToken }, message: 'OTP verified' });
  } catch (err) {
    next(err);
  }
}

export async function resetPassword(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const { reset_token, new_password } = req.body as { reset_token: string; new_password: string };
    if (!reset_token || !new_password) {
      return next(new AppError('reset_token and new_password are required', 400));
    }
    if (new_password.length < 8) {
      return next(new AppError('Password must be at least 8 characters', 400));
    }

    const secret = process.env.JWT_SECRET;
    if (!secret) throw new AppError('JWT_SECRET not configured', 500);

    const decoded = jwt.verify(reset_token, secret) as { id: string; purpose: string };
    if (decoded.purpose !== 'reset') {
      return next(new AppError('Invalid reset token', 400));
    }

    const hash = await bcrypt.hash(new_password, 12);
    await query(
      `UPDATE admins SET password_hash = $1, failed_attempts = 0, is_locked = FALSE WHERE id = $2`,
      [hash, decoded.id]
    );

    res.json({ success: true, message: 'Password updated successfully' });
  } catch (err) {
    if (err instanceof jwt.JsonWebTokenError) {
      return next(new AppError('Invalid or expired reset token', 400));
    }
    next(err);
  }
}

export async function changePassword(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const admin = req.admin!;
    const { current_password, new_password } = req.body as {
      current_password: string;
      new_password: string;
    };
    if (!current_password || !new_password) {
      return next(new AppError('current_password and new_password are required', 400));
    }
    if (new_password.length < 8) {
      return next(new AppError('New password must be at least 8 characters', 400));
    }

    const row = await queryOne<{ password_hash: string }>(
      `SELECT password_hash FROM admins WHERE id = $1`,
      [admin.id]
    );
    if (!row) return next(new AppError('Admin not found', 404));

    const match = await bcrypt.compare(current_password, row.password_hash);
    if (!match) return next(new AppError('Current password is incorrect', 401));

    const hash = await bcrypt.hash(new_password, 12);
    await query(`UPDATE admins SET password_hash = $1 WHERE id = $2`, [hash, admin.id]);

    res.json({ success: true, message: 'Password changed successfully' });
  } catch (err) {
    next(err);
  }
}

export async function healthCheck(_req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    await query('SELECT 1');
    res.json({
      success: true,
      data: {
        status: 'ok',
        db: 'connected',
        uptime: Math.floor(process.uptime()),
        timestamp: new Date().toISOString(),
      },
      message: 'Server healthy',
    });
  } catch (err) {
    next(new AppError('Database connection failed', 503));
  }
}
