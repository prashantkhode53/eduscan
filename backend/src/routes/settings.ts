import { Router, Request, Response, NextFunction } from 'express';
import { query, queryOne } from '../db/pool';
import { authMiddleware } from '../middleware/auth';
import { AppError } from '../middleware/errorHandler';
import { v4 as uuidv4 } from 'uuid';

const router = Router();
router.use(authMiddleware);

router.get('/', async (_req: Request, res: Response, next: NextFunction): Promise<void> => {
  try {
    const rows = await query<{ key: string; value: string }>(`SELECT key, value FROM settings ORDER BY key`);
    const settings: Record<string, string> = {};
    for (const row of rows) settings[row.key] = row.value;
    res.json({ success: true, data: settings, message: 'Settings fetched' });
  } catch (err) {
    next(err);
  }
});

router.put('/', async (req: Request, res: Response, next: NextFunction): Promise<void> => {
  try {
    const { key, value } = req.body as { key: string; value: string };
    if (!key || value === undefined) {
      return next(new AppError('key and value are required', 400));
    }
    await query(
      `INSERT INTO settings (key, value, updated_at) VALUES ($1, $2, NOW())
       ON CONFLICT (key) DO UPDATE SET value = $2, updated_at = NOW()`,
      [key, String(value)]
    );
    res.json({ success: true, data: { key, value }, message: 'Setting updated' });
  } catch (err) {
    next(err);
  }
});

router.post('/regen-kiosk-key', async (_req: Request, res: Response, next: NextFunction): Promise<void> => {
  try {
    const newKey = uuidv4();
    await query(
      `UPDATE settings SET value = $1, updated_at = NOW() WHERE key = 'kiosk_api_key'`,
      [newKey]
    );
    res.json({ success: true, data: { kiosk_api_key: newKey }, message: 'Kiosk key regenerated' });
  } catch (err) {
    next(err);
  }
});

export default router;
