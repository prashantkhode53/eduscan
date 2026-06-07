import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  registerStudent, listStudents, getStudent, getStats,
  updateStudent, updateStudentFace, deleteStudent, checkDuplicate,
  bulkUploadStudents, setMasterPassword, deleteMasterPassword,
} from '../controllers/academy/studentController';

const router = Router();
router.use(academyAuthMiddleware);

router.get  ('/stats',            getStats);
// Static sub-paths MUST be registered before /:id to avoid Express treating
// the literal string as an id param value.
router.get  ('/check-duplicate',  requireRole('admin', 'teacher'), checkDuplicate);
router.post ('/bulk-upload',      requireRole('admin', 'teacher'), bulkUploadStudents);
router.get  ('/',                 listStudents);
router.post ('/',                 requireRole('admin', 'teacher'), registerStudent);
router.get  ('/:id',              getStudent);
router.patch('/:id/face',         requireRole('admin', 'teacher'), updateStudentFace);
router.patch('/:id',              requireRole('admin', 'teacher'), updateStudent);
router.delete('/:id',             requireRole('admin', 'teacher'), deleteStudent);
// ── Fallback password (admin-only) ────────────────────────────────────────────
router.put   ('/:id/master-password', requireRole('admin'), setMasterPassword);
router.delete('/:id/master-password', requireRole('admin'), deleteMasterPassword);

export default router;
