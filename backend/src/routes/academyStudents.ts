import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  registerStudent, listStudents, getStudent, getStats,
  updateStudent, updateStudentFace, deleteStudent, checkDuplicate,
} from '../controllers/academy/studentController';

const router = Router();
router.use(academyAuthMiddleware);

router.get  ('/stats',            getStats);
// check-duplicate MUST be registered before /:id to avoid Express treating
// "check-duplicate" as an id param value.
router.get  ('/check-duplicate',  requireRole('admin', 'teacher'), checkDuplicate);
router.get  ('/',                 listStudents);
router.post ('/',                 requireRole('admin', 'teacher'), registerStudent);
router.get  ('/:id',              getStudent);
router.patch('/:id/face',         requireRole('admin', 'teacher'), updateStudentFace);
router.patch('/:id',              requireRole('admin', 'teacher'), updateStudent);
router.delete('/:id',             requireRole('admin', 'teacher'), deleteStudent);

export default router;
