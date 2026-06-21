import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import { scanAcademy, verifyAcademyPassword } from '../controllers/academy/attendanceController';

const router = Router();

router.use(academyAuthMiddleware);
router.post('/scan', requireRole('admin', 'teacher'), scanAcademy);
// Kiosk lock-mode unlock: re-verify the current academy user's password.
router.post('/verify-password', requireRole('admin', 'teacher'), verifyAcademyPassword);

export default router;
