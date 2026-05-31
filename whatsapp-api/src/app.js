/**
 * EduScan WhatsApp Module
 *
 * This file exports the Express Router and an init() function.
 * It does NOT start a server — it integrates into your existing Express app.
 *
 * Integration (add to your existing app.js / server.js):
 *
 *   const { router: waRouter, init: initWhatsApp } = require('./src/whatsapp');
 *   await initWhatsApp();
 *   app.use('/whatsapp', yourExistingAuthMiddleware, waRouter);
 *
 * See INTEGRATION.md for full setup guide.
 */

const logger           = require('./utils/logger');
const { runMigrations } = require('./db/migrations');
const whatsappService  = require('./services/whatsappService');
const apiRoutes        = require('./routes/index');

// ── Router export ─────────────────────────────────────────────────────────────
const router = require('express').Router();
router.use(apiRoutes);

// ── init() — call once during your server bootstrap ──────────────────────────
let _initialized = false;

async function init() {
  if (_initialized) return;
  _initialized = true;

  try {
    await runMigrations();
    logger.info('[wa-module] Database tables ready');
  } catch (err) {
    logger.error('[wa-module] Migration error:', err.message);
    throw err; // Fail fast so the caller knows something is wrong
  }

  // WhatsApp client starts non-blocking; failures don't crash the host server
  whatsappService.initialize().catch((err) =>
    logger.error('[wa-module] WhatsApp init error:', err.message)
  );

  logger.info('[wa-module] WhatsApp module ready');
}

module.exports = { router, init };
