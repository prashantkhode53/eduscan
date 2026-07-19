import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import { scanAcademy, verifyAcademyPassword } from '../controllers/academy/attendanceController';
import { groupScanRoster, groupScanPhoto, groupScanApprove } from '../controllers/academy/groupAttendanceController';

const router = Router();

router.use(academyAuthMiddleware);
router.post('/scan', requireRole('admin', 'teacher'), scanAcademy);
// Kiosk lock-mode unlock: re-verify the current academy user's password.
router.post('/verify-password', requireRole('admin', 'teacher'), verifyAcademyPassword);

// One-Click Attendance (group class photos). Scanning is open to teachers,
// but the final approval that writes attendance is admin-only by design.
router.get ('/group-scan/roster',  requireRole('admin', 'teacher'), groupScanRoster);
router.post('/group-scan/photo',   requireRole('admin', 'teacher'), groupScanPhoto);
router.post('/group-scan/approve', requireRole('admin'),            groupScanApprove);

export default router;
