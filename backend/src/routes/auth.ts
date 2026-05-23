import { Router } from 'express';
import {
  login,
  forgotPassword,
  verifyOtp,
  resetPassword,
  changePassword,
  healthCheck,
} from '../controllers/authController';
import { authMiddleware } from '../middleware/auth';
import { authLimiter } from '../middleware/rateLimiter';

const router = Router();

router.get('/health', healthCheck);
router.post('/auth/login', authLimiter, login);
router.post('/auth/forgot-password', authLimiter, forgotPassword);
router.post('/auth/verify-otp', authLimiter, verifyOtp);
router.post('/auth/reset-password', authLimiter, resetPassword);
router.post('/auth/change-password', authMiddleware, changePassword);

export default router;
