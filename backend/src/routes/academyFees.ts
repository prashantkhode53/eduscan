import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  listFees, collectFee, generateMonthlyFees,
  markOverdueFees, getStudentFees,
} from '../controllers/academy/feeController';

const router = Router();
router.use(academyAuthMiddleware);

router.get ('/',                          listFees);
router.post('/collect',  requireRole('admin', 'teacher'), collectFee);
router.post('/generate', requireRole('admin'), generateMonthlyFees);
router.post('/mark-overdue', requireRole('admin'), markOverdueFees);
router.get ('/student/:studentId',        getStudentFees);

export default router;
