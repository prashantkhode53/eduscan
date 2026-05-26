import { EventEmitter } from 'events';
import { Client, LocalAuth } from 'whatsapp-web.js';
import type { WAState } from 'whatsapp-web.js';
import QRCode from 'qrcode';
import path from 'path';
import { query } from '../db/pool';

type WaState = 'initializing' | 'qr_pending' | 'connected' | 'disconnected' | 'reconnecting';

export interface WaStatusPayload {
  status:    string;
  connected: boolean;
  hasQr:     boolean;
  qrData:    string | null;
  qrBase64:  string | null;
  initError: string | null;
}

class WhatsAppService extends EventEmitter {
  private _client: Client | null              = null;
  private _state: WaState                     = 'initializing';
  private _qrData: string | null              = null;
  private _qrBase64: string | null            = null;
  private _lastConnectedAt: Date | null       = null;
  private _initPromise: Promise<void> | null  = null;
  private _reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private _initError: string | null           = null;

  // ── Public getters ──────────────────────────────────────────────────────

  get state(): WaState               { return this._state; }
  get qrData(): string | null        { return this._qrData; }
  get qrBase64(): string | null      { return this._qrBase64; }
  get isConnected(): boolean         { return this._state === 'connected'; }
  get lastConnectedAt(): Date | null { return this._lastConnectedAt; }
  get initError(): string | null     { return this._initError; }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  initialize(): Promise<void> {
    if (this._initPromise) return this._initPromise;
    this._initPromise = this._boot();
    return this._initPromise;
  }

  private _setState(state: WaState): void {
    this._state = state;
    this._pushEvent();
  }

  private _pushEvent(): void {
    this.emit('wa_status', this._buildPayload());
  }

  private _buildPayload(): WaStatusPayload {
    return {
      status:    this._state,
      connected: this._state === 'connected',
      hasQr:     !!this._qrData,
      qrData:    this._qrData,
      qrBase64:  this._qrBase64,
      initError: this._initError,
    };
  }

  private async _boot(): Promise<void> {
    console.log('[wa] Starting WhatsApp client...');
    this._setState('initializing');
    this._initError = null;

    const sessionPath = process.env.WA_SESSION_PATH
      ?? path.join(process.cwd(), '.wwebjs_auth');
    const clientId = process.env.WA_CLIENT_ID ?? 'eduscan-wa';

    const launchArgs: Record<string, unknown> = {
      headless: true,
      timeout:  0,          // no timeout — Render cold-starts can be slow
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-dev-shm-usage',
        '--disable-accelerated-2d-canvas',
        '--no-first-run',
        '--no-zygote',      // do not combine with --single-process
        '--disable-gpu',
        '--disable-extensions',
        '--disable-background-networking',
        '--disable-default-apps',
        '--mute-audio',
      ],
    };

    // Allow overriding the Chromium binary path via env var
    const executablePath = process.env.PUPPETEER_EXECUTABLE_PATH
      ?? process.env.CHROME_PATH;
    if (executablePath) {
      launchArgs.executablePath = executablePath;
      console.log(`[wa] Using Chromium at: ${executablePath}`);
    }

    this._client = new Client({
      authStrategy: new LocalAuth({ clientId, dataPath: sessionPath }),
      puppeteer: launchArgs,
    });

    this._client.on('qr', async (qr: string) => {
      console.log('[wa] QR ready — open the app to scan');
      this._qrData   = qr;
      this._qrBase64 = null;
      try { this._qrBase64 = await QRCode.toDataURL(qr); }
      catch { /* non-fatal */ }
      this._setState('qr_pending');
      await this._logEvent('qr_generated');
    });

    this._client.on('authenticated', () => {
      console.log('[wa] Authenticated');
      this._initError = null;
    });

    this._client.on('ready', async () => {
      console.log('[wa] Ready ✔');
      this._qrData          = null;
      this._qrBase64        = null;
      this._lastConnectedAt = new Date();
      this._initError       = null;
      this._setState('connected');
      await this._logEvent('connected');
    });

    this._client.on('auth_failure', async (msg: string) => {
      console.error('[wa] Auth failure:', msg);
      this._initError = `Auth failure: ${msg}`;
      this._qrData    = null;
      this._qrBase64  = null;
      this._setState('disconnected');
      await this._logEvent('auth_failure', { message: msg });
    });

    this._client.on('disconnected', async (reason: WAState | 'LOGOUT') => {
      console.warn('[wa] Disconnected:', reason);
      this._qrData   = null;
      this._qrBase64 = null;
      this._setState('disconnected');
      await this._logEvent('disconnected', { reason });
      this._scheduleReconnect(10_000);
    });

    try {
      await this._client.initialize();
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error('[wa] Init error:', msg);
      this._initError   = msg;
      this._setState('disconnected');
      this._initPromise = null;
      this._scheduleReconnect(15_000);
    }
  }

  private _scheduleReconnect(delayMs: number): void {
    if (this._reconnectTimer) clearTimeout(this._reconnectTimer);
    this._reconnectTimer = setTimeout(() => void this._doReconnect(), delayMs);
  }

  private async _doReconnect(): Promise<void> {
    if (this._state === 'connected') return;
    console.log('[wa] Auto-reconnecting...');
    this._initPromise = null;
    try { await this._client?.destroy(); } catch { /* ignore */ }
    this._client = null;
    await this.initialize();
  }

  // ── Public actions ────────────────────────────────────────────────────────

  /** Force a full restart from any state — clears timers, destroys client, reinitializes. */
  async reconnect(): Promise<void> {
    console.log('[wa] Manual reconnect triggered');
    if (this._reconnectTimer) clearTimeout(this._reconnectTimer);
    this._reconnectTimer = null;
    this._initPromise    = null;
    this._qrData         = null;
    this._qrBase64       = null;
    this._initError      = null;
    this._setState('reconnecting');
    try { await this._client?.destroy(); } catch { /* ignore */ }
    this._client = null;
    await this.initialize();
  }

  async sendMessage(waId: string, text: string): Promise<void> {
    if (!this.isConnected || !this._client) {
      throw new Error(`WhatsApp not connected (state: ${this._state})`);
    }
    await this._client.sendMessage(waId, text);
    console.log(`[wa] Sent to ${waId}`);
  }

  // ── Status ────────────────────────────────────────────────────────────────

  getStatusInfo() {
    return {
      status:          this._state as string,
      connected:       this.isConnected,
      lastConnectedAt: this._lastConnectedAt,
      hasQr:           !!this._qrData,
      initError:       this._initError,
    };
  }

  // ── Internal ──────────────────────────────────────────────────────────────

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
