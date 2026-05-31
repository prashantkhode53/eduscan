import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';

// ── Parent JWT (30 days — issued after face verification) ─────────────────────

export interface ParentTokenPayload {
  type:        'parent';
  studentId:   string;
  academySlug: string;
  academyName: string;
  parentName:  string;
  mobile:      string;
}

// ── Parent session JWT (5 min — issued after credential check) ────────────────

export interface ParentSessionPayload {
  type:        'parent_session';
  studentId:   string;
  academySlug: string;
  academyName: string;
  parentName:  string;
  mobile:      string;
}

declare global {
  namespace Express {
    interface Request {
      parentUser?:    ParentTokenPayload;
      parentSession?: ParentSessionPayload;
    }
  }
}

function verifyBearer<T>(
  req: Request, res: Response,
  expectedType: string,
  assign: (payload: T) => void
): boolean {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    res.status(401).json({ success: false, message: 'No token provided' });
    return false;
  }
  const secret = process.env.JWT_SECRET;
  if (!secret) {
    res.status(500).json({ success: false, message: 'Server misconfiguration' });
    return false;
  }
  try {
    const payload = jwt.verify(header.split(' ')[1], secret) as T & { type: string };
    if (payload.type !== expectedType) {
      res.status(403).json({ success: false, message: `Invalid token type (expected ${expectedType})` });
      return false;
    }
    assign(payload);
    return true;
  } catch {
    res.status(401).json({ success: false, message: 'Token invalid or expired. Please log in again.' });
    return false;
  }
}

/** Validates the 30-day parent JWT (used on all protected parent routes). */
export function parentAuthMiddleware(
  req: Request, res: Response, next: NextFunction
): void {
  if (verifyBearer<ParentTokenPayload>(req, res, 'parent', (p) => { req.parentUser = p; })) {
    next();
  }
}

/** Validates the 5-min session JWT (used only on /verify-face). */
export function parentSessionMiddleware(
  req: Request, res: Response, next: NextFunction
): void {
  if (verifyBearer<ParentSessionPayload>(req, res, 'parent_session', (p) => { req.parentSession = p; })) {
    next();
  }
}
