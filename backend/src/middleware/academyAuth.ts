import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { AcademyUser, AcademyUserRole } from '../types';

export function academyAuthMiddleware(
  req: Request,
  res: Response,
  next: NextFunction
): void {
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    res.status(401).json({ success: false, message: 'Missing or invalid authorization header' });
    return;
  }
  const token = authHeader.split(' ')[1];
  try {
    const secret = process.env.JWT_SECRET;
    if (!secret) throw new Error('JWT_SECRET not configured');
    const decoded = jwt.verify(token, secret) as AcademyUser;
    if (decoded.type !== 'academy') {
      res.status(403).json({ success: false, message: 'Token is not an academy token' });
      return;
    }
    req.academyUser = decoded;
    next();
  } catch {
    res.status(401).json({ success: false, message: 'Invalid or expired token' });
  }
}

/** Restrict route to specific academy roles */
export function requireRole(...roles: AcademyUserRole[]) {
  return (req: Request, res: Response, next: NextFunction): void => {
    if (!req.academyUser || !roles.includes(req.academyUser.role)) {
      res.status(403).json({ success: false, message: 'Insufficient permissions' });
      return;
    }
    next();
  };
}
