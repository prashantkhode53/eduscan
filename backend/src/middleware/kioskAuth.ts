import { Request, Response, NextFunction } from 'express';
import { queryOne } from '../db/pool';

export const kioskAuthMiddleware = async (
  req: Request,
  res: Response,
  next: NextFunction
): Promise<void> => {
  const kioskKey = req.headers['x-kiosk-key'] as string | undefined;
  if (!kioskKey) {
    res.status(401).json({ success: false, message: 'Missing X-Kiosk-Key header' });
    return;
  }
  try {
    const setting = await queryOne<{ value: string }>(
      'SELECT value FROM settings WHERE key = $1',
      ['kiosk_api_key']
    );
    if (!setting || setting.value !== kioskKey) {
      res.status(401).json({ success: false, message: 'Invalid kiosk key' });
      return;
    }
    next();
  } catch (err) {
    console.error('Kiosk auth error:', err);
    res.status(500).json({ success: false, message: 'Server error during kiosk authentication' });
  }
};
