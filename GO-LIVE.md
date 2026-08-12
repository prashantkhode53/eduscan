# EduScan — Go-Live Runbook (First Paying Academy)

**Goal:** Onboard the first *paying* coaching academy end-to-end (real students, fees,
attendance, face recognition, parent app + push notifications).

**Status as of writing:** Nothing live in production yet. This is the first launch.

This is an operations + risk runbook, not a feature plan. The code is built; going live
is about infra correctness, data safety, security, and a repeatable onboarding flow.

---

## ⚠️ Known launch blockers found in the repo

Fix these *before* anything else — they will cause silent failures in production.

1. **`render.yaml` is out of sync with reality.**
   Both `render.yaml` (root) and `backend/render.yaml` still define
   `eduscan-insightface` and `eduscan-redis` on Render. But InsightFace + Redis now run
   on **Hetzner CX23 (167.233.94.60)** and the Render copies are suspended.
   - Risk: a deploy that re-creates/links the suspended Render services, or
     `INSIGHTFACE_URL`/`REDIS_URL` pointing at dead Render hosts → 500s on every scan.
   - **Action:** Update both render.yaml files so the backend's `INSIGHTFACE_URL`
     points at the Hetzner box (set as a dashboard secret, `sync: false`), and remove the
     `fromService` links to the suspended Render InsightFace/Redis. The backend must
     never touch Redis directly (per architecture) — only InsightFace does.

2. **`backend/.env.example` is missing production keys.**
   It has no `INSIGHTFACE_URL`, `REDIS_URL`, or `FIREBASE_SERVICE_ACCOUNT_JSON`.
   Update the example so the real Render dashboard env is provably complete
   (see the env audit checklist below).

3. **No automated DB backups verified.** Neon has PITR, but confirm the retention
   window and do at least one *test restore* before real fee data exists (Phase 3).

---

## Phase 0 — Decide the business + scope (before any infra)

- [ ] **Pricing & payment for the academy.** There is **no payment gateway** in the
      codebase (no Razorpay/Stripe). Collect the first academy's payment **manually**
      (bank transfer / UPI / invoice). Subscription state is enforced manually via the
      super-admin academy `status` toggle (`active` / `inactive`).
- [ ] Write a one-page agreement: price, what's included, data ownership, support hours.
- [ ] Define the support channel (phone/email) and who answers it.
- [ ] Decide the rollback story: if it fails for them in week 1, what do you do?

---

## Phase 1 — Infrastructure hardening

### Hosting & services
- [ ] Backend on Render — confirm it's on a **paid plan** (free tier sleeps; keep-alive
      via `utils/keepAlive.ts` pings `/api/health` but cold starts still hurt face scans).
- [ ] InsightFace + Redis on Hetzner (167.233.94.60) — confirm both auto-start on reboot
      (systemd / docker `restart: unless-stopped`).
- [ ] Lock down Hetzner firewall: only the backend's egress IP may reach the InsightFace
      port and Redis port. Redis must **not** be exposed to the public internet.
- [ ] Confirm SSL/TLS on the backend domain and a stable custom domain (not the
      `*.onrender.com` URL baked into the app build).
- [ ] Set timeouts per CLAUDE.md: registration 90s (cold start), scan 20s, default 30s.

### Database (Neon)
- [ ] Confirm `DATABASE_URL` uses the **PgBouncer / pooled** endpoint (transaction mode).
- [ ] Re-confirm all tenant queries go through `academyExec()` / `academyQuery()` with
      `SET LOCAL search_path` — no session-level `SET search_path` anywhere.
- [ ] Confirm Neon plan/retention is adequate; note the PITR window.
- [ ] Pick a maintenance window policy (academies use this during class hours).

---

## Phase 2 — Security pass

- [ ] **Rotate every secret** that has ever been in chat, git history, or a dev machine:
      `JWT_SECRET` (forces re-login — fine pre-launch), `DATABASE_URL`, SMTP creds,
      Firebase service account.
- [ ] Confirm `backend/.env` and any real-secret file are git-ignored and **not** in
      history (`git log --all -- backend/.env`).
- [ ] Verify CORS is restricted to the app/origins you actually serve.
- [ ] Verify rate limiting is on for auth (30/60s).
- [ ] Confirm error responses don't leak stack traces in `NODE_ENV=production`; only
      `error_ref` + `category` should surface (per error-handling convention).
- [ ] Test tenant isolation deliberately: log in as Academy A, attempt to read Academy B
      data by ID. Must fail. This is the single highest-risk bug class for a multi-tenant
      SaaS — test it explicitly.
- [ ] Confirm JWT `type` enforcement: a `parent` token cannot hit academy/admin routes.
- [ ] Kiosk endpoints require `X-Kiosk-Key`; rotate that key and store it only on the
      kiosk device.

> Optional: run `/security-review` on the branch before launch for a focused pass.

---

## Phase 3 — Data & backup safety (do before real fee data exists)

- [ ] Verify a **fresh academy registration** creates the `academy_<slug>` schema with all
      tables (run `academyMigrations` path end-to-end on a throwaway academy).
- [ ] **Test restore:** take a Neon PITR/branch snapshot, restore to a scratch branch,
      confirm a per-academy schema and its fee data come back intact. A backup you've
      never restored is not a backup.
- [ ] Document a daily logical backup (`pg_dump`) to off-Neon storage for fee/attendance
      data, even if just a scheduled job. Fees = money; treat it as the crown jewels.
- [ ] Confirm `pg` DATE columns are handled as JS `Date` (no `.split` on raw PG dates) —
      a known footgun; spot-check fee receipt + attendance date rendering.

---

## Phase 4 — Mobile app release

- [ ] Point the Flutter build's `API_BASE_URL` at the **production custom domain**, not
      `eduscan-j4cg.onrender.com` and not a dev IP.
- [ ] Build signed release APK/AAB (and iOS if in scope). Test on a real low-end Android
      device — the kiosk/scan device is often cheap hardware.
- [ ] Verify the three launch routes work from `SplashScreen`: superadmin → dashboard,
      academy → admin dashboard, parent → parent dashboard.
- [ ] Test offline behavior (SQLite cache + `ConnectivityProvider`) — academies have
      flaky wifi.
- [ ] Test face scan on the actual kiosk device + lighting it'll be used in.
- [ ] Decide distribution: Play Store, or direct APK for the first academy (faster).

---

## Phase 5 — End-to-end dress rehearsal (staging academy)

Run the **entire** first-academy journey on a throwaway tenant before the real one:

- [ ] Super admin creates the academy → academy admin logs in.
- [ ] Create academic year → courses → register 3–5 students with face capture
      (3–5 JPEGs → `/embed/batch` → 512-D embedding stored).
- [ ] Confirm Redis embedding cache reconcile after the registrations (`cacheReconcile`).
- [ ] Run a live attendance scan → match + unknown case → parent notification fires.
- [ ] Record a fee payment, generate a receipt/report (PDF/CSV).
- [ ] Parent app: 2-step face-verified login → sees attendance + fees + push notification.
- [ ] Delete the staging academy / wipe its schema.

---

## Phase 6 — Launch day (real academy)

- [ ] Onboard during off-hours.
- [ ] Bulk-import real students; **reconcile the Redis cache** after the import.
- [ ] Sit with the academy for the first real scan session; watch logs live.
- [ ] Confirm the first real parent (push) notification lands.
- [ ] Toggle academy `status = active` only after payment is received.

---

## Phase 7 — Operations (week 1 and ongoing)

- [ ] **Monitoring:** uptime ping on `/api/health`; alert to your phone (UptimeRobot/
      BetterStack). Watch Render + Hetzner.
- [ ] **Log correlation:** when the academy reports an error, get the `error_ref` from the
      app and grep Render logs by it. Registration logs `phase=` markers.
- [ ] **Render gotcha:** a failing `buildCommand` *silently serves stale code*. Always
      check build logs, not just deploy status.
- [ ] Daily glance: backup ran, services up, no error spikes.
- [ ] Keep a runbook for the 2 most likely incidents:
      (1) face scans 500ing → InsightFace/Hetzner down or `INSIGHTFACE_URL` wrong;
      (2) "relation does not exist" → search_path/pooling regression.

---

## Quick env audit (backend, Render dashboard)

Confirm each is set correctly for production — `.env.example` is currently incomplete:

| Var | Must be |
|---|---|
| `DATABASE_URL` | Neon **pooled** endpoint, `sslmode=require` |
| `JWT_SECRET` | freshly rotated, 32-byte random |
| `JWT_EXPIRES_IN` | `8h` (or your choice) |
| `INSIGHTFACE_URL` | **Hetzner** box, not suspended Render service |
| `REDIS_URL` | only if the backend truly needs it (architecture says it shouldn't) |
| `SMTP_*` | working app password, `SMTP_FROM` set |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | valid JSON, for parent push |
| `NODE_ENV` | `production` |

---

## What is intentionally NOT in scope for first launch

- Automated billing / payment gateway — collect manually, toggle academy `status`.
- Self-serve public academy signup — onboard the first one yourself, by hand.
- Multi-region / HA — single Render + single Hetzner box is fine for one academy.
