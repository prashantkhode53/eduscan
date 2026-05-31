import { Router } from 'express';
import { authLimiter } from '../middleware/rateLimiter';
import { parentAuthMiddleware } from '../middleware/parentAuth';
import {
  parentLogin,
  saveFcmToken,
  getParentProfile,
  getAttendanceHistory,
} from '../controllers/academy/parentController';

const router = Router();

// Public — rate-limited
router.post('/login', authLimiter, parentLogin);

// Protected — requires valid parent JWT
router.use(parentAuthMiddleware);
router.post('/fcm-token',   saveFcmToken);
router.get('/profile',      getParentProfile);
router.get('/attendance',   getAttendanceHistory);

export default router;
