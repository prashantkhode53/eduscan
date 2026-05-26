import { Client, LocalAuth } from 'whatsapp-web.js';
import type { WAState } from 'whatsapp-web.js';
import QRCode from 'qrcode';
import path from 'path';
import { query } from '../db/pool';

type WaState = 'initializing' | 'qr_pending' | 'connected' | 'disconnected' | 'reconnecting';

class WhatsAppService {
  private _client: Client | null         = null;
  private _state: WaState                = 'initializing';
  private _qrData: string | null         = null;
  private _qrBase64: string | null       = null;
  private _lastConnectedAt: Date | null  = null;
  private _initPromise: Promise<void> | null = null;
  private _reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  // ── Public getters ──────────────────────────────────────────────────────

  get state(): WaState               { return this._state; }
  get qrData(): string | null        { return this._qrData; }
  get qrBase64(): string | null      { return this._qrBase64; }
  get isConnected(): boolean         { return this._state === 'connected'; }
  get lastConnectedAt(): Date | null { return this._lastConnectedAt; }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  initialize(): Promise<void> {
    if (this._initPromise) return this._initPromise;
    this._initPromise = this._boot();
    return this._initPromise;
  }

  private async _boot(): Promise<void> {
    console.log('[wa] Starting WhatsApp client...');
    this._state = 'initializing';

    const sessionPath = process.env.WA_SESSION_PATH
      ?? path.join(process.cwd(), '.wwebjs_auth');
    const clientId = process.env.WA_CLIENT_ID ?? 'eduscan-wa';

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

    this._client.on('qr', async (qr: string) => {
      console.log('[wa] QR ready — open the app to scan');
      this._state  = 'qr_pending';
      this._qrData = qr;
      try { this._qrBase64 = await QRCode.toDataURL(qr); }
      catch { /* non-fatal */ }
      await this._logEvent('qr_generated');
    });

    this._client.on('authenticated', () => {
      console.log('[wa] Authenticated');
    });

    this._client.on('ready', async () => {
      console.log('[wa] Ready ✔');
      this._state           = 'connected';
      this._qrData          = null;
      this._qrBase64        = null;
      this._lastConnectedAt = new Date();
      await this._logEvent('connected');
    });

    this._client.on('auth_failure', async (msg: string) => {
      console.error('[wa] Auth failure:', msg);
      this._state = 'disconnected';
      await this._logEvent('auth_failure', { message: msg });
    });

    this._client.on('disconnected', async (reason: WAState | 'LOGOUT') => {
      console.warn('[wa] Disconnected:', reason);
      this._state    = 'disconnected';
      this._qrData   = null;
      this._qrBase64 = null;
      await this._logEvent('disconnected', { reason });
      this._scheduleReconnect(10_000);
    });

    try {
      await this._client.initialize();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error('[wa] Init error:', msg);
      this._state       = 'disconnected';
      this._initPromise = null;
      this._scheduleReconnect(15_000);
    }
  }

  private _scheduleReconnect(delayMs: number): void {
    if (this._reconnectTimer) clearTimeout(this._reconnectTimer);
    this._reconnectTimer = setTimeout(() => void this._reconnect(), delayMs);
  }

  private async _reconnect(): Promise<void> {
    if (this._state === 'connected') return;
    console.log('[wa] Reconnecting...');
    this._state       = 'reconnecting';
    this._initPromise = null;
    try { await this._client?.destroy(); } catch { /* ignore */ }
    this._client = null;
    await this.initialize();
  }

  // ── Messaging ───────────────────────────────────────────────────────────

  async reconnect(): Promise<void> {
    if (this._state === 'connected') return;
    await this._reconnect();
  }

  async sendMessage(waId: string, text: string): Promise<void> {
    if (!this.isConnected || !this._client) {
      throw new Error(`WhatsApp not connected (state: ${this._state})`);
    }
    await this._client.sendMessage(waId, text);
    console.log(`[wa] Sent to ${waId}`);
  }

  // ── Status ──────────────────────────────────────────────────────────────

  getStatusInfo() {
    return {
      status:          this._state as string,
      connected:       this.isConnected,
      lastConnectedAt: this._lastConnectedAt,
      hasQr:           !!this._qrData,
    };
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  private async _logEvent(eventType: string, info: object = {}): Promise<void> {
    try {
      await query(
        'INSERT INTO whatsapp_sessions (event_type, session_info) VALUES ($1, $2)',
        [eventType, JSON.stringify(info)]
      );
    } catch { /* non-fatal */ }
  }
}

export const whatsappService = new WhatsAppService();
