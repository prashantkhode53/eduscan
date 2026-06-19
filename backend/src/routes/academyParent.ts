import { Router } from 'express';
import { authLimiter, passwordLimiter } from '../middleware/rateLimiter';
import { parentAuthMiddleware, parentSessionMiddleware } from '../middleware/parentAuth';
import {
  checkCredentials,
  verifyFace,
  verifyPassword,
  saveFcmToken,
  getParentProfile,
  getAttendanceHistory,
  getParentReceipts,
  getParentReceipt,
} from '../controllers/academy/parentController';
import {
  getParentNotifications,
  getLatestParentNotification,
  markNotificationRead,
} from '../controllers/academy/notificationController';

const router = Router();

// ── Step 1: validate credentials → returns 5-min session token ───────────────
router.post('/check-credentials', authLimiter, checkCredentials);

// ── Step 2a: verify face → returns 30-day parent JWT ─────────────────────────
// Uses the session token (not the full parent JWT) as Bearer
router.post('/verify-face', parentSessionMiddleware, verifyFace);

// ── Step 2b: verify institute password → returns 30-day parent JWT ────────────
// Requires session token; only works when admin has set fallback_password_enabled
router.post('/verify-password', passwordLimiter, parentSessionMiddleware, verifyPassword);

// ── Protected routes — require valid 30-day parent JWT ────────────────────────
router.post('/fcm-token',      parentAuthMiddleware, saveFcmToken);
router.get('/profile',         parentAuthMiddleware, getParentProfile);
router.get('/attendance',      parentAuthMiddleware, getAttendanceHistory);
router.get('/receipts',        parentAuthMiddleware, getParentReceipts);
router.get('/receipts/:id',    parentAuthMiddleware, getParentReceipt);

// ── Parent notifications (broadcast inbox + ticker) ───────────────────────────
router.get('/notifications',         parentAuthMiddleware, getParentNotifications);
router.get('/notifications/latest',  parentAuthMiddleware, getLatestParentNotification);
router.post('/notifications/:id/read', parentAuthMiddleware, markNotificationRead);

export default router;
