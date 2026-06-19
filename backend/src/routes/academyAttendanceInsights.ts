import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  getTodayActionList,
  getStudentScores,
  getStudentScoreDetail,
  getDefaulters,
  nudgeParent,
} from '../controllers/academy/attendanceInsightsController';

const router = Router();

// All attendance-intelligence routes are admin/teacher only and scoped to the
// caller's academy schema. Read-only except the explicit nudge action, which
// reuses the existing fire-and-forget FCM helper (no DB write).
router.use(academyAuthMiddleware);

router.get('/today',               requireRole('admin', 'teacher'), getTodayActionList);
router.get('/students',            requireRole('admin', 'teacher'), getStudentScores);
router.get('/defaulters',          requireRole('admin', 'teacher'), getDefaulters);
router.get('/:studentId/score',    requireRole('admin', 'teacher'), getStudentScoreDetail);
router.post('/:studentId/nudge',   requireRole('admin', 'teacher'), nudgeParent);

export default router;
