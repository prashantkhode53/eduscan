import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  sendParentNotification,
  listSentNotifications,
} from '../controllers/academy/notificationController';

const router = Router();

router.use(academyAuthMiddleware);

// Broadcast a notification to parents (admin only)
router.post('/', requireRole('admin'), sendParentNotification);

// Notification history / audit (admin + teacher)
router.get('/', requireRole('admin', 'teacher'), listSentNotifications);

export default router;
