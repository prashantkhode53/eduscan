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

router.use(authMiddleware);

router.get('/', listAttendance);
router.post('/', createAttendance);
router.put('/:id', updateAttendance);
router.post('/batch', batchAttendance);
router.post('/bulk-absent', bulkMarkAbsent);

export default router;
