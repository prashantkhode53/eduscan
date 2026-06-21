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
  getAcademyLoginStatus,
  unlockAcademyUser,
  resetLoginAttempts,
  blockAcademyUser,
  getFaceThreshold,
  setFaceThreshold,
} from '../controllers/superAdminController';

const router = Router();
router.use(authMiddleware); // all routes require super admin JWT

router.get   ('/',                     listAcademies);
router.get   ('/:slug/stats',          getAcademyStats);
router.get   ('/:slug/students',       getAcademyStudents);
router.get   ('/:slug/export',         exportAcademyStudents);
router.get   ('/:slug/login-status',   getAcademyLoginStatus);
router.patch ('/:slug/deactivate',     deactivateAcademy);
router.patch ('/:slug/activate',       activateAcademy);
router.patch ('/:slug/unlock-user',    unlockAcademyUser);
router.patch ('/:slug/reset-attempts', resetLoginAttempts);
router.patch ('/:slug/block-user',     blockAcademyUser);
router.get   ('/:slug/face-threshold', getFaceThreshold);
router.put   ('/:slug/face-threshold', setFaceThreshold);
router.delete('/:slug',                deleteAcademy);

export default router;
