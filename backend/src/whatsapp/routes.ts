import { Router, Request, Response, NextFunction } from 'express';
import rateLimit from 'express-rate-limit';
import Joi from 'joi';
import { authMiddleware } from '../middleware/auth';
import { sendMessage, getMessageStats } from './messageService';
import { whatsappService } from './service';
import type { WaStatusPayload } from './service';
import { isValidPhone } from './phoneFormatter';

const router = Router();

// All WhatsApp routes require a valid JWT — same as every other protected route
router.use(authMiddleware);

// ── Rate limiter for message-send endpoints ───────────────────────────────────

const msgLimiter = rateLimit({
  windowMs: parseInt(process.env.WA_RATE_LIMIT_WINDOW_MS ?? '60000', 10),
  max:      parseInt(process.env.WA_RATE_LIMIT_MAX ?? '30', 10),
  standardHeaders: true,
  legacyHeaders:   false,
  handler: (_req: Request, res: Response) => {
    res.status(429).json({ success: false, message: 'Too many requests — slow down.' });
  },
});

// ── Joi schemas ───────────────────────────────────────────────────────────────

const phoneField = Joi.string().custom((v: string, h) =>
  isValidPhone(v) ? v : h.error('any.invalid')
);

const schemas = {
  checkin: Joi.object({
    phone:       phoneField.required(),
    parentName:  Joi.string().min(1).max(100).trim().required(),
    studentName: Joi.string().min(1).max(100).trim().required(),
    time:        Joi.string().min(1).max(30).trim().required(),
  }),
  checkout: Joi.object({
    phone:       phoneField.required(),
    parentName:  Joi.string().min(1).max(100).trim().required(),
    studentName: Joi.string().min(1).max(100).trim().required(),
    time:        Joi.string().min(1).max(30).trim().required(),
  }),
  custom: Joi.object({
    phone:   phoneField.required(),
    message: Joi.string().min(1).max(1000).trim().required(),
  }),
};

function validate(schema: keyof typeof schemas) {
  return (req: Request, res: Response, next: NextFunction): void => {
    const { error, value } = schemas[schema].validate(req.body, { abortEarly: false });
    if (error) {
      res.status(400).json({
        success: false,
        message: error.details.map((d) => d.message).join('; '),
      });
      return;
    }
    req.body = value;
    next();
  };
}

// ── GET /whatsapp/status ──────────────────────────────────────────────────────

router.get('/status', async (_req: Request, res: Response): Promise<void> => {
  try {
    const info  = whatsappService.getStatusInfo();
    const stats = await getMessageStats();
    res.json({
      success: true,
      data: {
        ...info,
        stats: {
          totalToday:  parseInt(stats.total_today  ?? '0', 10),
          sentToday:   parseInt(stats.sent_today   ?? '0', 10),
          failedToday: parseInt(stats.failed_today ?? '0', 10),
          lastSentAt:  stats.last_sent_at ?? null,
        },
      },
    });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : 'Internal error';
    res.status(500).json({ success: false, message: msg });
  }
});

// ── GET /whatsapp/qr ──────────────────────────────────────────────────────────

router.get('/qr', (_req: Request, res: Response): void => {
  const info = whatsappService.getStatusInfo();
  res.json({
    success: true,
    data: {
      status:    info.status,
      connected: info.connected,
      hasQr:     info.hasQr,
      qrData:    info.connected ? null : whatsappService.qrData,
      qrBase64:  info.connected ? null : whatsappService.qrBase64,
    },
  });
});

// ── GET /whatsapp/events (Server-Sent Events) ─────────────────────────────────
// Push state changes in real time. Falls back to polling if SSE is unavailable.

router.get('/events', (req: Request, res: Response): void => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no'); // disable Nginx/Render buffering
  res.flushHeaders();

  const sendEvent = (payload: WaStatusPayload): void => {
    try {
      res.write(`data: ${JSON.stringify(payload)}\n\n`);
    } catch { /* client already disconnected */ }
  };

  // Push current state immediately on connect
  sendEvent({
    ...whatsappService.getStatusInfo(),
    qrData:   whatsappService.qrData,
    qrBase64: whatsappService.qrBase64,
  });

  // Push every state change as it happens
  whatsappService.on('wa_status', sendEvent);

  // Keepalive comment every 25s — prevents Render/CDN from closing idle connections
  const heartbeat = setInterval(() => {
    try { res.write(': ping\n\n'); } catch { /* ignore */ }
  }, 25_000);

  req.on('close', () => {
    clearInterval(heartbeat);
    whatsappService.off('wa_status', sendEvent);
  });
});

// ── POST /whatsapp/reconnect ──────────────────────────────────────────────────

router.post('/reconnect', (_req: Request, res: Response): void => {
  // Always fire-and-forget — reconnect() handles any current state internally
  void whatsappService.reconnect();
  res.json({ success: true, message: 'Reconnect initiated' });
});

// ── POST /whatsapp/send-checkin ───────────────────────────────────────────────

router.post('/send-checkin', msgLimiter, validate('checkin'), async (req: Request, res: Response): Promise<void> => {
  try {
    const { phone, parentName, studentName, time } = req.body as Record<string, string>;
    const result = await sendMessage({
      phone, messageType: 'checkin', templateData: { parentName, studentName, time },
    });
    res.json({ success: true, data: result });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : 'Send failed';
    res.status(500).json({ success: false, message: msg });
  }
});

// ── POST /whatsapp/send-checkout ──────────────────────────────────────────────

router.post('/send-checkout', msgLimiter, validate('checkout'), async (req: Request, res: Response): Promise<void> => {
  try {
    const { phone, parentName, studentName, time } = req.body as Record<string, string>;
    const result = await sendMessage({
      phone, messageType: 'checkout', templateData: { parentName, studentName, time },
    });
    res.json({ success: true, data: result });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : 'Send failed';
    res.status(500).json({ success: false, message: msg });
  }
});

// ── POST /whatsapp/send-custom ────────────────────────────────────────────────

router.post('/send-custom', msgLimiter, validate('custom'), async (req: Request, res: Response): Promise<void> => {
  try {
    const { phone, message } = req.body as Record<string, string>;
    const result = await sendMessage({
      phone, messageType: 'custom', templateData: { message },
    });
    res.json({ success: true, data: result });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : 'Send failed';
    res.status(500).json({ success: false, message: msg });
  }
});

export default router;
