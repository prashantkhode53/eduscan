import { Router } from 'express';
import {
  login,
  forgotPassword,
  verifyOtp,
  resetPassword,
  changePassword,
} from '../controllers/authController';
import { authMiddleware } from '../middleware/auth';
import { authLimiter } from '../middleware/rateLimiter';

const router = Router();

router.post('/login', authLimiter, login);
router.post('/forgot-password', authLimiter, forgotPassword);
router.post('/verify-otp', authLimiter, verifyOtp);
router.post('/reset-password', authLimiter, resetPassword);
router.post('/change-password', authMiddleware, changePassword);

export default router;
