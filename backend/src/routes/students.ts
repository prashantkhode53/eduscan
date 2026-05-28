import { Router } from 'express';
import {
  listStudents,
  createStudent,
  getStudent,
  updateStudent,
  deleteStudent,
  getStudentAttendance,
  listFaceDuplicates,
} from '../controllers/studentController';
import { authMiddleware } from '../middleware/auth';

const router = Router();

router.use(authMiddleware);

router.get('/', listStudents);
router.post('/', createStudent);
// Diagnostic: find students whose face embeddings are suspiciously similar
router.get('/face-duplicates', listFaceDuplicates);
router.get('/:id', getStudent);
router.put('/:id', updateStudent);
router.delete('/:id', deleteStudent);
router.get('/:id/attendance', getStudentAttendance);

export default router;
