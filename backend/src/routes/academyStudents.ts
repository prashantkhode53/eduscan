import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  registerStudent, listStudents, getStudent, getStats,
} from '../controllers/academy/studentController';

const router = Router();
router.use(academyAuthMiddleware);

router.get ('/stats',  getStats);
router.get ('/',       listStudents);
router.post('/',       requireRole('admin', 'teacher'), registerStudent);
router.get ('/:id',    getStudent);

export default router;
