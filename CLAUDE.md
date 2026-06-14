# EduScan — CLAUDE.md

This file locks conventions, architecture decisions, and critical rules for all Claude Code sessions in this project. Follow everything here exactly.

---

## Git Rules

- **NEVER commit or push without explicit user instruction.**
- The following files must never be committed:
  - `backend/.env`
  - Any file containing real secrets or credentials
  - `whatsapp-api/.env`
- Use `git add <specific-files>` — never `git add -A` or `git add .`

---

## Project Overview

EduScan is a multi-tenant SaaS platform for face-recognition attendance management at coaching academies.

**Services:**
| Service | Tech | Directory |
|---|---|---|
| Backend REST API | Node.js + TypeScript + Express | `backend/` |
| Mobile App | Flutter (Dart) | `lib/` |
| Face Recognition | Python FastAPI + InsightFace | `insightface-service/` |
| WhatsApp Notifications | Node.js (standalone) | `whatsapp-api/` |

**Live backend:** `https://eduscan-j4cg.onrender.com`

---

## Multi-Tenant Architecture — CRITICAL

- **Schema-per-academy**: Each academy has its own PostgreSQL schema named `academy_<slug>`.
- **NOT** branch-per-academy. **NOT** separate databases.
- The `public` schema holds shared tables: `academies`, `admins`, `settings`, `super_admin_audit_log`.
- Per-academy schemas hold: `users`, `students`, `courses`, `student_courses`, `fee_records`, `attendance`, `academic_years`, `messages`, `notifications`, `qr_codes`, `settings`.

### search_path + PgBouncer — CRITICAL

- Neon uses PgBouncer in **transaction mode**.
- `SET search_path = academy_<slug>` at the session level is **forbidden** — it causes intermittent "relation does not exist" 500s because the path is lost between transactions.
- **Always** use `SET LOCAL search_path` inside a transaction via `poolManager.ts` helpers: `academyExec()` and `academyQuery()`.
- Never bypass the pool manager for academy-scoped queries.

### pg DATE Type — CRITICAL

- The `pg` library returns `DATE` and `TIMESTAMP` columns as **JavaScript `Date` objects**, not strings.
- Never call string methods (`.split`, `.substring`, `.replace`, etc.) on values coming from PostgreSQL date/timestamp columns — it will throw at runtime.
- Use `date.toISOString().split('T')[0]` or similar after confirming the value is a Date object.

---

## Backend Conventions

**Entry point:** `backend/src/index.ts`
**Build:** `npm run build` (TypeScript → `dist/`)
**Dev:** `npm run dev` (ts-node-dev)
**Start:** `npm start` (runs `dist/index.js`)

### Database Pool

- Single `pg` pool via `DATABASE_URL` (Neon serverless).
- Pool: max 5, idle timeout 30s, connection timeout 10s, SSL enabled.
- File: `backend/src/db/pool.ts` (or equivalent pool init).
- Pool manager: `backend/src/db/poolManager.ts` — use `academyExec()` / `academyQuery()` for all tenant queries.

### Authentication

- JWT Bearer tokens signed with `JWT_SECRET`, expiry `JWT_EXPIRES_IN` (default 8h).
- Token payload carries `type`: `superadmin` | `academy` | `parent`.
- Middleware:
  - `authMiddleware` → super admin routes
  - `academyAuthMiddleware` + `requireRole` → academy routes (roles: `admin`, `teacher`)
  - `kioskAuth` → `X-Kiosk-Key` header for kiosk endpoints
  - `parentAuth` → parent JWT

### Error Handling

- Global `errorHandler` middleware in `backend/src/middleware/errorHandler.ts`.
- Use the `AppError` class for operational errors (carries `statusCode` + optional `data`).
- PG error codes mapped to safe HTTP responses:
  - `23505` → 409 Conflict (duplicate)
  - `23503` → 400 Bad Request (FK violation)
  - `23502` → 400 Bad Request (not-null violation)
  - `42703` → 500 (undefined column — schema bug)
- Backend errors carry `error_ref` and `category` fields in response for log correlation.
- Registration endpoints log `phase=` markers to pinpoint failing step.

### API Response Shape

```json
{ "success": true, "data": { ... }, "message": "..." }
{ "success": false, "error": "...", "error_ref": "...", "category": "..." }
```

### Route Files

| File | Purpose |
|---|---|
| `routes/auth.ts` | Super admin login, OTP, password reset |
| `routes/academy.ts` | Academy register/login/profile |
| `routes/academyCourses.ts` | Course CRUD |
| `routes/academyStudents.ts` | Student management |
| `routes/academyFees.ts` | Fee records and collection |
| `routes/academyAttendance.ts` | Attendance logs |
| `routes/academyParent.ts` | Parent 2-step face-verified login |
| `routes/academyQr.ts` | QR code generation |
| `routes/scan.ts` | Face recognition attendance scan |
| `routes/reports.ts` | PDF/CSV reporting |
| `routes/settings.ts` | System configuration |
| `routes/superAdmin.ts` | Academy management (super admin only) |

### Rate Limiting

- Auth endpoints: 30 requests / 60s (configurable).
- WhatsApp: 30 requests / 60s (via `WA_RATE_LIMIT_*` env vars).

---

## Face Recognition Pipeline

1. **Registration:** 3–5 JPEG images → `POST /embed/batch` on Python InsightFace service → 512-D ArcFace embedding stored in DB.
2. **Attendance Scan:** JPEG → `POST /match` on Python service → compare against Redis embedding cache → match or unknown.
3. **Cache:** Redis stores embeddings for all students. Must reconcile after bulk imports via `cacheReconcile`.
4. **Timeouts:**
   - Default API: 30s
   - Student registration (face capture + cold-start Python service): 90s
   - Real-time scan: 20s

**InsightFace model:** `buffalo_sc`
**Match threshold:** `MATCH_THRESHOLD=0.60`
**Margin threshold:** `MARGIN_THRESHOLD=0.05`

---

## Flutter App Conventions

**State management:** Provider (ChangeNotifier)
**HTTP client:** `http` package via `ApiService` / `AcademyApiService`
**Local DB:** SQLite (`sqflite`) for offline cache
**Face detection:** `google_mlkit_face_detection` (on-device, NV21 format)

### API Service

- `ApiService` unwraps `body['data']` automatically for callers.
- Timeouts: 30s default, 90s for student registration, 20s for face scan.
- Throws `ApiException` on error — callers must catch this.

### Providers (State)

| Provider | Owns |
|---|---|
| `AuthProvider` | Super admin + academy user state, token storage |
| `AcademicYearProvider` | Selected academic year for all list screens |
| `StudentProvider` | Student list + detail |
| `AttendanceProvider` | Attendance records + daily stats |
| `ConnectivityProvider` | Internet status |
| `ParentAuthProvider` | Parent session + JWT |

### Token Types (SharedPreferences)

Stored under key `token_type`: `superadmin` | `academy` | `parent`.
`SplashScreen` reads this to route the user correctly at startup.

### Navigation on Launch

```
SplashScreen → check connectivity → check stored JWT → route:
  superadmin  → DashboardScreen
  academy     → AcademyAdminDashboard
  parent      → ParentDashboardScreen
```

---

## Deployment (Render)

Two `render.yaml` files exist in the repo (root + possibly backend). Failing `buildCommand` **silently serves stale code** — always check build logs on Render, not just deploy status.

**Services:**
- `eduscan-backend` — Node.js, `rootDir: backend`, `npm install && npm run build`, `npm start`
- `eduscan-insightface` — Python, `rootDir: insightface-service`, uvicorn on `$PORT`
- `eduscan-redis` — Redis free plan

**Secrets:** All env vars are `sync: false` — managed in Render dashboard only, never in `render.yaml`.

**Keep-alive:** `utils/keepAlive.ts` pings `GET /api/health` periodically to prevent Render free-tier sleep.

---

## Environment Variables (Backend)

| Variable | Purpose |
|---|---|
| `DATABASE_URL` | Neon PostgreSQL connection string |
| `JWT_SECRET` | JWT signing key |
| `JWT_EXPIRES_IN` | Token expiry (default `8h`) |
| `INSIGHTFACE_URL` | URL of Python face service |
| `REDIS_URL` | Redis connection string |
| `MATCH_THRESHOLD` | Face match confidence threshold (0.60) |
| `MARGIN_THRESHOLD` | Ambiguous match margin (0.05) |
| `SMTP_HOST/PORT/USER/PASS/FROM` | Email (Gmail SMTP) |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | FCM push notifications |
| `WA_SESSION_PATH` | WhatsApp session storage path |
| `WA_CLIENT_ID` | WhatsApp client identifier |
| `NODE_ENV` | `production` or `development` |
| `PORT` | Server port (default 3000) |

---

## WhatsApp Microservice

Standalone Node.js service in `whatsapp-api/`. Added 2026-05-27.
Flutter has a dedicated WhatsApp tab for this feature.
Runs independently — does not share the main backend process.

---

## Local Development

`docker-compose.yml` at root orchestrates:
- `redis:7` on port 6379
- `insightface` Python service on port 8000 (depends on redis)
- `backend` Node.js on port 3000 (depends on insightface)

Inject all env vars from `.env` file (never commit this file).
