import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  listFees, listFeesStudentSummary, collectFee,
  generateMonthlyFees, markOverdueFees, getStudentFees,
  listReceipts, getReceipt, resendReceipt, getFeesExportData,
} from '../controllers/academy/feeController';

const router = Router();
router.use(academyAuthMiddleware);

router.get ('/',                          listFees);
router.get ('/students-summary',          listFeesStudentSummary);
router.get ('/export-data',               getFeesExportData);
router.post('/collect',  requireRole('admin', 'teacher'), collectFee);
router.post('/generate', requireRole('admin'), generateMonthlyFees);
router.post('/mark-overdue', requireRole('admin'), markOverdueFees);
router.get ('/student/:studentId',        getStudentFees);

// ── Receipt management ────────────────────────────────────────────────────────
router.get ('/receipts',          listReceipts);
router.get ('/receipts/:id',      getReceipt);
router.post('/receipts/:id/resend', requireRole('admin', 'teacher'), resendReceipt);

export default router;
