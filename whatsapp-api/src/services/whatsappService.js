const { Client, LocalAuth } = require('whatsapp-web.js');
const qrcode = require('qrcode');
const path = require('path');
const logger = require('../utils/logger');
const { query } = require('../config/database');

const STATE = {
  INITIALIZING: 'initializing',
  QR_PENDING:   'qr_pending',
  CONNECTED:    'connected',
  DISCONNECTED: 'disconnected',
  RECONNECTING: 'reconnecting',
};

class WhatsAppService {
  constructor() {
    this._client             = null;
    this._state              = STATE.INITIALIZING;
    this._qrData             = null;   // Raw QR string (for qr_flutter)
    this._qrBase64           = null;   // Base64 PNG (fallback)
    this._lastConnectedAt    = null;
    this._initPromise        = null;
    this._reconnectTimeout   = null;
  }

  // ── Public getters ──────────────────────────────────────────────────────

  get state()           { return this._state; }
  get qrData()          { return this._qrData; }
  get qrBase64()        { return this._qrBase64; }
  get isConnected()     { return this._state === STATE.CONNECTED; }
  get lastConnectedAt() { return this._lastConnectedAt; }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  async initialize() {
    if (this._initPromise) return this._initPromise;
    this._initPromise = this._boot();
    return this._initPromise;
  }

  async _boot() {
    logger.info('WhatsApp client starting...');
    this._state = STATE.INITIALIZING;

    const sessionPath = process.env.WA_SESSION_PATH
      || path.join(process.cwd(), '.wwebjs_auth');
    const clientId = process.env.WA_CLIENT_ID || 'eduscan-wa';

    this._client = new Client({
      authStrategy: new LocalAuth({ clientId, dataPath: sessionPath }),
      puppeteer: {
        headless: true,
        args: [
          '--no-sandbox',
          '--disable-setuid-sandbox',
          '--disable-dev-shm-usage',
          '--disable-accelerated-2d-canvas',
          '--no-first-run',
          '--no-zygote',
          '--single-process',
          '--disable-gpu',
          '--disable-extensions',
        ],
      },
    });

    this._client.on('qr', async (qr) => {
      logger.info('QR code ready — open the app to scan');
      this._state   = STATE.QR_PENDING;
      this._qrData  = qr;
      try {
        this._qrBase64 = await qrcode.toDataURL(qr);
      } catch (err) {
        logger.warn('QR→base64 conversion failed:', err.message);
      }
      await this._logEvent('qr_generated');
    });

    this._client.on('authenticated', () => {
      logger.info('WhatsApp authenticated');
    });

    this._client.on('ready', async () => {
      logger.info('WhatsApp ready ✔');
      this._state           = STATE.CONNECTED;
      this._qrData          = null;
      this._qrBase64        = null;
      this._lastConnectedAt = new Date();
      await this._logEvent('connected');
    });

    this._client.on('auth_failure', async (msg) => {
      logger.error('WhatsApp auth failure:', msg);
      this._state = STATE.DISCONNECTED;
      await this._logEvent('auth_failure', { message: msg });
    });

    this._client.on('disconnected', async (reason) => {
      logger.warn('WhatsApp disconnected:', reason);
      this._state    = STATE.DISCONNECTED;
      this._qrData   = null;
      this._qrBase64 = null;
      await this._logEvent('disconnected', { reason });
      this._scheduleReconnect(10_000);
    });

    try {
      await this._client.initialize();
    } catch (err) {
      logger.error('WhatsApp init error:', err.message);
      this._state       = STATE.DISCONNECTED;
      this._initPromise = null;
      this._scheduleReconnect(15_000);
    }
  }

  _scheduleReconnect(delayMs) {
    if (this._reconnectTimeout) clearTimeout(this._reconnectTimeout);
    this._reconnectTimeout = setTimeout(() => this._reconnect(), delayMs);
  }

  async _reconnect() {
    if (this._state === STATE.CONNECTED) return;
    logger.info('WhatsApp reconnecting...');
    this._state       = STATE.RECONNECTING;
    this._initPromise = null;
    try {
      await this._client?.destroy();
    } catch (_) {}
    this._client = null;
    await this.initialize();
  }

  // ── Messaging ───────────────────────────────────────────────────────────

  async sendMessage(waId, text) {
    if (!this.isConnected || !this._client) {
      throw new Error(`WhatsApp not connected (state: ${this._state})`);
    }
    const result = await this._client.sendMessage(waId, text);
    logger.info(`Sent to ${waId}: "${text.substring(0, 60)}…"`);
    return result;
  }

  // ── Status ──────────────────────────────────────────────────────────────

  getStatusInfo() {
    return {
      status:          this._state,
      connected:       this.isConnected,
      lastConnectedAt: this._lastConnectedAt,
      hasQr:           !!this._qrData,
    };
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  async _logEvent(eventType, info = {}) {
    try {
      await query(
        'INSERT INTO whatsapp_sessions (event_type, session_info) VALUES ($1, $2)',
        [eventType, JSON.stringify(info)]
      );
    } catch (err) {
      logger.warn('Session event log failed:', err.message);
    }
  }
}

module.exports = new WhatsAppService(); // singleton
