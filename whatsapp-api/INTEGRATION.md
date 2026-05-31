# EduScan WhatsApp Module — Integration Guide

Integrates into your **existing** EduScan Render backend.
No separate service, no persistent disk, no extra cost.

---

## 1. Copy module files

Copy the entire `whatsapp-api/` folder into your existing backend's source tree:

```
your-backend/
└── src/
    └── whatsapp/        ← copy whatsapp-api/src/ contents here
```

---

## 2. Add dependencies

Append to your existing `package.json` → `dependencies`:

```json
"whatsapp-web.js": "^1.23.0",
"puppeteer":       "^21.5.0",
"qrcode":          "^1.5.3",
"winston":         "^3.11.0",
"joi":             "^17.11.0",
"express-rate-limit": "^7.1.5"
```

Then run: `npm install`

---

## 3. Add environment variables

Append to your existing `.env` (and Render dashboard):

```env
WA_SESSION_PATH=.wwebjs_auth
WA_CLIENT_ID=eduscan-wa-client
# WA_API_KEY=           # optional — leave blank to rely on your existing JWT auth
WA_RATE_LIMIT_WINDOW_MS=60000
WA_RATE_LIMIT_MAX=30
```

`DATABASE_URL` is already present — no change needed.

---

## 4. Mount in your Express app

In your existing `app.js` / `server.js`:

```javascript
const { router: waRouter, init: initWhatsApp } = require('./src/whatsapp');

// Call once during server startup (after DB is ready)
await initWhatsApp();

// Mount AFTER your existing auth middleware so JWT is already verified
app.use('/whatsapp', yourAuthMiddleware, waRouter);
```

> **No existing auth middleware?**  
> Set `WA_API_KEY=<secret>` in env — the module will check `X-API-Key` header.

---

## 5. Endpoints (all under `/whatsapp/`)

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/whatsapp/status` | Connection status + today's stats |
| `GET`  | `/whatsapp/qr`     | QR code for pairing |
| `POST` | `/whatsapp/send-checkin` | Check-in notification |
| `POST` | `/whatsapp/send-checkout` | Check-out notification |
| `POST` | `/whatsapp/send-custom` | Custom message |

---

## 6. Render build note

Puppeteer downloads Chromium during `npm install`.
On Render, add this env var to skip the download and use system Chrome if available:

```env
PUPPETEER_CACHE_DIR=/opt/render/.cache/puppeteer
```

Or leave it out — Render's Node buildpack handles Chromium automatically.

---

## 7. Session behaviour

- WhatsApp session is kept **in memory** (`.wwebjs_auth/` on local filesystem).
- Session is **lost on restart/redeploy** — rescan the QR via the Flutter app.
- This is acceptable and expected behaviour.

---

## 8. DB tables created automatically

On first startup, the module creates:

```sql
whatsapp_logs       -- message delivery history
whatsapp_sessions   -- connection event log
```

No existing tables are touched.
