import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import { scanAcademy } from '../controllers/academy/attendanceController';

const router = Router();

router.use(academyAuthMiddleware);
router.post('/scan', requireRole('admin', 'teacher'), scanAcademy);

export default router;
