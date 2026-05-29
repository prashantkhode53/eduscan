import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  listCourses, createCourse, updateCourse, deleteCourse,
} from '../controllers/academy/courseController';

const router = Router();
router.use(academyAuthMiddleware);

router.get ('/',    listCourses);
router.post('/',    requireRole('admin', 'teacher'), createCourse);
router.put ('/:id', requireRole('admin', 'teacher'), updateCourse);
router.delete('/:id', requireRole('admin'), deleteCourse);

export default router;
