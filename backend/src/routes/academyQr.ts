import { Router } from 'express';
import { academyAuthMiddleware, requireRole } from '../middleware/academyAuth';
import {
  listQrCodes, getActiveQrCode, createQrCode,
  updateQrCode, activateQrCode, deleteQrCode,
} from '../controllers/academy/qrController';

const router = Router();
router.use(academyAuthMiddleware);

// active must be registered before /:id so it isn't swallowed as an id param
router.get   ('/active',          getActiveQrCode);
router.get   ('/',                listQrCodes);
router.post  ('/',                requireRole('admin', 'teacher'), createQrCode);
router.put   ('/:id',             requireRole('admin', 'teacher'), updateQrCode);
router.patch ('/:id/activate',    requireRole('admin', 'teacher'), activateQrCode);
router.delete('/:id',             requireRole('admin'),            deleteQrCode);

export default router;
