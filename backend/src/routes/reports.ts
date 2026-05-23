import { Router } from 'express';
import {
  getDashboardStats,
  getWeeklyReport,
  exportReport,
  getRecentActivity,
  getStudentReportSummary,
} from '../controllers/reportsController';
import { authMiddleware } from '../middleware/auth';

const router = Router();

router.use(authMiddleware);

router.get('/summary', getDashboardStats);
router.get('/weekly', getWeeklyReport);
router.get('/recent-activity', getRecentActivity);
router.get('/students', getStudentReportSummary);
router.get('/export', exportReport);

export default router;
