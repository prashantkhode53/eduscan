import { Router, Request, Response, NextFunction } from 'express';
import { scan } from '../controllers/scanController';
import { kioskAuthMiddleware } from '../middleware/kioskAuth';
import { authMiddleware } from '../middleware/auth';
import { scanLimiter } from '../middleware/rateLimiter';

const router = Router();

// Accept either X-Kiosk-Key (kiosk devices) or Bearer JWT (admin testing)
const flexAuth = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
  const kioskKey = req.headers['x-kiosk-key'];
  const authHeader = req.headers['authorization'];

  if (kioskKey) {
    return kioskAuthMiddleware(req, res, next);
  } else if (authHeader) {
    return authMiddleware(req, res, next);
  } else {
    res.status(401).json({
      success: false,
      message: 'Authentication required — provide X-Kiosk-Key or Authorization header',
    });
  }
};

router.post('/scan', scanLimiter, flexAuth, scan);

export default router;
