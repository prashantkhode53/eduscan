import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  listAcademicYears,
  getCurrentAcademicYear,
  createAcademicYear,
  updateAcademicYear,
  deleteAcademicYear,
} from '../controllers/academy/academicYearController';

const router = Router();
router.use(academyAuthMiddleware);

router.get('/',        listAcademicYears);
router.get('/current', getCurrentAcademicYear);
router.post('/',        requireRole('admin'), createAcademicYear);
router.put('/:id',     requireRole('admin'), updateAcademicYear);
router.delete('/:id',  requireRole('admin'), deleteAcademicYear);

export default router;
