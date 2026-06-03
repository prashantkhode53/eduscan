import { Router } from 'express';
import { authMiddleware } from '../middleware/auth';
import {
  listAcademies,
  getAcademyStats,
  getAcademyStudents,
  exportAcademyStudents,
  deactivateAcademy,
  activateAcademy,
  deleteAcademy,
} from '../controllers/superAdminController';

const router = Router();
router.use(authMiddleware); // all routes require super admin JWT

router.get ('/',                    listAcademies);
router.get ('/:slug/stats',         getAcademyStats);
router.get ('/:slug/students',      getAcademyStudents);
router.get ('/:slug/export',        exportAcademyStudents);
router.patch('/:slug/deactivate',   deactivateAcademy);
router.patch('/:slug/activate',     activateAcademy);
router.delete('/:slug',             deleteAcademy);

export default router;
