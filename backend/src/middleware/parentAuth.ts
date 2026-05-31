import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';

export interface ParentTokenPayload {
  type:        'parent';
  studentId:   string;
  academySlug: string;
  academyName: string;
  parentName:  string;
  mobile:      string;
}

declare global {
  namespace Express {
    interface Request {
      parentUser?: ParentTokenPayload;
    }
  }
}

export function parentAuthMiddleware(
  req: Request, res: Response, next: NextFunction
): void {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    res.status(401).json({ success: false, message: 'No token provided' });
    return;
  }

  const secret = process.env.JWT_SECRET;
  if (!secret) {
    res.status(500).json({ success: false, message: 'Server misconfiguration' });
    return;
  }

  try {
    const payload = jwt.verify(header.split(' ')[1], secret) as ParentTokenPayload;
    if (payload.type !== 'parent') {
      res.status(403).json({ success: false, message: 'Token is not a parent token' });
      return;
    }
    req.parentUser = payload;
    next();
  } catch {
    res.status(401).json({ success: false, message: 'Token invalid or expired. Please log in again.' });
  }
}
