const rateLimit = require('express-rate-limit');
const logger = require('../utils/logger');

const messageLimiter = rateLimit({
  windowMs: parseInt(process.env.WA_RATE_LIMIT_WINDOW_MS ?? '60000', 10),
  max:      parseInt(process.env.WA_RATE_LIMIT_MAX ?? '30', 10),
  standardHeaders: true,
  legacyHeaders:   false,
  handler(req, res) {
    logger.warn(`[rate-limit] Exceeded — ${req.ip}`);
    res.status(429).json({ success: false, message: 'Too many requests — slow down.' });
  },
});

module.exports = { messageLimiter };
