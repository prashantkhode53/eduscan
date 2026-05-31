const logger = require('../utils/logger');

/**
 * WhatsApp auth middleware.
 *
 * Priority:
 * 1. If upstream middleware (e.g. your existing JWT middleware) has already set
 *    req.user or req.admin, treat the request as authenticated.
 * 2. Otherwise fall back to X-API-Key check using WA_API_KEY env var.
 * 3. If WA_API_KEY is not set, skip this check and rely entirely on upstream auth.
 *
 * Recommended integration:
 *   app.use('/whatsapp', yourExistingAuthMiddleware, waRouter);
 * — in that case this middleware is a no-op because req.user is already set.
 */
function whatsappAuth(req, res, next) {
  // Already authenticated by upstream middleware
  if (req.user || req.admin) return next();

  // Optional standalone API key (useful for testing or non-JWT callers)
  const waKey = process.env.WA_API_KEY;
  if (waKey) {
    const provided = req.headers['x-api-key'];
    if (provided === waKey) return next();
    logger.warn(`[wa-auth] Invalid/missing API key — ${req.ip}`);
    return res.status(403).json({ success: false, message: 'Forbidden' });
  }

  // WA_API_KEY not set → assume upstream auth is handling security
  next();
}

module.exports = { whatsappAuth };
