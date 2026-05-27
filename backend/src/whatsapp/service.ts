import { EventEmitter } from 'events';
import { Client, RemoteAuth } from 'whatsapp-web.js';
import type { WAState } from 'whatsapp-web.js';
import QRCode from 'qrcode';
import path from 'path';
import fs from 'fs';
import os from 'os';
import { query } from '../db/pool';
import { PostgresSessionStore } from './authStore';

// ── Types ─────────────────────────────────────────────────────────────────────

type WaState = 'initializing' | 'qr_pending' | 'connected' | 'disconnected' | 'reconnecting';

export interface WaStatusPayload {
  status:    string;
  connected: boolean;
  hasQr:     boolean;
  qrData:    string | null;
  qrBase64:  string | null;
  initError: string | null;
}

// ── Chrome detection ──────────────────────────────────────────────────────────
// Resolution order:
//   1. PUPPETEER_EXECUTABLE_PATH / CHROME_PATH env var
//   2. Common Linux system paths  (Debian/Ubuntu on Render)
//   3. PUPPETEER_CACHE_DIR env var
//   4. Project-local .puppeteer-browsers/  (written by postinstall)
//   5. .chrome-path sentinel file           (written by install-browsers.js)
//   6. Default ~/.cache/puppeteer
//
// Returns undefined → Puppeteer auto-detects (errors if still missing).

function findChrome(): string | undefined {
  for (const key of ['PUPPETEER_EXECUTABLE_PATH', 'CHROME_PATH']) {
    const p = process.env[key];
    if (p && fs.existsSync(p)) { console.log(`[wa] Chrome: ${key} → ${p}`); return p; }
  }

  const systemPaths = [
    '/usr/bin/google-chrome-stable', '/usr/bin/google-chrome',
    '/usr/bin/chromium-browser',     '/usr/bin/chromium',
    '/usr/local/bin/chromium',       '/usr/local/bin/google-chrome',
    '/snap/bin/chromium',
  ];
  for (const p of systemPaths) {
    if (fs.existsSync(p)) { console.log(`[wa] Chrome: system → ${p}`); return p; }
  }

  const cacheDirs = [
    process.env.PUPPETEER_CACHE_DIR,
    path.join(process.cwd(), '.puppeteer-browsers'),
    path.join(os.homedir(), '.cache', 'puppeteer'),
  ].filter(Boolean) as string[];

  for (const dir of cacheDirs) {
    if (!fs.existsSync(dir)) continue;
    const found = _walkForChrome(dir, 0);
    if (found) { console.log(`[wa] Chrome: cache → ${found}`); return found; }
  }

  try {
    const p = fs.readFileSync(path.join(process.cwd(), '.chrome-path'), 'utf8').trim();
    if (p && fs.existsSync(p)) { console.log(`[wa] Chrome: sentinel → ${p}`); return p; }
  } catch { /* not present */ }

  console.warn('[wa] Chrome not found in known paths — Puppeteer will auto-detect');
  return undefined;
}

function _walkForChrome(dir: string, depth: number): string | undefined {
  if (depth > 5) return undefined;
  let entries: fs.Dirent[];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch { return undefined; }

  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (!e.isDirectory() && ['chrome', 'google-chrome', 'chromium', 'chrome.exe'].includes(e.name)) {
      try { fs.accessSync(full, fs.constants.X_OK); return full; } catch { /* not exec */ }
    }
    if (e.isDirectory()) {
      const found = _walkForChrome(full, depth + 1);
      if (found) return found;
    }
  }
  return undefined;
}

// ── Puppeteer args ────────────────────────────────────────────────────────────
// --no-single-process: omitted intentionally — causes sandbox issues in containers
// --no-zygote: safe alone and prevents extra process overhead

const PUPPETEER_ARGS = [
  '--no-sandbox',
  '--disable-setuid-sandbox',
  '--disable-dev-shm-usage',           // use /tmp, avoids SIGBUS in Docker/Render
  '--disable-accelerated-2d-canvas',
  '--no-first-run',
  '--no-zygote',
  '--disable-gpu',
  '--disable-extensions',
  '--disable-background-networking',
  '--disable-default-apps',
  '--disable-sync',
  '--disable-translate',
  '--mute-audio',
  '--disable-features=TranslateUI',
  '--disable-ipc-flooding-protection',
  '--disable-backgrounding-occluded-windows',
  '--disable-renderer-backgrounding',
  '--disable-client-side-phishing-detection',
  '--safebrowsing-disable-auto-update',
  '--metrics-recording-only',
  '--no-default-browser-check',
  '--window-size=1280,720',
];

// ── WhatsApp Service ──────────────────────────────────────────────────────────

class WhatsAppService extends EventEmitter {
  private _client: Client | null                                = null;
  private _state: WaState                                       = 'initializing';
  private _qrData: string | null                                = null;
  private _qrBase64: string | null                              = null;
  private _lastConnectedAt: Date | null                         = null;
  private _initError: string | null                             = null;

  // ── Concurrency guards ────────────────────────────────────────────────────
  // _initPromise  → prevents duplicate initialize() calls
  // _isReconnecting → prevents concurrent reconnect() calls (race condition)
  private _initPromise: Promise<void> | null                    = null;
  private _isReconnecting                                       = false;

  private _reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private _reconnectAttempts                                    = 0;

  // ── Getters ───────────────────────────────────────────────────────────────

  get state(): WaState               { return this._state; }
  get qrData(): string | null        { return this._qrData; }
  get qrBase64(): string | null      { return this._qrBase64; }
  get isConnected(): boolean         { return this._state === 'connected'; }
  get lastConnectedAt(): Date | null { return this._lastConnectedAt; }
  get initError(): string | null     { return this._initError; }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /** Safe to call multiple times — only one boot runs at a time. */
  initialize(): Promise<void> {
    if (this._initPromise) return this._initPromise;
    this._initPromise = this._boot();
    return this._initPromise;
  }

  private _setState(state: WaState): void {
    this._state = state;
    this.emit('wa_status', this._buildPayload());
  }

  private _buildPayload(): WaStatusPayload {
    return {
      status:    this._state,
      connected: this._state === 'connected',
      hasQr:     this._state === 'qr_pending' && !!this._qrData,
      qrData:    this._qrData,
      qrBase64:  this._qrBase64,
      initError: this._initError,
    };
  }

  private async _boot(): Promise<void> {
    console.log('[wa] ── Booting ─────────────────────────────────────────');
    this._setState('initializing');
    this._initError = null;

    const clientId   = process.env.WA_CLIENT_ID ?? 'eduscan-wa';
    const executablePath = findChrome();
    if (executablePath) console.log('[wa] Using Chrome:', executablePath);

    this._client = new Client({
      authStrategy: new RemoteAuth({
        clientId,
        store: new PostgresSessionStore(),
        backupSyncIntervalMs: 5 * 60 * 1000,   // back up to DB every 5 minutes
        dataPath: path.join(process.cwd(), '.wwebjs_auth'), // local temp path
      }),
      puppeteer: {
        headless: true,
        timeout:  0,   // Render cold-starts can be >60 s
        args: PUPPETEER_ARGS,
        ...(executablePath ? { executablePath } : {}),
      },
    });

    this._client.on('loading_screen', (percent: number, message: string) => {
      console.log(`[wa] Loading: ${percent}% — ${message}`);
    });

    // wwebjs re-fires `qr` every ~60 s when the QR expires — no manual timer needed.
    // With RemoteAuth: this event fires ONLY when no saved session exists in the DB.
    this._client.on('qr', async (qr: string) => {
      console.log('[wa] QR ready — expires in ~60 s (scan with WhatsApp)');
      this._qrData   = qr;
      this._qrBase64 = null;
      try { this._qrBase64 = await QRCode.toDataURL(qr, { scale: 8, margin: 2 }); }
      catch { /* non-fatal */ }
      this._setState('qr_pending');
      void this._logEvent('qr_generated');
    });

    this._client.on('authenticated', () => {
      console.log('[wa] Authenticated ✔');
      this._reconnectAttempts = 0;
      this._initError         = null;
    });

    this._client.on('ready', async () => {
      console.log('[wa] Ready ✔ — session active, messages can be sent');
      this._qrData            = null;
      this._qrBase64          = null;
      this._lastConnectedAt   = new Date();
      this._initError         = null;
      this._reconnectAttempts = 0;
      this._setState('connected');
      void this._logEvent('connected');
    });

    // RemoteAuth fires `remote_session_saved` after each backup
    this._client.on('remote_session_saved', () => {
      console.log('[wa] Session backed up to PostgreSQL ✔');
    });

    this._client.on('auth_failure', async (msg: string) => {
      console.error('[wa] Auth failure:', msg);
      this._initError = `Auth failure: ${msg}`;
      this._qrData    = null;
      this._qrBase64  = null;
      this._setState('disconnected');
      void this._logEvent('auth_failure', { message: msg });
      this._scheduleReconnect();
    });

    this._client.on('disconnected', async (reason: WAState | 'LOGOUT') => {
      console.warn('[wa] Disconnected:', reason);
      this._qrData   = null;
      this._qrBase64 = null;
      this._setState('disconnected');
      void this._logEvent('disconnected', { reason });
      // LOGOUT = user delinked the device — do not auto-reconnect into a QR loop
      if (reason !== 'LOGOUT') this._scheduleReconnect();
    });

    try {
      await this._client.initialize();
    } catch (err: unknown) {
      const raw = err instanceof Error ? err.message : String(err);
      console.error('[wa] Init error:', raw);
      this._initError   = _friendlyInitError(raw);
      this._setState('disconnected');
      this._initPromise = null;
      this._scheduleReconnect();
    }
  }

  // Exponential backoff: 10 s → 15 s → 22 s → 34 s → max 120 s
  private _scheduleReconnect(): void {
    if (this._reconnectTimer) clearTimeout(this._reconnectTimer);
    const delay = Math.min(10_000 * Math.pow(1.5, this._reconnectAttempts), 120_000);
    this._reconnectAttempts++;
    console.log(`[wa] Auto-reconnect in ${Math.round(delay / 1000)} s (attempt #${this._reconnectAttempts})`);
    this._reconnectTimer = setTimeout(() => void this._doReconnect(), delay);
  }

  private async _doReconnect(): Promise<void> {
    if (this._state === 'connected') return;
    console.log('[wa] Auto-reconnecting...');
    await this._destroyClient();
    this._initPromise = null;
    await this.initialize();
  }

  /** Removes all listeners before destroying — prevents EventEmitter memory leaks. */
  private async _destroyClient(): Promise<void> {
    if (!this._client) return;
    try {
      this._client.removeAllListeners();
      await this._client.destroy();
    } catch { /* browser may already be gone */ }
    this._client = null;
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /**
   * Force a full restart.
   * Protected by _isReconnecting to prevent concurrent calls
   * (e.g. user spamming the Reconnect button) from launching two Chrome instances.
   */
  async reconnect(): Promise<void> {
    // Already reconnecting — ignore duplicate call
    if (this._isReconnecting) {
      console.log('[wa] reconnect() ignored — already in progress');
      return;
    }
    // Already connected — nothing to do (session is alive in DB)
    if (this._state === 'connected') {
      console.log('[wa] reconnect() ignored — already connected');
      return;
    }

    this._isReconnecting = true;
    console.log('[wa] Manual reconnect triggered');

    try {
      if (this._reconnectTimer) clearTimeout(this._reconnectTimer);
      this._reconnectTimer    = null;
      this._reconnectAttempts = 0;   // manual reconnect resets backoff
      this._initPromise       = null;
      this._qrData            = null;
      this._qrBase64          = null;
      this._initError         = null;
      this._setState('reconnecting');
      await this._destroyClient();
      await this.initialize();
    } finally {
      this._isReconnecting = false;
    }
  }

  async sendMessage(waId: string, text: string): Promise<void> {
    if (!this.isConnected || !this._client) {
      throw new Error(`WhatsApp not connected (state: ${this._state})`);
    }
    await this._client.sendMessage(waId, text);
    console.log(`[wa] Sent → ${waId}`);
  }

  getStatusInfo() {
    return {
      status:          this._state as string,
      connected:       this.isConnected,
      lastConnectedAt: this._lastConnectedAt,
      hasQr:           this._state === 'qr_pending' && !!this._qrData,
      initError:       this._initError,
    };
  }

  private async _logEvent(eventType: string, info: object = {}): Promise<void> {
    try {
      await query(
        'INSERT INTO whatsapp_sessions (event_type, session_info) VALUES ($1, $2)',
        [eventType, JSON.stringify(info)],
      );
    } catch { /* non-fatal */ }
  }
}

function _friendlyInitError(raw: string): string {
  if (raw.includes('Could not find Chrome') || raw.includes('No usable sandbox')) {
    return 'Chromium not found — check PUPPETEER_CACHE_DIR or PUPPETEER_EXECUTABLE_PATH';
  }
  if (raw.includes('ECONNREFUSED') || raw.includes('ERR_CONNECTION_REFUSED')) {
    return 'Cannot connect to WhatsApp — check server internet connectivity';
  }
  if (raw.includes('TimeoutError') || raw.includes('Navigation timeout')) {
    return 'WhatsApp Web failed to load — Chromium startup is slow or blocked';
  }
  if (raw.includes('ENOMEM') || raw.includes('out of memory')) {
    return 'Out of memory — server needs more RAM to run Chromium';
  }
  if (raw.includes('SIGKILL') || raw.includes('Target closed')) {
    return 'Chromium was killed — likely OOM or container memory limit';
  }
  return raw.length > 300 ? raw.substring(0, 300) + '…' : raw;
}

export const whatsappService = new WhatsAppService();
