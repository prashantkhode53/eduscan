import { EventEmitter } from 'events';
import { Client, LocalAuth } from 'whatsapp-web.js';
import type { WAState } from 'whatsapp-web.js';
import QRCode from 'qrcode';
import path from 'path';
import fs from 'fs';
import os from 'os';
import { query } from '../db/pool';

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
//   2. Common Linux system paths (Debian/Ubuntu on Render)
//   3. PUPPETEER_CACHE_DIR env var
//   4. Project-local .puppeteer-browsers/ (written by install-browsers.js)
//   5. Project-local .chrome-path sentinel file (also written by installer)
//   6. Default ~/.cache/puppeteer
//   Returns undefined → Puppeteer will auto-detect (errors if still missing)

function findChrome(): string | undefined {
  // 1. Explicit env overrides
  for (const key of ['PUPPETEER_EXECUTABLE_PATH', 'CHROME_PATH']) {
    const p = process.env[key];
    if (p && fs.existsSync(p)) {
      console.log(`[wa] Chrome: ${key} → ${p}`);
      return p;
    }
  }

  // 2. Common Linux system Chrome/Chromium paths
  const systemPaths = [
    '/usr/bin/google-chrome-stable',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium-browser',
    '/usr/bin/chromium',
    '/usr/local/bin/chromium',
    '/usr/local/bin/google-chrome',
    '/snap/bin/chromium',
  ];
  for (const p of systemPaths) {
    if (fs.existsSync(p)) {
      console.log(`[wa] Chrome: system → ${p}`);
      return p;
    }
  }

  // 3–6. Search Puppeteer cache directories
  const cacheDirs = [
    process.env.PUPPETEER_CACHE_DIR,
    path.join(process.cwd(), '.puppeteer-browsers'),
    path.join(os.homedir(), '.cache', 'puppeteer'),
  ].filter(Boolean) as string[];

  for (const dir of cacheDirs) {
    if (!fs.existsSync(dir)) continue;
    const found = _walkForChrome(dir, 0);
    if (found) {
      console.log(`[wa] Chrome: cache ${dir} → ${found}`);
      return found;
    }
  }

  // Sentinel file written by install-browsers.js
  const sentinelFile = path.join(process.cwd(), '.chrome-path');
  try {
    const p = fs.readFileSync(sentinelFile, 'utf8').trim();
    if (p && fs.existsSync(p)) {
      console.log(`[wa] Chrome: sentinel file → ${p}`);
      return p;
    }
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
      try { fs.accessSync(full, fs.constants.X_OK); return full; } catch { /* not executable */ }
    }
    if (e.isDirectory()) {
      const found = _walkForChrome(full, depth + 1);
      if (found) return found;
    }
  }
  return undefined;
}

// ── Puppeteer args ────────────────────────────────────────────────────────────
// No --single-process: it disables the process sandbox and causes crashes in containers.
// --no-zygote is safe alone and prevents zygote process overhead.

const PUPPETEER_ARGS = [
  '--no-sandbox',
  '--disable-setuid-sandbox',
  '--disable-dev-shm-usage',           // use /tmp instead of /dev/shm (avoids SIGBUS in containers)
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

// ── WhatsAppService ───────────────────────────────────────────────────────────

class WhatsAppService extends EventEmitter {
  private _client: Client | null                                    = null;
  private _state: WaState                                           = 'initializing';
  private _qrData: string | null                                    = null;
  private _qrBase64: string | null                                  = null;
  private _lastConnectedAt: Date | null                             = null;
  private _initPromise: Promise<void> | null                        = null;
  private _reconnectTimer: ReturnType<typeof setTimeout> | null     = null;
  private _initError: string | null                                 = null;
  private _reconnectAttempts                                        = 0;

  // ── Getters ──────────────────────────────────────────────────────────────────

  get state(): WaState               { return this._state; }
  get qrData(): string | null        { return this._qrData; }
  get qrBase64(): string | null      { return this._qrBase64; }
  get isConnected(): boolean         { return this._state === 'connected'; }
  get lastConnectedAt(): Date | null { return this._lastConnectedAt; }
  get initError(): string | null     { return this._initError; }

  // ── Lifecycle ─────────────────────────────────────────────────────────────────

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
      hasQr:     this._state === 'qr_pending' && !!this._qrData,
      qrData:    this._qrData,
      qrBase64:  this._qrBase64,
      initError: this._initError,
    };
  }

  private async _boot(): Promise<void> {
    console.log('[wa] ── Booting WhatsApp client ──────────────────────');
    this._setState('initializing');
    this._initError = null;

    const sessionPath = process.env.WA_SESSION_PATH
      ?? path.join(process.cwd(), '.wwebjs_auth');
    const clientId = process.env.WA_CLIENT_ID ?? 'eduscan-wa';

    const executablePath = findChrome();
    if (executablePath) {
      console.log('[wa] Using Chrome:', executablePath);
    } else {
      console.log('[wa] Chrome path not resolved — Puppeteer will use its default');
    }

    this._client = new Client({
      authStrategy: new LocalAuth({ clientId, dataPath: sessionPath }),
      puppeteer: {
        headless: true,
        timeout:  0,  // no timeout — Render cold-starts can be >60s
        args: PUPPETEER_ARGS,
        ...(executablePath ? { executablePath } : {}),
      },
    });

    this._client.on('loading_screen', (percent: number, message: string) => {
      console.log(`[wa] Loading WhatsApp Web: ${percent}% — ${message}`);
    });

    this._client.on('qr', async (qr: string) => {
      // whatsapp-web.js re-fires this event every ~60s when QR expires — no manual timer needed
      console.log('[wa] QR ready — expires in ~60s');
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
      console.log('[wa] Ready ✔ — WhatsApp connected');
      this._qrData            = null;
      this._qrBase64          = null;
      this._lastConnectedAt   = new Date();
      this._initError         = null;
      this._reconnectAttempts = 0;
      this._setState('connected');
      void this._logEvent('connected');
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
      // LOGOUT = user explicitly delinked — don't auto-reconnect
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

  // Exponential backoff: 10s → 15s → 22s → 34s → max 120s
  private _scheduleReconnect(): void {
    if (this._reconnectTimer) clearTimeout(this._reconnectTimer);
    const delay = Math.min(10_000 * Math.pow(1.5, this._reconnectAttempts), 120_000);
    this._reconnectAttempts++;
    console.log(`[wa] Auto-reconnect in ${Math.round(delay / 1000)}s (attempt #${this._reconnectAttempts})`);
    this._reconnectTimer = setTimeout(() => void this._doReconnect(), delay);
  }

  private async _doReconnect(): Promise<void> {
    if (this._state === 'connected') return;
    console.log('[wa] Auto-reconnecting...');
    await this._destroyClient();
    this._initPromise = null;
    await this.initialize();
  }

  // Removes all listeners before destroying to prevent memory leaks
  private async _destroyClient(): Promise<void> {
    if (!this._client) return;
    try {
      this._client.removeAllListeners();
      await this._client.destroy();
    } catch { /* browser may already be gone */ }
    this._client = null;
  }

  // ── Public API ────────────────────────────────────────────────────────────────

  /** Force a full restart from any state. Resets backoff counter. */
  async reconnect(): Promise<void> {
    console.log('[wa] Manual reconnect triggered');
    if (this._reconnectTimer) clearTimeout(this._reconnectTimer);
    this._reconnectTimer    = null;
    this._reconnectAttempts = 0;        // reset backoff on manual reconnect
    this._initPromise       = null;
    this._qrData            = null;
    this._qrBase64          = null;
    this._initError         = null;
    this._setState('reconnecting');
    await this._destroyClient();
    await this.initialize();
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

// Translate raw Puppeteer/Chrome error strings into user-friendly messages
function _friendlyInitError(raw: string): string {
  if (raw.includes('Could not find Chrome') || raw.includes('No usable sandbox') || raw.includes('ERR_LAUNCH_ARG')) {
    return 'Chromium not found — set PUPPETEER_CACHE_DIR or PUPPETEER_EXECUTABLE_PATH';
  }
  if (raw.includes('ECONNREFUSED') || raw.includes('ERR_CONNECTION_REFUSED')) {
    return 'Cannot connect to WhatsApp — check server internet connectivity';
  }
  if (raw.includes('TimeoutError') || raw.includes('Navigation timeout') || raw.includes('ERR_TIMED_OUT')) {
    return 'WhatsApp Web failed to load — Chromium startup is slow or blocked';
  }
  if (raw.includes('ENOMEM') || raw.includes('out of memory') || raw.includes('OOM')) {
    return 'Out of memory — server needs more RAM to run Chromium';
  }
  if (raw.includes('SIGKILL') || raw.includes('Target closed')) {
    return 'Chromium was killed — likely OOM or container memory limit';
  }
  return raw.length > 300 ? raw.substring(0, 300) + '…' : raw;
}

export const whatsappService = new WhatsAppService();
