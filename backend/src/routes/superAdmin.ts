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
  resetAcademyAdminPassword,
  getFaceThreshold,
  setFaceThreshold,
} from '../controllers/superAdminController';
import {
  listAcademyYears,
  listAcademyCourses,
  listCourseUnlockRoster,
  unlockCourseFees,
  relockCourseFees,
} from '../controllers/superAdminController.courseUnlocks';

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
router.patch ('/:slug/reset-password', resetAcademyAdminPassword);
router.get   ('/:slug/face-threshold', getFaceThreshold);
router.put   ('/:slug/face-threshold', setFaceThreshold);

// Course fee unlocks — let the academy admin edit a student's frozen subject fees.
router.get   ('/:slug/academic-years',                listAcademyYears);
router.get   ('/:slug/courses',                       listAcademyCourses);
router.get   ('/:slug/courses/:courseId/students',    listCourseUnlockRoster);
router.post  ('/:slug/course-unlocks',                unlockCourseFees);
router.delete('/:slug/course-unlocks',                relockCourseFees);

// Keep last: '/:slug' would otherwise swallow the more specific paths above.
router.delete('/:slug',                deleteAcademy);

export default router;
