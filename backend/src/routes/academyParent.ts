import { Router } from 'express';
import { authLimiter } from '../middleware/rateLimiter';
import { parentAuthMiddleware, parentSessionMiddleware } from '../middleware/parentAuth';
import {
  checkCredentials,
  verifyFace,
  saveFcmToken,
  getParentProfile,
  getAttendanceHistory,
  getParentReceipts,
  getParentReceipt,
} from '../controllers/academy/parentController';

const router = Router();

// ── Step 1: validate credentials → returns 5-min session token ───────────────
router.post('/check-credentials', authLimiter, checkCredentials);

// ── Step 2: verify face → returns 30-day parent JWT ──────────────────────────
// Uses the session token (not the full parent JWT) as Bearer
router.post('/verify-face', parentSessionMiddleware, verifyFace);

// ── Protected routes — require valid 30-day parent JWT ────────────────────────
router.post('/fcm-token',      parentAuthMiddleware, saveFcmToken);
router.get('/profile',         parentAuthMiddleware, getParentProfile);
router.get('/attendance',      parentAuthMiddleware, getAttendanceHistory);
router.get('/receipts',        parentAuthMiddleware, getParentReceipts);
router.get('/receipts/:id',    parentAuthMiddleware, getParentReceipt);

export default router;
