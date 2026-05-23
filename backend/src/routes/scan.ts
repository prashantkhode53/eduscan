import { Router } from 'express';
import { scan } from '../controllers/scanController';
import { kioskAuthMiddleware } from '../middleware/kioskAuth';
import { scanLimiter } from '../middleware/rateLimiter';

const router = Router();

router.post('/scan', scanLimiter, kioskAuthMiddleware, scan);

export default router;
