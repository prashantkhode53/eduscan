import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  registerStudent, listStudents, getStudent, getStats, updateStudent, deleteStudent,
} from '../controllers/academy/studentController';

const router = Router();
router.use(academyAuthMiddleware);

router.get  ('/stats',  getStats);
router.get  ('/',       listStudents);
router.post ('/',       requireRole('admin', 'teacher'), registerStudent);
router.get  ('/:id',    getStudent);
router.patch('/:id',    requireRole('admin', 'teacher'), updateStudent);
router.delete('/:id',   requireRole('admin', 'teacher'), deleteStudent);

export default router;
