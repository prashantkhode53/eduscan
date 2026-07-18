import { Router } from 'express';
import { authLimiter } from '../middleware/rateLimiter';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  registerAcademy,
  loginAcademyUser,
  forgotPasswordAcademy,
  verifyOtpAcademy,
  resetPasswordAcademy,
  getAcademyProfile,
  updateAcademyProfile,
  getAcademySettings,
  updateAcademySetting,
} from '../controllers/academyController';

const router = Router();

// Public — no auth required
router.post('/register', registerAcademy);
router.post('/login',    authLimiter, loginAcademyUser);

// Password reset — OTP by email, admins only (public, rate-limited)
router.post('/forgot-password', authLimiter, forgotPasswordAcademy);
router.post('/verify-otp',      authLimiter, verifyOtpAcademy);
router.post('/reset-password',  authLimiter, resetPasswordAcademy);

// Protected — valid academy JWT required
router.get ('/profile', academyAuthMiddleware, getAcademyProfile);
router.patch('/profile', academyAuthMiddleware, requireRole('admin'), updateAcademyProfile);

// Per-academy settings (e.g. Face Scan Attendance password protection toggle)
router.get('/settings', academyAuthMiddleware, getAcademySettings);
router.put('/settings', academyAuthMiddleware, requireRole('admin'), updateAcademySetting);

export default router;
