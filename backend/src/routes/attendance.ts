import { Router } from 'express';
import {
  listAttendance,
  createAttendance,
  updateAttendance,
  batchAttendance,
  bulkMarkAbsent,
} from '../controllers/attendanceController';
import { authMiddleware } from '../middleware/auth';

const router = Router();

// authMiddleware applied per-route so POST /scan falls through to scanRoutes
router.get('/', authMiddleware, listAttendance);
router.post('/', authMiddleware, createAttendance);
router.put('/:id', authMiddleware, updateAttendance);
router.post('/batch', authMiddleware, batchAttendance);
router.post('/bulk-absent', authMiddleware, bulkMarkAbsent);

export default router;
