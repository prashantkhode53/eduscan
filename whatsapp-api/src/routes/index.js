const { Router } = require('express');
const { sendCheckin, sendCheckout, sendCustom } = require('../controllers/messageController');
const { getQrCode, getWhatsappStatus }          = require('../controllers/statusController');
const { whatsappAuth }                          = require('../middleware/auth');
const { messageLimiter }                        = require('../middleware/rateLimiter');
const { validate }                              = require('../middleware/validator');

const router = Router();

router.use(whatsappAuth);

// ── Message routes ────────────────────────────────────────────────────────────
router.post('/send-checkin',  messageLimiter, validate('sendCheckin'),  sendCheckin);
router.post('/send-checkout', messageLimiter, validate('sendCheckout'), sendCheckout);
router.post('/send-custom',   messageLimiter, validate('sendCustom'),   sendCustom);

// ── Status routes ─────────────────────────────────────────────────────────────
router.get('/status', getWhatsappStatus);
router.get('/qr',     getQrCode);

module.exports = router;
