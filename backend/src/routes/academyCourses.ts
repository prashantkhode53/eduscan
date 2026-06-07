import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  listCourses, createCourse, updateCourse, deleteCourse,
  listSubjects, createSubject, updateSubject, deleteSubject,
} from '../controllers/academy/courseController';

const router = Router();
router.use(academyAuthMiddleware);

// ── Course CRUD ───────────────────────────────────────────────────────────────
router.get ('/',    listCourses);
router.post('/',    requireRole('admin', 'teacher'), createCourse);

// ── Subject CRUD (static paths before /:id to avoid param capture) ────────────
router.put   ('/subjects/:subjectId', requireRole('admin', 'teacher'), updateSubject);
router.delete('/subjects/:subjectId', requireRole('admin'), deleteSubject);

router.put ('/:id', requireRole('admin', 'teacher'), updateCourse);
router.delete('/:id', requireRole('admin'), deleteCourse);

// Nested subject routes — after :id routes so /:courseId reads correctly
router.get ('/:courseId/subjects', listSubjects);
router.post('/:courseId/subjects', requireRole('admin', 'teacher'), createSubject);

export default router;
