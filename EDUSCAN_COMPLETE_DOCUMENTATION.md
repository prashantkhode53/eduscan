# EduScan — Complete System Documentation
> Version: 1.0 | Date: 2026-06-05 | Status: Living Document

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [User Roles](#2-user-roles)
3. [Complete Navigation Flow](#3-complete-navigation-flow)
4. [Database Flow](#4-database-flow)
5. [Student Registration Flow](#5-student-registration-flow)
6. [Face Recognition Flow](#6-face-recognition-flow)
7. [Attendance Flow](#7-attendance-flow)
8. [Fees Management Flow](#8-fees-management-flow)
9. [WhatsApp Integration Flow](#9-whatsapp-integration-flow)
10. [API Flow](#10-api-flow)
11. [Security Flow](#11-security-flow)
12. [Mobile Application Flow](#12-mobile-application-flow)
13. [Edge Cases](#13-edge-cases)
14. [Bug Analysis](#14-bug-analysis)
15. [Implementation Plan](#15-implementation-plan)

---

## 1. Project Overview

### 1.1 Purpose

EduScan is a **multi-tenant attendance and academy management platform** built for coaching institutes and tuition academies. It uses **face recognition** as the primary method for student check-in and check-out, backed by a complete fee management, parent notification, and reporting system.

The platform runs as:
- A **Flutter mobile app** (used by academy admins and parents)
- A **Node.js/TypeScript REST API** (backend logic, hosted on Render)
- A **Python/FastAPI face recognition microservice** (InsightFace ArcFace model, hosted on Render)
- A **Node.js WhatsApp notification service** (WhatsApp Web automation)
- A **Neon PostgreSQL** database (serverless, schema-per-academy multi-tenant)
- A **Redis cache** (face embedding cache for fast matching)

### 1.2 Target Users

| User | Description |
|------|-------------|
| **Super Admin** | Platform owner. Manages all academies from a central dashboard. |
| **Academy Admin** | Academy owner/manager. Full control over their academy's students, courses, fees, attendance. |
| **Teacher/Staff** | Academy staff with limited permissions (can collect fees, mark attendance manually). |
| **Parent** | Logs in via a separate parent portal. Views their child's attendance and fee records. |
| **Student** | Does not log in. Is enrolled and identified via face recognition. |

### 1.3 Main Modules

| Module | Description |
|--------|-------------|
| **Authentication** | Multi-role login (Super Admin, Academy Admin, Parent), JWT-based, OTP password reset |
| **Academy Management** | Create and manage academies (super admin only) |
| **Student Management** | Register, edit, delete students with face capture |
| **Course Management** | Create courses, assign academic years, set fee schedules |
| **Fees Management** | Generate monthly fees, collect payments, track pending/overdue, download PDF receipts |
| **Attendance** | Face-scan kiosk for check-in/check-out, manual override, attendance logs |
| **Face Recognition** | ArcFace 512D embeddings, Redis cache, duplicate detection, quality gating |
| **QR Code** | Generate QR codes for kiosk identification |
| **WhatsApp** | Send check-in/check-out notifications and fee reminders to parents |
| **Reports** | Attendance and fee reports, PDF/CSV export |
| **Parent Portal** | Face-verified parent login, view child's attendance and fee history |
| **Bulk Upload** | Import students via Excel file |

### 1.4 Technology Stack

```
Mobile App:    Flutter (Dart) — Provider state management, SQLite offline, ML Kit face detection
Backend API:   Node.js + TypeScript + Express
Face Service:  Python + FastAPI + InsightFace (ArcFace buffalo_sc/buffalo_l model)
WhatsApp:      Node.js + whatsapp-web.js + Puppeteer
Database:      Neon PostgreSQL (serverless) — schema-per-tenant
Cache:         Redis (face embeddings)
Deployment:    Render (backend + insightface + redis), Neon (database)
Notifications: Firebase Cloud Messaging (FCM)
PDF:           Dart pdf package
```

---

## 2. User Roles

### 2.1 Super Admin

- **Login:** Username + Password → JWT with `type: 'superadmin'`
- **Capabilities:**
  - Create new academies (triggers schema creation for that academy)
  - View all academies in the system
  - Activate / deactivate academies
  - Delete academies
  - View super admin audit log (all critical actions are logged)
- **Screens:** Splash → Login → Dashboard → Manage Academies → Academy Detail → Register Academy
- **Token:** Carries `role: 'admin'` and `type: 'superadmin'`

### 2.2 Academy Admin

- **Login:** Academy slug + Email + Password → JWT with `type: 'academy'`, `role: 'admin'`
- **Capabilities:**
  - Full CRUD on students, courses, academic years, fees
  - Generate monthly fee records
  - Mark fees as overdue
  - View and export attendance/fee reports
  - Manage QR codes
  - Manage parent accounts
  - Generate and download fee slip PDFs
  - Access face scan kiosk
- **Screens:** Academy Login → Academy Dashboard → all academy sub-screens

### 2.3 Teacher / Staff

- **Login:** Same as academy admin login
- **Token:** Carries `role: 'teacher'`
- **Capabilities (subset of Admin):**
  - View students
  - Collect fees (cannot generate or mark overdue)
  - View attendance
  - Cannot delete students or manage courses
- **Restriction:** `requireRole('admin')` guards block teacher access to destructive/sensitive operations

### 2.4 Parent

- **Login (Two-step):**
  1. Enter: Academy slug + Student ID + Mobile number → returns short-lived session token
  2. Face scan verification (parent's face is compared against the student's registered face embedding) → returns parent JWT
- **Token:** Carries `type: 'parent'`, `academySlug`, `studentId`
- **Capabilities:**
  - View their child's attendance history
  - View their child's fee records and balances
  - Receive WhatsApp notifications for check-in/check-out and fee reminders
- **Screens:** Parent Login Screen (2-step) → Parent Dashboard

### 2.5 Student

- **No login account.** Students are identified entirely via face recognition.
- **Interaction:** Walk in front of the kiosk camera → system identifies them → records attendance.
- **Data stored:** 512D ArcFace face embedding (JSONB in database, cached in Redis)

---

## 3. Complete Navigation Flow

### 3.1 App Startup

```
App Launch
  └── SplashScreen
        ├── Check internet connectivity (ConnectivityProvider)
        │     └── No internet → Show "No Internet" screen (do NOT hang)
        ├── Check stored JWT token (StorageService)
        │     ├── No token → LoginScreen (Super Admin)
        │     ├── Token found → Validate token type
        │     │     ├── type = 'superadmin' → DashboardScreen
        │     │     ├── type = 'academy'    → AcademyAdminDashboard
        │     │     └── type = 'parent'     → ParentDashboard
        │     └── Token expired → LoginScreen
        └── Backend health check → /api/health
```

### 3.2 Super Admin Navigation

```
LoginScreen
  └── DashboardScreen
        ├── Quick Actions:
        │     ├── Register Academy → RegisterAcademyScreen
        │     ├── Manage Academies → ManageAcademiesScreen
        │     │     └── Academy row tap → AcademyDetailScreen
        │     │           ├── Activate / Deactivate toggle
        │     │           └── Delete academy
        │     ├── Face Scan Attendance → AcademyFaceScanScreen
        │     ├── Student List → StudentListScreen
        │     └── Reports → ReportsScreen
        ├── Settings → SettingsScreen
        │     └── Change Password, App Version, Logout
        └── Logout → LoginScreen
```

### 3.3 Academy Admin Navigation

```
AcademyLoginScreen
  └── AcademyAdminDashboard
        ├── Header: Academic Year Selector (AcademicYearProvider)
        ├── Stats Cards: Students, Present Today, Fees Collected
        ├── Quick Actions:
        │     ├── Students → AcademyStudentListScreen
        │     │     ├── Search / filter
        │     │     ├── Student card tap → (detail view)
        │     │     └── FAB → AcademyStudentRegistrationScreen (4-step wizard)
        │     ├── Face Scan Attendance → AcademyFaceScanScreen
        │     ├── Fees → FeesScreen
        │     │     ├── Fee list (overdue first)
        │     │     ├── Filter by status / student / month
        │     │     ├── Collect fee → bottom sheet → update record
        │     │     └── Student tap → StudentFeesDetailTab
        │     ├── Courses → CourseMasterScreen
        │     │     ├── List all courses
        │     │     ├── Add course (name, fee, schedule, academic year)
        │     │     └── Edit / delete course
        │     ├── Academic Years → AcademicYearMasterScreen
        │     │     ├── List all years
        │     │     ├── Create year
        │     │     └── Set as current year
        │     ├── QR Codes → QRCodeScreen
        │     │     ├── View existing QR codes
        │     │     ├── Generate new QR
        │     │     └── Activate / deactivate QR
        │     ├── Bulk Upload → BulkUploadScreen
        │     │     └── Upload Excel → parse → register multiple students
        │     └── Reports → ReportsScreen
        └── Logout
```

### 3.4 Parent Navigation

```
ParentLoginScreen
  ├── Step 1: Enter academy slug + student ID + mobile (10-digit)
  │     └── POST /api/academy/parent/verify → session token
  └── Step 2: Face scan verification
        └── Camera → detect face → POST /api/academy/parent/face-verify → parent JWT
              └── ParentDashboardScreen
                    ├── Tab 1: Attendance history (list by date)
                    └── Tab 2: Fee records (balance, status)
```

### 3.5 Face Scan Kiosk Navigation

```
AcademyFaceScanScreen (full-screen kiosk)
  ├── Camera initializes → front camera, medium resolution, NV21 format
  ├── Continuous image stream → ML Kit face detection (on-device)
  ├── Face detected + quality pass → capture JPEG → POST /api/academy/attendance/scan
  ├── Result overlay (3 seconds):
  │     ├── Check-in success → green overlay, haptic light
  │     ├── Check-out success → orange overlay, haptic light
  │     ├── Duplicate (< 10 min) → amber overlay
  │     ├── Ambiguous match → deep orange overlay, haptic heavy
  │     └── Unknown face → red overlay, haptic heavy
  └── Auto-restart stream after debounce period (2–3 seconds)
```

---

## 4. Database Flow

### 4.1 Architecture — Schema-Per-Tenant

```
Neon PostgreSQL (single database)
  │
  ├── public schema (shared tables)
  │     ├── admins              ← Super admin accounts
  │     ├── students            ← Legacy / global student records (pre-multi-tenant)
  │     ├── attendance          ← Legacy attendance records
  │     ├── academies           ← Academy registry (one row per academy)
  │     ├── settings            ← Global system settings (face_threshold, kiosk_api_key…)
  │     └── super_admin_audit_log ← Audit trail for super admin actions
  │
  ├── academy_<slug1> schema    ← One schema per academy
  │     ├── users               ← Academy staff (admin, teacher)
  │     ├── students            ← Academy students
  │     ├── academic_years      ← School year definitions
  │     ├── courses             ← Courses / classes
  │     ├── student_courses     ← Enrollment table (student ↔ course)
  │     ├── fee_records         ← Fee records per student per course per month
  │     ├── attendance          ← Attendance records
  │     ├── messages            ← Internal messages / announcements
  │     ├── notifications       ← Push notification log
  │     ├── qr_codes            ← QR code registry
  │     └── settings            ← Per-academy settings (kiosk_api_key, face_threshold)
  │
  └── academy_<slug2> schema    ← Another academy, fully isolated
```

> **PgBouncer Safety Rule:** All academy queries use `academyExec()` or `academyQuery()` from `poolManager.ts`, which sets `SET LOCAL search_path TO "<slug>", public` **inside** a transaction. Session-level SET is never used — it causes "relation does not exist" errors under PgBouncer transaction-mode pooling.

### 4.2 All Tables — Full Schema

#### Public Schema Tables

**`admins`** — Super admin accounts
```
id              UUID PK (auto)
username        VARCHAR(50) UNIQUE NOT NULL
password_hash   TEXT NOT NULL
email           VARCHAR(100) UNIQUE NOT NULL
full_name       VARCHAR(100)
role            VARCHAR(20) DEFAULT 'admin'
is_locked       BOOLEAN DEFAULT FALSE
failed_attempts INT DEFAULT 0
last_login      TIMESTAMPTZ
otp_code        VARCHAR(6)
otp_expires_at  TIMESTAMPTZ
created_at      TIMESTAMPTZ DEFAULT NOW()
```

**`academies`** — Registry of all academies
```
id          UUID PK (auto)
name        VARCHAR(100) NOT NULL
slug        VARCHAR(100) UNIQUE NOT NULL     ← Used as schema name
admin_name  VARCHAR(100) NOT NULL
admin_email VARCHAR(100) NOT NULL
phone       VARCHAR(15)
address     TEXT
logo_url    TEXT
status      VARCHAR(10) DEFAULT 'active'     ← 'active' | 'inactive'
created_at  TIMESTAMPTZ DEFAULT NOW()
```
*Indexes:* `idx_academies_slug`, `idx_academies_email`

**`settings`** — Global key-value configuration
```
key        VARCHAR(50) PK
value      TEXT NOT NULL
updated_at TIMESTAMPTZ DEFAULT NOW()
```
*Default values:* `school_name`, `school_logo_url`, `school_hours_start` (07:00), `school_hours_end` (18:00), `face_threshold` (0.75), `kiosk_api_key` (auto-generated UUID), `auto_mark_absent` (true), `absent_alert_days` (3), `app_version` (1.0.0)

**`super_admin_audit_log`** — Audit trail
```
id          UUID PK
admin_id    UUID → admins.id (SET NULL on delete)
action      VARCHAR(50) NOT NULL     ← e.g. 'activate', 'deactivate', 'delete'
target_slug VARCHAR(100)
details     TEXT
created_at  TIMESTAMPTZ DEFAULT NOW()
```

#### Per-Academy Schema Tables (replicated for each academy)

**`users`** — Academy staff accounts
```
id              UUID PK
role            VARCHAR(20) CHECK IN ('admin','teacher','student','parent')
name            VARCHAR(100) NOT NULL
email           VARCHAR(100) UNIQUE NOT NULL
phone           VARCHAR(15)
password_hash   TEXT NOT NULL
avatar_url      TEXT
fcm_token       TEXT
is_active       BOOLEAN DEFAULT TRUE
failed_attempts INT DEFAULT 0
last_login      TIMESTAMPTZ
otp_code        VARCHAR(6)
otp_expires_at  TIMESTAMPTZ
created_at      TIMESTAMPTZ DEFAULT NOW()
updated_at      TIMESTAMPTZ DEFAULT NOW()
```

**`students`** — Academy student records
```
id               VARCHAR(20) PK        ← Format: ACF-YYYY-NNNNN
user_id          UUID → users.id (SET NULL)
first_name       VARCHAR(50) NOT NULL
middle_name      VARCHAR(50)
last_name        VARCHAR(50) NOT NULL
dob              DATE
gender           VARCHAR(10)
blood_group      VARCHAR(5)
mobile           VARCHAR(15) NOT NULL
email            VARCHAR(100)
parent_name      VARCHAR(100)
parent_mobile    VARCHAR(15)
address          TEXT
face_embedding   JSONB                 ← 512-D ArcFace float array
face_quality     DECIMAL(4,2)
parent_fcm_token TEXT                  ← For FCM push notifications
status           VARCHAR(10) DEFAULT 'active'
created_at       TIMESTAMPTZ DEFAULT NOW()
updated_at       TIMESTAMPTZ DEFAULT NOW()
```

**`academic_years`** — School year definitions
```
id                  UUID PK
academic_year_name  VARCHAR(20) NOT NULL    ← e.g. '2025-26'
start_date          DATE NOT NULL
end_date            DATE NOT NULL
status              VARCHAR(10) DEFAULT 'active' CHECK IN ('active','inactive')
is_current_year     BOOLEAN DEFAULT FALSE
created_at          TIMESTAMPTZ DEFAULT NOW()
updated_at          TIMESTAMPTZ DEFAULT NOW()
```

**`courses`** — Course / class definitions
```
id               UUID PK
academic_year_id UUID → academic_years.id (SET NULL)
name             VARCHAR(100) NOT NULL
description      TEXT
subject          VARCHAR(50)
duration_months  INT
default_fee      DECIMAL(10,2) DEFAULT 0
schedule         VARCHAR(20) DEFAULT 'monthly' CHECK IN ('monthly','quarterly','onetime')
is_active        BOOLEAN DEFAULT TRUE
created_at       TIMESTAMPTZ DEFAULT NOW()
updated_at       TIMESTAMPTZ DEFAULT NOW()
```

**`student_courses`** — Enrollment (many-to-many: student ↔ course)
```
id          UUID PK
student_id  VARCHAR(20) → students.id (CASCADE delete)
course_id   UUID → courses.id (CASCADE delete)
fee_amount  DECIMAL(10,2) NOT NULL        ← Overridable per-student fee
start_date  DATE NOT NULL DEFAULT CURRENT_DATE
end_date    DATE
status      VARCHAR(10) DEFAULT 'active' CHECK IN ('active','completed','dropped')
created_at  TIMESTAMPTZ DEFAULT NOW()
UNIQUE(student_id, course_id)
```

**`fee_records`** — Individual fee records
```
id           UUID PK
student_id   VARCHAR(20) → students.id (CASCADE delete)
course_id    UUID → courses.id (SET NULL)
amount_due   DECIMAL(10,2) NOT NULL
amount_paid  DECIMAL(10,2) DEFAULT 0
due_date     DATE NOT NULL
paid_date    DATE
status       VARCHAR(10) DEFAULT 'pending' CHECK IN ('pending','paid','overdue','partial')
remarks      TEXT
collected_by UUID → users.id (SET NULL)
created_at   TIMESTAMPTZ DEFAULT NOW()
updated_at   TIMESTAMPTZ DEFAULT NOW()
```

**`attendance`** — Attendance records
```
id              UUID PK
student_id      VARCHAR(20) → students.id (CASCADE delete)
date            DATE NOT NULL
time_in         TIME
time_out        TIME
duration_mins   INT
status          VARCHAR(10) DEFAULT 'absent' CHECK IN ('present','absent','late','holiday')
checkin_mode    VARCHAR(15) DEFAULT 'face_auto'      ← 'face_auto' | 'manual' | 'qr'
checkout_mode   VARCHAR(15) DEFAULT 'not_recorded'  ← 'face_auto' | 'manual' | 'not_recorded'
confidence_in   DECIMAL(4,2)    ← Face match confidence at check-in (0.0–1.0)
confidence_out  DECIMAL(4,2)    ← Face match confidence at check-out
remarks         TEXT
marked_by       UUID → users.id (SET NULL)
created_at      TIMESTAMPTZ DEFAULT NOW()
UNIQUE(student_id, date)           ← One record per student per day
```

**`qr_codes`** — QR codes for kiosk
```
id          UUID PK
name        VARCHAR(100) NOT NULL
description TEXT
image_data  TEXT NOT NULL    ← Base64 PNG
is_active   BOOLEAN DEFAULT FALSE
created_at  TIMESTAMPTZ DEFAULT NOW()
updated_at  TIMESTAMPTZ DEFAULT NOW()
```

**`messages`** — Internal messaging
```
id          UUID PK
sender_id   UUID → users.id (SET NULL)
receiver_id UUID → users.id (CASCADE delete)
group_type  VARCHAR(30)
subject     VARCHAR(200)
body        TEXT NOT NULL
type        VARCHAR(20) DEFAULT 'message' CHECK IN ('message','announcement','alert','homework','fee_reminder')
read_at     TIMESTAMPTZ
created_at  TIMESTAMPTZ DEFAULT NOW()
```

**`notifications`** — Push notification log
```
id          UUID PK
user_id     UUID → users.id (CASCADE delete)
title       VARCHAR(200) NOT NULL
body        TEXT NOT NULL
type        VARCHAR(30) DEFAULT 'info'
data_json   JSONB
is_read     BOOLEAN DEFAULT FALSE
created_at  TIMESTAMPTZ DEFAULT NOW()
```

**`settings`** (per academy)
```
key        VARCHAR(50) PK
value      TEXT NOT NULL
updated_at TIMESTAMPTZ DEFAULT NOW()
```
*Default values:* `kiosk_api_key` (auto UUID), `face_threshold` (0.75), `auto_mark_absent` (true), `app_version` (1.0.0)

### 4.3 Data Relationships Diagram

```
academies (public)
  └─ (slug → schema name) academy_<slug>
        ├── users ◄─────────────────────── (admin who created records)
        │
        ├── academic_years
        │     └── courses (academic_year_id FK)
        │
        ├── students
        │     ├── student_courses ──────► courses
        │     ├── fee_records ──────────► courses
        │     │                     └──► users (collected_by)
        │     └── attendance ───────────► users (marked_by)
        │
        ├── qr_codes
        ├── messages
        ├── notifications
        └── settings
```

### 4.4 Data Creation Flow

1. **Academy created** → `academies` row inserted (public schema) → `runAcademyMigrations(slug)` creates new schema with all tables → admin user seeded in `users`
2. **Academic year created** → row in `academic_years`
3. **Course created** → row in `courses` (linked to academic year)
4. **Student registered** → row in `students` → rows in `student_courses` (one per selected course) → face embedding cached in Redis via `POST /cache/upsert`
5. **Fee generated** → `generateMonthlyFees()` inserts rows in `fee_records` for every active `student_courses` row
6. **Attendance marked** → row upserted in `attendance` (`ON CONFLICT DO UPDATE`)

### 4.5 Data Update Flow

- **Student edit** → `PATCH /api/academy/students/:id` → update `students` row + update `student_courses` (add/remove courses) + update Redis cache embedding
- **Face recapture** → `PATCH /api/academy/students/:id/face` → update `face_embedding`, `face_quality` in `students` + upsert Redis cache
- **Fee collection** → `POST /api/academy/fees/collect` → update `amount_paid`, `status`, `paid_date`, `collected_by` in `fee_records`
- **Attendance check-in** → `INSERT ... ON CONFLICT DO UPDATE` on `attendance`
- **Attendance check-out** → `UPDATE attendance SET time_out, duration_mins, checkout_mode, confidence_out`

### 4.6 Data Deletion Flow

- **Student deleted** → `DELETE FROM students WHERE id = $1` → cascades to `student_courses`, `fee_records`, `attendance` → `DELETE /cache/:studentId` removes from Redis
- **Course deleted** → cascades to `student_courses`; `fee_records.course_id` set to NULL
- **Academy deactivated** → `status = 'inactive'` in `academies` (schema NOT dropped; data preserved)
- **Academic year deleted** → `courses.academic_year_id` set to NULL

### 4.7 Validation Rules

| Rule | Where Enforced |
|------|---------------|
| `first_name`, `last_name`, `mobile` are required for student | Backend controller |
| At least one course must be selected during registration | Backend controller |
| Mobile must be 10 digits | Flutter UI (FilteringTextInputFormatter) |
| Duplicate mobile with no face embedding → auto-cleaned before insert | Backend (removes orphaned records) |
| Face threshold minimum: 0.75 | `settings` table default |
| Attendance: one record per student per day | DB UNIQUE constraint `(student_id, date)` |
| Student course enrollment: one per student per course | DB UNIQUE constraint `(student_id, course_id)` |
| Academic year status: only 'active' or 'inactive' | DB CHECK constraint |
| Fee status: only 'pending', 'paid', 'overdue', 'partial' | DB CHECK constraint |
| JWT secret must be set | Middleware check on startup |
| Academy slug: only `[a-z0-9_]`, max 63 chars | Server-side regex validation |

---

## 5. Student Registration Flow

### 5.1 Overview

Student registration uses a **4-step wizard** with a **two-phase save**:
- **Phase 1** (Steps 1–3): Student profile + courses saved to database first (data never lost if camera fails)
- **Phase 2** (Step 4): Face captured → embedding generated → attached to existing student record

### 5.2 Step-by-Step Flow

```
Step 1 — Personal Information
  Fields: First Name*, Last Name*, Date of Birth, Gender, Mobile* (10 digits), Email
  Validation: All required fields checked, mobile must be 10 digits
  On Next: Form validated → proceed to Step 2

Step 2 — Parent & Address Information
  Fields: Parent Name, Parent Mobile (10 digits), Address
  On Next: Form validated → proceed to Step 3

Step 3 — Course Selection
  Load: GET /api/academy/courses?academicYearId=<current>
  Display: List of active courses with default fees
  Action: Toggle courses on/off, optionally override fee amount per course
  Validation: At least one course must be selected
  On Next:
    ├── Phase 1 starts (runs in background while camera initialises)
    │     POST /api/academy/students  (without face_images)
    │     → Creates student record + student_courses rows
    │     → Returns { studentId: 'ACF-2026-00001' }
    └── Proceed to Step 4 (camera starts simultaneously)

Step 4 — Face Capture
  Camera: Front camera, medium resolution, NV21 format
  On-device face detection: Google ML Kit
  Quality gates (from FaceService):
    - Face must be centered in oval guide
    - No multiple faces
    - Head angle (yaw) acceptable
    - Face size sufficient
  Auto-capture process:
    - Hold face steady for ~2 seconds (progress bar fills)
    - Captures 5 JPEG frames automatically (_requiredSamples = 5)
    - Encodes each as base64
  On completion:
    ├── Wait for Phase 1 (studentId) if not yet returned
    └── PATCH /api/academy/students/:studentId/face
          Body: { face_images: [base64_1, base64_2, ..., base64_5] }
          → Backend sends to InsightFace POST /embed/batch
          → InsightFace averages 5 embeddings → returns 512D vector
          → Backend stores in students.face_embedding (JSONB)
          → Backend calls POST /cache/upsert → Redis updated
          → Returns { studentId, embedding_saved: true }
```

### 5.3 Student ID Generation

```
Format: ACF-{YEAR}-{SEQUENCE}
Example: ACF-2026-00001, ACF-2026-00002

Logic (studentController.ts):
  1. Query MAX(CAST(SUBSTRING(id FROM length('ACF-2026-') + 1) AS INTEGER))
     FROM students WHERE id LIKE 'ACF-2026-%'
  2. seq = (max_seq ?? 0) + 1
  3. Pad to 5 digits: seq.toString().padStart(5, '0')
  4. Return 'ACF-2026-' + padded_seq
```

> **Why MAX instead of COUNT?** COUNT causes collisions when rows have gaps (e.g., orphaned face-less students deleted mid-registration). MAX always produces a unique next value.

### 5.4 Duplicate Student Handling

Before inserting a new student, the backend runs:
```sql
DELETE FROM students WHERE mobile = $1 AND face_embedding IS NULL
```
This removes any previous "orphaned" student records created when a registration was abandoned at the face capture step (Phase 1 succeeded, Phase 2 failed). This prevents duplicate mobile number conflicts.

### 5.5 Registration Error Scenarios

| Error | Cause | Handling |
|-------|-------|---------|
| Camera permission denied | User denied camera | Show "Enable in Settings" + Retry button |
| Camera timeout (> 12s) | Driver hang | Show TimeoutException message + Retry |
| No face detected | Poor lighting, distance | Quality hint shown ("Move closer", etc.) |
| Multiple faces | More than one person in frame | "Please stand alone" message |
| Face embedding failure | InsightFace service down | HTTP 422 returned; user sees error toast |
| Duplicate mobile (active student) | Student already registered | Backend returns 409 conflict |
| Network failure | Offline during Phase 1 | Error shown; no orphan created |

---

## 6. Face Recognition Flow

### 6.1 Face Enrollment (Registration)

```
Flutter (AcademyStudentRegistrationScreen)
  │  5 × base64 JPEG images
  ▼
Backend (POST /api/academy/students/:id/face)
  │  calls batchEmbed(face_images)
  ▼
InsightFace Service (POST /embed/batch)
  │  1. Decode each base64 → bytes
  │  2. For each image:
  │       a. Detect face with ArcFace model
  │       b. Apply quality gate (min size, yaw angle, score)
  │       c. Extract 512D L2-normalized embedding
  │  3. Average all valid embeddings
  │  4. Return averaged 512D vector
  ▼
Backend
  │  1. Store embedding in students.face_embedding (JSONB)
  │  2. Call POST /cache/upsert (InsightFace)
  │       → Set Redis key: face_emb:{studentId}
  │       → Value: { embedding, first_name, last_name, class_grade, division, roll_no }
  ▼
Redis Cache
  └── face_emb:{studentId} = JSON with embedding + metadata
```

### 6.2 Face Embedding Storage

- **Database:** `students.face_embedding` column (JSONB) — persistent, survives Redis restart
- **Redis:** `face_emb:{studentId}` keys — fast in-memory lookup for matching
- **On server startup:** `redis_cache.py` loads all embeddings from PostgreSQL into Redis (`reload_from_db()`)
- **Hourly reconciliation:** Backend calls `POST /cache/reconcile` with valid student IDs → removes stale Redis entries

### 6.3 Face Matching Process (Scan / Attendance)

```
Flutter Kiosk (AcademyFaceScanScreen)
  │  Continuous image stream → ML Kit detects face on-device
  │  Quality check passes → capture JPEG → base64 encode
  ▼
Backend (POST /api/academy/attendance/scan OR /api/attendance/scan)
  │  calls matchFace(image_base64) from utils/insightface.ts
  ▼
InsightFace Service (POST /match)
  │  1. Generate embedding from incoming image
  │  2. Load all embeddings from Redis (get_all_embeddings())
  │  3. FaceAnalyzer.find_best_match():
  │       a. Compute cosine similarity between query and every cached embedding
  │       b. Sort by similarity score descending
  │       c. Best score ≥ threshold (0.75) AND margin to 2nd best ≥ margin_threshold
  │          → matched = True, student_id = best match ID
  │       d. Best score ≥ threshold BUT margin too small
  │          → matched = False, reason = 'ambiguous_match'
  │       e. Best score < threshold
  │          → matched = False, reason = 'below_threshold'
  ▼
Backend (scanController.ts)
  │  1. matchResult.matched = false → return appropriate error response
  │  2. matchResult.matched = true:
  │       a. Verify student is 'active' in DB
  │       b. Check for duplicate scan (< 10 min window)
  │       c. mode = 'checkin' → INSERT/UPDATE attendance (time_in, status='present')
  │       d. mode = 'checkout' → UPDATE attendance (time_out, duration_mins)
  ▼
Flutter
  └── Show result overlay for 3 seconds → restart stream
```

### 6.4 Duplicate Scan Prevention

- **Window:** 10 minutes
- **Check-in:** If `existing.time_in` exists and `(current_time - time_in) < 10 min` → return `action: 'duplicate'`
- **Check-out:** If `existing.time_out` exists and `(current_time - time_out) < 10 min` → return `action: 'duplicate'`
- **UI response:** Amber overlay, "Already recorded (10 min window)" message — no DB write

### 6.5 Face Quality Gates

Applied by `FaceService.scanQualityHint()` on Flutter (on-device) and `FaceAnalyzer.get_embedding()` on InsightFace (server-side):

| Gate | Threshold | Failure Message |
|------|-----------|----------------|
| Face size | Minimum pixels | "Move closer to the camera" |
| Head yaw angle | Max degrees | "Face the camera directly" |
| Face detection confidence | Minimum score | "Face not clearly visible" |
| Multiple faces | Count > 1 | "Please stand alone" |

### 6.6 Ambiguous Match

Occurs when the best match score is above the threshold but the gap to the second-best match is too small. This means the system cannot confidently distinguish between two registered students.

- **Response:** `action: 'ambiguous'`, message includes score and gap percentage
- **UI:** Deep orange overlay, "Ambiguous Match" with details
- **Resolution for user:** Face the camera directly, re-register if persistent

### 6.7 Error Handling

| Error | HTTP Status | Response |
|-------|------------|---------|
| InsightFace service unreachable | 503 | `action: 'error'`, "Face recognition service unavailable" |
| No face detected in image | 200 | `success: false`, `action: 'unknown'`, "Face detection failed" |
| Student inactive | 200 | `success: false`, "Student not found or inactive" |
| Checkout without check-in | 200 | `success: false`, `action: 'error'`, "No check-in found for today" |

---

## 7. Attendance Flow

### 7.1 Face Detection → Check-In

```
1. Kiosk camera runs continuously (image stream)
2. Every frame: ML Kit face detection (on-device, fast)
3. If no face detected: overlay = idle, status = "Looking for face..."
4. If multiple faces: overlay = unknown, "Please stand alone"
5. If face detected + quality OK: overlay = detected, capture JPEG
6. JPEG → base64 → POST /api/academy/attendance/scan { image_base64, mode: 'checkin' }
7. InsightFace matches → student identified
8. attendance row:
     INSERT INTO attendance (student_id, date, time_in, status, checkin_mode, confidence_in)
     VALUES ($1, TODAY, CURRENT_TIME, 'present', 'face_auto', $4)
     ON CONFLICT (student_id, date) DO UPDATE
       SET time_in = $3, status = 'present', checkin_mode = 'face_auto', confidence_in = $4
9. Response: { action: 'checkin', student, time_in, confidence }
10. Flutter: green overlay, student name/ID shown, counter increments
11. WhatsApp notification sent to parent (if WA service connected)
```

### 7.2 Face Detection → Check-Out

```
1. Admin switches mode to 'checkout' on kiosk
2. Same face detection flow
3. POST /api/academy/attendance/scan { image_base64, mode: 'checkout' }
4. Backend verifies existing check-in exists for today
5. Calculates duration: (time_out_mins - time_in_mins)
6. UPDATE attendance SET time_out, duration_mins, checkout_mode='face_auto', confidence_out
7. Response: { action: 'checkout', time_in, time_out, duration_mins, confidence }
8. Flutter: orange overlay, shows "X hours Y minutes"
9. WhatsApp checkout notification to parent
```

### 7.3 Attendance Status Values

| Status | Meaning | When Set |
|--------|---------|---------|
| `present` | Student checked in | After successful check-in scan |
| `absent` | Default; no scan recorded | Auto-set if `auto_mark_absent = true` |
| `late` | Arrived after school hours start | Future feature |
| `holiday` | Day marked as holiday | Manual override |

### 7.4 Manual Attendance Override

- **Route:** `PATCH /api/academy/attendance/:id`
- **Who:** Academy admin or teacher
- **Fields:** `status`, `time_in`, `time_out`, `remarks`
- **Mode recorded:** `checkin_mode = 'manual'`, `checkout_mode = 'manual'`
- **Marked_by:** `users.id` of the staff member who made the change

### 7.5 Attendance Logs

- **Route:** `GET /api/academy/attendance`
- **Filters:** `date`, `student_id`, `status`, `page`, `limit`
- **Sorted by:** date descending
- **Fields returned:** `student_id`, `first_name`, `last_name`, `date`, `time_in`, `time_out`, `duration_mins`, `status`, `checkin_mode`, `confidence_in`, `confidence_out`

### 7.6 Reports

- **Route:** `GET /api/reports`
- **Types:** Daily attendance summary, weekly, monthly, per-student history
- **Export:** JSON (for in-app display), CSV (download), PDF (via Flutter pdf package)

---

## 8. Fees Management Flow

### 8.1 Fee Structure

```
Academy → defines Course → sets default_fee + schedule (monthly/quarterly/onetime)
         ↓
Student enrolled → student_courses row with fee_amount (can differ from default)
         ↓
Admin runs "Generate Fees" → fee_records created for the month
         ↓
Admin collects payment → fee_records.amount_paid updated → status changes
```

### 8.2 Monthly Fee Generation

```
POST /api/academy/fees/generate
Body: { month: 'YYYY-MM' }  ← defaults to current month

SQL logic:
  INSERT INTO fee_records (student_id, course_id, amount_due, due_date, status)
  SELECT sc.student_id, sc.course_id, sc.fee_amount,
         LAST_DAY_OF_MONTH($month), 'pending'
  FROM student_courses sc
  WHERE sc.status = 'active'
    AND NOT EXISTS (
      SELECT 1 FROM fee_records fr
      WHERE fr.student_id = sc.student_id
        AND fr.course_id  = sc.course_id
        AND TO_CHAR(fr.due_date,'YYYY-MM') = $month
    )

- Safe to call multiple times (NOT EXISTS guard prevents duplicates)
- due_date = last day of the target month
- Only active enrollments generate fees
```

### 8.3 Fee Collection

```
POST /api/academy/fees/collect
Body: { fee_record_id, amount_paid, payment_mode, remarks }

Logic:
  1. Fetch record; reject if status = 'paid'
  2. new_paid = existing_paid + amount_paid
  3. balance = amount_due - new_paid
  4. new_status:
       balance ≤ 0         → 'paid'
       new_paid > 0        → 'partial'
       else                → unchanged
  5. UPDATE fee_records SET amount_paid, status, paid_date, remarks, collected_by
  6. Response includes remaining balance and message
```

### 8.4 Fee Status Machine

```
          Generate Fees
              ↓
           pending
          /       \
    collect partial   past due_date
        ↓                ↓
     partial           overdue
        ↓                ↓
  collect rest      collect any amount
        ↓                ↓
        └──────► paid ◄──┘
```

`POST /api/academy/fees/mark-overdue` transitions all `pending`/`partial` records past `due_date` to `overdue`.

### 8.5 Fee Summary Dashboard

`GET /api/academy/fees` returns with each page:
```json
{
  "summary": {
    "total_due": 150000.00,
    "total_paid": 120000.00,
    "count_pending": 12,
    "count_overdue": 3,
    "count_paid": 45
  }
}
```
Records are sorted: overdue → pending → partial → paid, then by due_date ascending.

### 8.6 Per-Student Fee View

`GET /api/academy/fees/student/:studentId` returns all fee records with:
```json
{
  "records": [...],
  "totals": {
    "total_due": 6000.00,
    "total_paid": 4500.00,
    "total_balance": 1500.00
  }
}
```

### 8.7 Fee Slip PDF Generation

- **Flutter service:** `fee_pdf_service.dart` and `pdf_service.dart`
- **Content:** Academy name/logo, student name/ID, course name, amount due, amount paid, balance, due date, payment date, payment mode, collected by, remarks
- **Format:** A4 PDF generated in-memory and opened via `open_filex`
- **Trigger:** "Download Receipt" button on fee detail screen

### 8.8 Pending Fees Tracking

- Filter `GET /api/academy/fees?status=pending` or `status=overdue`
- WhatsApp fee reminder: `POST /whatsapp/send-custom` to parent mobile

---

## 9. WhatsApp Integration Flow

### 9.1 Architecture

```
whatsapp-api/ (Node.js service, integrated into backend)
  │
  ├── WhatsAppService (whatsappService.js) ← Singleton
  │     ├── whatsapp-web.js Client
  │     ├── Puppeteer (headless Chromium)
  │     └── LocalAuth (.wwebjs_auth/ filesystem session)
  │
  ├── State machine:
  │     INITIALIZING → QR_PENDING → CONNECTED
  │                              ↓
  │                        DISCONNECTED → RECONNECTING → QR_PENDING
  │
  └── PostgreSQL: whatsapp_logs + whatsapp_sessions tables
```

### 9.2 Initial QR Connection

```
1. App start → WhatsAppService.initialize() called
2. Puppeteer launches headless Chromium
3. WhatsApp Web loads → emits 'qr' event
4. State → QR_PENDING
5. QR string stored: _qrData (raw), _qrBase64 (PNG)

Academy Admin in Flutter:
  6. Open WhatsApp/QR screen
  7. GET /whatsapp/qr → { qr_data: '...', qr_base64: '...' }
  8. Display QR code using qr_flutter package
  9. Admin scans with their WhatsApp app
  10. WhatsApp emits 'authenticated' → session saved to .wwebjs_auth/
  11. WhatsApp emits 'ready' → State → CONNECTED
  12. _lastConnectedAt = now

Session persistence:
  - Session stored in .wwebjs_auth/<clientId>/ (filesystem)
  - Lost on Render restart (ephemeral disk)
  - On restart → QR_PENDING again → re-scan required
```

### 9.3 Sending Attendance Notifications

**Check-in notification:**
```
POST /whatsapp/send-checkin
Body: {
  phone: "919876543210",        ← Parent's mobile with country code
  student_name: "Rahul Sharma",
  time_in: "09:15:00",
  academy_name: "Excel Academy"
}

Message format:
"✅ *Check-In Alert*
Student: Rahul Sharma
Time: 09:15 AM
Academy: Excel Academy
Have a great day! 📚"
```

**Check-out notification:**
```
POST /whatsapp/send-checkout
Body: {
  phone, student_name, time_out, duration_mins, academy_name
}

Message format:
"🏠 *Check-Out Alert*
Student: Rahul Sharma
Time: 04:30 PM
Duration: 7h 15m
Academy: Excel Academy"
```

### 9.4 Sending Fee Notifications

```
POST /whatsapp/send-custom
Body: {
  phone: "919876543210",
  message: "💰 Fee Reminder: ₹1500 pending for May 2026 — Excel Academy"
}
```

### 9.5 Connection Status Check

```
GET /whatsapp/status
Response: {
  connected: true,
  state: 'connected',
  last_connected_at: '2026-06-05T09:00:00Z',
  today_sent: 42,
  today_failed: 0
}
```

### 9.6 Error Recovery

| Error | Recovery |
|-------|---------|
| WhatsApp disconnects | State → DISCONNECTED → RECONNECTING → re-init (exponential backoff) |
| QR expired | New QR generated automatically on next init cycle |
| Message send fails | Logged to `whatsapp_logs` with `status: 'failed'`; no retry by default |
| Puppeteer crash | Process restart (Render auto-restarts on crash) |
| Session lost on restart | Admin must re-scan QR code |
| Phone not on WhatsApp | whatsapp-web.js throws error; logged as failed |

### 9.7 Phone Number Formatting

`phoneFormatter.js` normalises numbers:
- Input: `9876543210` or `+91 98765 43210` or `91-9876543210`
- Output: `919876543210@c.us` (WhatsApp internal format with country code)

---

## 10. API Flow

### 10.1 Base URL

- **Production:** `https://eduscan-backend.onrender.com/api`
- **Local:** `http://localhost:3000/api`

### 10.2 Authentication Endpoints

| Method | Endpoint | Body | Description |
|--------|----------|------|-------------|
| POST | `/auth/login` | `{ username, password }` | Super admin login → JWT |
| POST | `/auth/forgot-password` | `{ email }` | Send OTP to email |
| POST | `/auth/verify-otp` | `{ email, otp }` | Verify OTP |
| POST | `/auth/reset-password` | `{ email, otp, new_password }` | Reset password |
| POST | `/auth/change-password` | `{ old_password, new_password }` | Change own password (auth required) |

### 10.3 Academy Management Endpoints (Super Admin)

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/super-admin/academies` | List all academies |
| POST | `/super-admin/academies` | Create academy + provision schema |
| PATCH | `/super-admin/academies/:slug/status` | Activate / deactivate |
| DELETE | `/super-admin/academies/:slug` | Delete academy |

### 10.4 Academy Auth Endpoints

| Method | Endpoint | Body | Description |
|--------|----------|------|-------------|
| POST | `/academy/login` | `{ email, password, slug }` | Academy user login → JWT |
| POST | `/academy/refresh` | `{ refresh_token }` | Refresh academy JWT |

### 10.5 Academy Student Endpoints

All require Academy JWT header: `Authorization: Bearer <token>`

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/academy/students` | List students (filter: status, course_id, page, limit) |
| POST | `/academy/students` | Register new student (with or without face) |
| GET | `/academy/students/:id` | Get student detail |
| PATCH | `/academy/students/:id` | Update student info |
| DELETE | `/academy/students/:id` | Delete student (cascades attendance, fees) |
| PATCH | `/academy/students/:id/face` | Attach/update face embedding |
| GET | `/academy/students/search` | Search by name or mobile |

**POST `/academy/students` — Request Body:**
```json
{
  "first_name": "Rahul",
  "last_name": "Sharma",
  "dob": "2010-05-15",
  "gender": "male",
  "mobile": "9876543210",
  "email": "rahul@example.com",
  "parent_name": "Mohan Sharma",
  "parent_mobile": "9876543211",
  "address": "123 Main St, City",
  "courses": [
    { "course_id": "uuid-1", "fee_amount": 1500.00 },
    { "course_id": "uuid-2", "fee_amount": 2000.00 }
  ],
  "face_images": ["base64_img_1", "base64_img_2", "..."]
}
```

**Response:**
```json
{
  "success": true,
  "data": {
    "id": "ACF-2026-00001",
    "first_name": "Rahul",
    "last_name": "Sharma",
    "face_registered": true
  }
}
```

### 10.6 Attendance / Scan Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/attendance/scan` | Global scan (Super admin context) |
| POST | `/academy/attendance/scan` | Academy-scoped scan (kiosk) |
| GET | `/academy/attendance` | List attendance (filter: date, student_id, status) |
| POST | `/academy/attendance` | Manual attendance entry |
| PATCH | `/academy/attendance/:id` | Update attendance record |

**POST `/academy/attendance/scan` — Request:**
```json
{
  "image_base64": "<JPEG as base64 string>",
  "mode": "checkin",
  "timestamp": "2026-06-05T09:15:00.000Z"
}
```

**Response (check-in success):**
```json
{
  "success": true,
  "action": "checkin",
  "student": {
    "id": "ACF-2026-00001",
    "first_name": "Rahul",
    "last_name": "Sharma",
    "class_grade": "10",
    "division": "A",
    "roll_no": 5
  },
  "time_in": "09:15:00",
  "confidence": 0.91,
  "message": "Face matched! Check-in recorded for Rahul Sharma at 09:15:00"
}
```

**Possible `action` values:**
| Action | Success | Meaning |
|--------|---------|---------|
| `checkin` | true | Check-in recorded |
| `checkout` | true | Check-out recorded |
| `duplicate` | true | Scan within 10-min window, no write |
| `unknown` | false | Face not recognised |
| `ambiguous` | false | Ambiguous match, re-scan needed |
| `error` | false | Service error |

### 10.7 Fees Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/academy/fees` | List fees (filter: status, student_id, course_id, month) |
| GET | `/academy/fees/student/:id` | All fees for one student |
| POST | `/academy/fees/collect` | Record payment |
| POST | `/academy/fees/generate` | Generate monthly fees |
| POST | `/academy/fees/mark-overdue` | Transition past-due fees to overdue |

### 10.8 Course & Academic Year Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/academy/courses` | List courses (filter: academic_year_id, is_active) |
| POST | `/academy/courses` | Create course |
| PATCH | `/academy/courses/:id` | Update course |
| DELETE | `/academy/courses/:id` | Delete course |
| GET | `/academy/academic-years` | List academic years |
| POST | `/academy/academic-years` | Create academic year |
| PATCH | `/academy/academic-years/:id` | Update year |
| PATCH | `/academy/academic-years/:id/set-current` | Set as current year |

### 10.9 QR Code Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/academy/qr-codes` | List QR codes |
| POST | `/academy/qr-codes` | Generate new QR code |
| PATCH | `/academy/qr-codes/:id/activate` | Set as active |
| DELETE | `/academy/qr-codes/:id` | Delete QR code |

### 10.10 Parent Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/academy/parent/verify` | Step 1: verify student ID + mobile → session token |
| POST | `/academy/parent/face-verify` | Step 2: face scan → parent JWT |
| GET | `/academy/parent/attendance` | Child's attendance (parent JWT required) |
| GET | `/academy/parent/fees` | Child's fee records (parent JWT required) |

### 10.11 InsightFace Service Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/embed` | Generate 512D embedding from one image |
| POST | `/embed/batch` | Batch embed + average (registration) |
| POST | `/match` | Match face against Redis cache |
| POST | `/cache/upsert` | Add/update student embedding in Redis |
| DELETE | `/cache/:student_id` | Remove student from Redis |
| POST | `/cache/reload` | Full reload from PostgreSQL |
| POST | `/cache/reconcile` | Hourly: remove stale entries |
| GET | `/health` | Liveness probe |

### 10.12 Standard Error Response Format

```json
{
  "success": false,
  "message": "Human-readable error description",
  "code": "OPTIONAL_ERROR_CODE"
}
```

HTTP status codes:
- `400` — Bad request (missing/invalid fields)
- `401` — Unauthorized (missing or expired token)
- `403` — Forbidden (insufficient role)
- `404` — Not found
- `409` — Conflict (duplicate)
- `422` — Unprocessable (face embedding failure)
- `429` — Rate limited
- `500` — Server error
- `503` — Dependency unavailable (InsightFace service down)

---

## 11. Security Flow

### 11.1 Authentication

**Super Admin Login:**
```
POST /auth/login { username, password }
  1. Rate limiter: authLimiter (max 5 attempts per 15 min per IP)
  2. Fetch admin by username from public.admins
  3. If is_locked = true → reject "Account locked"
  4. bcrypt.compare(password, password_hash)
  5. If fail: failed_attempts++ 
     If failed_attempts ≥ 5: is_locked = true
  6. If success: failed_attempts = 0, last_login = NOW()
  7. JWT signed: { id, username, role, type: 'superadmin' }
  8. JWT_SECRET from environment (process.env.JWT_SECRET)
  9. Token expiry: configurable (typically 24h)
```

**Academy User Login:**
```
POST /academy/login { email, password, slug }
  1. Same rate limiter
  2. academyExec(slug) → SELECT from users WHERE email = $1
  3. bcrypt.compare(password, password_hash)
  4. JWT signed: { userId, academySlug, role, type: 'academy' }
```

**Parent Login (2-step):**
```
Step 1: POST /academy/parent/verify { slug, student_id, mobile }
  → Verify student exists in that academy with matching mobile
  → Return short-lived session token (in-memory, 5-min TTL)

Step 2: POST /academy/parent/face-verify { session_token, image_base64 }
  → Verify session token valid and not expired
  → Match face against student's stored embedding
  → If confidence ≥ threshold → issue parent JWT
  → JWT: { type: 'parent', academySlug, studentId }
```

### 11.2 Authorization

Three middleware layers enforce access:

| Middleware | Guards | Token Type Check |
|-----------|--------|-----------------|
| `auth.ts` (`authMiddleware`) | Super admin routes | `type = 'superadmin'` |
| `academyAuth.ts` (`academyAuthMiddleware`) | Academy routes | `type = 'academy'` |
| `parentAuth.ts` | Parent routes | `type = 'parent'` |
| `kioskAuth.ts` | Kiosk scan routes | `X-Kiosk-Key` header matches `settings.kiosk_api_key` |

Role-based access within academy routes:
```typescript
router.post('/generate', requireRole('admin'), generateMonthlyFees);
//  Teachers cannot generate fees — only admin role can
```

### 11.3 Session Management

- **JWT storage:** Flutter stores JWT in `SharedPreferences` via `StorageService`
- **Token expiry:** Checked on app resume and API call (401 → clear token → redirect to login)
- **No refresh token** (current implementation): User must re-login on expiry
- **Session token (parent step 1):** In-memory only, 5-minute TTL, single-use

### 11.4 Data Protection

- **Passwords:** bcrypt hashed with cost factor 10 (admin) / 12 (academy users)
- **Face embeddings:** Stored as JSONB array — not a biometric template in a traditional sense, but treated as sensitive data
- **kiosk_api_key:** Auto-generated UUID, stored in `settings`, used as a static API key for the kiosk device
- **OTP:** 6-digit code, stored in `otp_code` with `otp_expires_at` timestamp

### 11.5 Transport Security

- **CORS:** Configured to allow all origins (`*`) — suitable for mobile app (no browser session attacks)
- **Helmet:** HTTP security headers enabled (`contentSecurityPolicy: false` for API-only use)
- **Rate limiting:** `authLimiter` on login and password-reset routes
- **Payload size limit:** 5MB (to accommodate face scan base64 images)

### 11.6 JWT Expiration Handling

```
Flutter flow on 401 response:
  1. api_service.dart receives 401
  2. Clear stored JWT (StorageService.clearToken())
  3. Navigate to LoginScreen (or AcademyLoginScreen)
  4. User shown "Session expired. Please log in again."
```

---

## 12. Mobile Application Flow

### 12.1 App Entry — Splash Screen

```
Screen: splash_screen.dart
Duration: ~2–3 seconds (async checks)
Logic:
  1. Check connectivity via ConnectivityProvider
     → No connectivity: show offline screen with retry
  2. Read stored token from SharedPreferences
  3. Decode JWT (jwt_decoder package)
     → Expired: go to LoginScreen
     → type = 'superadmin': go to DashboardScreen
     → type = 'academy': go to AcademyAdminDashboard
     → type = 'parent': go to ParentDashboard
     → No token: go to LoginScreen
```

### 12.2 Login Screen (`login_screen.dart`)

```
Fields: Username, Password
Validation:
  - Both fields required
  - No empty submit
Actions:
  - Login button → POST /auth/login → store JWT → navigate to Dashboard
  - "Academy Login" link → AcademyLoginScreen
Error handling:
  - "Invalid credentials" (401)
  - "Account locked" (403)
  - Network error → toast with friendly message
```

### 12.3 Academy Login Screen (`academy_login_screen.dart`)

```
Fields: Academy Code (slug), Email, Password
Validation:
  - All 3 fields required
  - Email format validated
Actions:
  - Login button → POST /academy/login → store JWT → AcademyAdminDashboard
Error handling:
  - "Invalid credentials"
  - "Academy not found"
  - Network error
```

### 12.4 Academy Admin Dashboard (`academy_admin_dashboard.dart`)

```
Header:
  - Academy name, admin greeting
  - Academic year dropdown (AcademicYearProvider)
    → Changing year filters all subsequent screens

Stats row:
  - Total Students
  - Present Today
  - Fees Collected This Month

Quick action grid:
  - Students
  - Face Scan Attendance
  - Fees
  - Courses
  - Academic Years
  - QR Codes
  - Bulk Upload
  - Reports

Offline banner (offline_banner.dart):
  - Appears when ConnectivityProvider reports offline
  - Does not block navigation (SQLite offline fallback)
```

### 12.5 Student Registration Screen (4-step wizard)

```
Step 1 — Personal Info
  Inputs: First Name, Last Name, DOB (date picker), Gender (dropdown), Mobile, Email
  Validator: Required fields + 10-digit mobile enforcement
  Button: Next

Step 2 — Parent & Address
  Inputs: Parent Name, Parent Mobile (10-digit), Address
  Button: Next (triggers background Phase 1 API call)

Step 3 — Courses
  Loads: Available courses for selected academic year
  UI: List with toggle + fee override
  Validator: Minimum 1 course
  Button: Next

Step 4 — Face Capture
  Camera: Front, medium resolution, NV21
  On-device: ML Kit face detection every frame
  Progress: 5 auto-captures required (hold face steady)
  Phase 2: PATCH /:id/face after 5 captures
  Success: "Registration complete!" → pop to student list

Error states:
  - Camera permission denied → "Enable in Settings" + Retry
  - Camera timeout → Retry button
  - Face not detected → quality hint
  - InsightFace failure → retry option; student saved without face
```

### 12.6 Face Scan Kiosk Screen (`academy_face_scan_screen.dart`)

```
Layout (dark theme):
  ├── Top bar: title, live clock
  ├── Camera preview (48% of screen height)
  │     └── FaceOverlayPainter: oval guide, coloured border by state
  ├── Mode buttons: CHECK IN (green) | CHECK OUT (orange)
  ├── Result card (last scan result)
  └── Session counters: In: X | Out: Y

States (FaceOverlayState):
  - idle: grey border, "Looking for face..."
  - detected: blue border, "Face detected — scanning..."
  - successCheckin: green border, student name shown
  - successCheckout: orange border, time and duration shown
  - unknown: red border, "Face Not Recognised"

Haptic feedback:
  - Success/duplicate: lightImpact()
  - Unknown/error: heavyImpact()

Debounce: 3s after success, 2s after failure
Camera error: shows videocam_off icon + Retry button
PopScope: canPop: false → always stop camera before pop
```

### 12.7 Fees Screen (`fees_screen.dart`)

```
Header: Summary cards (Due / Paid / Overdue count)
List: fee_records sorted overdue → pending → partial → paid
Filters: Month picker, Status dropdown
Actions per row:
  - Tap → expand to show detail + "Collect Fee" button
  - Collect Fee → bottom sheet:
      Amount to collect, Payment mode (Cash/UPI/Bank), Remarks
      Submit → POST /academy/fees/collect
  - Student name tap → StudentFeesDetailTab
```

### 12.8 Parent Dashboard (`parent_dashboard_screen.dart`)

```
Tab 1: Attendance
  - List of dates with time_in, time_out, duration, status indicator
  - Status chip: Present (green), Absent (red), Late (amber)
  - Pagination (load more)

Tab 2: Fees
  - Summary: Total Due, Total Paid, Balance
  - List of fee_records with due_date, status, course name
  - Status chip: Paid (green), Pending (amber), Overdue (red), Partial (blue)
```

### 12.9 User Actions Summary

| Screen | User Action | Result |
|--------|------------|--------|
| Login | Submit credentials | API call → JWT stored → navigate |
| Dashboard | Tap quick action | Navigate to sub-screen |
| Student List | Tap FAB | Open registration wizard |
| Student List | Tap student card | Open student detail |
| Student Detail | Tap "Edit" | Open edit screen |
| Student Detail | Tap "Recapture Face" | Open face recapture screen |
| Student Detail | Tap "Delete" | Confirm dialog → delete API call |
| Face Scan | Switch mode | Toggle check-in / check-out |
| Fees | Tap "Collect" | Open payment bottom sheet |
| Fees | Tap "Generate" | POST generate fees API call |
| Academic Years | Tap "Set Current" | PATCH set-current API call |
| QR Code | Tap "Activate" | PATCH activate API call |

### 12.10 Global Error Handling

- **No internet:** `offline_banner.dart` shown at top of screen; `network_aware_client.dart` queues or blocks API calls
- **API 401:** Token cleared, user redirected to login
- **API 5xx:** Toast with "Server error. Please try again."
- **Camera failure:** Friendly error + Retry button on face scan screens
- **Shimmer loading:** `shimmer_loader.dart` shown while API calls are in progress

---

## 13. Edge Cases

### 13.1 Duplicate Students

**Scenario:** Admin registers the same student twice (same mobile number).

**Current Behavior:**
- Phase 1 of registration runs `DELETE FROM students WHERE mobile = $1 AND face_embedding IS NULL` before inserting.
- If the existing student has a face (active student): DB UNIQUE violation on mobile → 409 returned.
- If the existing student is a ghost (no face, abandoned registration): ghost is deleted, new registration proceeds.

**Gap:** If two admins register the same student simultaneously, the race condition could create duplicates. No application-level mutex exists.

### 13.2 Duplicate Faces

**Scenario:** Two students have very similar faces or twins are registered.

**Current Behavior:**
- No duplicate face detection during registration. The system only checks similarity at scan time.
- At scan time, if two students have close embeddings, `reason = 'ambiguous_match'` is returned.

**Gap:** No proactive check at registration time to warn if a new student's face is too similar to an existing one.

### 13.3 Invalid / Missing Face Data

**Scenario:** Student registered but Phase 2 (face) failed — student exists in DB with `face_embedding = NULL`.

**Current Behavior:**
- Student cannot be identified by face scan (they won't appear in Redis cache)
- Student can still be found in student list and manually managed
- `face_recapture_screen.dart` can be used to attach a face later

### 13.4 Network Failures

**During Registration Phase 1 (student + courses):**
- If network fails before INSERT commits → no orphan created (transaction rolled back)
- User sees error toast; must retry

**During Registration Phase 2 (face):**
- Student already saved (ACF ID exists)
- Face not saved
- Admin can use "Recapture Face" later from student detail

**During Attendance Scan:**
- Flutter catches exception → `action: 'error'` displayed
- Attendance NOT recorded (backend never received request)
- User should retry

### 13.5 Camera Failures

**Initialization failure:** 
- `CameraAccessDenied` → prompt to enable in device Settings
- `NoCamera` → "No camera found on this device"
- `TimeoutException` (> 12 seconds) → "Camera took too long. Please try again."

**Mid-stream failure:** Frame processing error caught in try/catch; `_processingFrame = false` reset so next frame is processed.

**Stuck camera:** Stall detection: `_stallCheckTimer` tracks if no progress for > 12 seconds → shows retry UI.

### 13.6 WhatsApp Disconnection

**Scenario:** WhatsApp session disconnects mid-day (phone battery dead, WhatsApp update, etc.)

**State:** `DISCONNECTED → RECONNECTING`

**Impact:** No notification messages sent; attendance records still saved normally.

**Recovery:** Auto-reconnect attempted with exponential backoff → if fails, state = `QR_PENDING` → admin must re-scan QR.

**Manual check:** `GET /whatsapp/status` → `{ connected: false }` → admin re-scans.

### 13.7 Redis Cache Cleared / Lost

**Scenario:** Redis restarts and loses all cached face embeddings.

**Impact:** All face scans return `reason: 'no_registered_faces'` or `below_threshold`.

**Recovery:** On InsightFace service startup, `reload_from_db()` is called automatically → reads all `face_embedding` JSONB values from PostgreSQL → loads into Redis. This takes a few seconds; scans will fail during this window.

**Hourly reconciliation:** `POST /cache/reconcile` removes stale entries without full reload — cheaper than reload but cannot restore lost entries.

### 13.8 Invalid / Corrupted Embedding

**Scenario:** Face embedding stored in DB is malformed (partial JSON, wrong dimensions).

**Current Behavior:** InsightFace service would fail to parse it during cache reload → log error for that student_id → other students unaffected.

**Gap:** No validation of embedding dimensions or normalization on write.

### 13.9 Academy Schema Missing Columns

**Scenario:** Academy was created before a new column was added (e.g., `parent_fcm_token` added in a later version).

**Handling:** `reconcileAcademySchemas()` runs on every server boot and runs `ALTER TABLE IF EXISTS ... ADD COLUMN IF NOT EXISTS ...` for all known migration gaps. This is safe to run repeatedly.

### 13.10 Face Scan on Inactive Student

**Scenario:** Student's status changed to 'inactive' but their embedding is still in Redis.

**Handling:**
```typescript
const dbStudent = await queryOne(`SELECT id, status FROM students WHERE id = $1`, [studentId]);
if (!dbStudent || dbStudent.status !== 'active') {
  return res.json({ success: false, action: 'unknown', message: 'Student not found or inactive.' });
}
```
The face is matched but attendance is NOT recorded. Student must be reactivated first.

---

## 14. Bug Analysis

### Bug #1 — WhatsApp Session Lost on Render Restart

**Current Behavior:** Every time the Render service restarts (deploy, idle timeout, crash), the WhatsApp session is lost because `.wwebjs_auth/` lives on ephemeral disk. Admin must manually re-scan QR code.

**Expected Behavior:** Session persists across restarts without manual intervention.

**Root Cause:** Render's free/starter tier uses ephemeral (non-persistent) disk storage. The LocalAuth strategy saves session to filesystem which is wiped on restart.

**Proposed Solution:**
- Store session state in PostgreSQL (`whatsapp_sessions` table already exists)
- Implement a custom `RemoteAuth` strategy using the DB as session store
- Or: Upgrade to Render persistent disk (paid tier)

**Database Impact:** `whatsapp_sessions` table needs session data columns

**API Impact:** None (internal change)

**UI Impact:** Admin would no longer need to re-scan QR after every restart

**Testing Scenarios:**
1. Deploy new version → WhatsApp stays connected
2. Render restarts due to idle → WhatsApp reconnects automatically
3. Manual restart → connection restored without admin intervention

**Acceptance Criteria:** Admin scans QR once; service reconnects automatically on all subsequent restarts for at least 7 days.

---

### Bug #2 — Ambiguous Match Not Providing Actionable Resolution

**Current Behavior:** When `action = 'ambiguous'`, the UI shows a message but gives no option to escalate (e.g., manually identify the student).

**Expected Behavior:** On ambiguous match, admin should see a list of possible students and select the correct one to manually record attendance.

**Root Cause:** The backend returns the top 2 candidate student IDs when ambiguous, but the frontend does not display or use them.

**Proposed Solution:**
- Backend: include `candidates: [{student_id, first_name, last_name, confidence}]` in ambiguous response
- Flutter: on `action = 'ambiguous'`, show a "Select Student" dialog with candidate list
- On selection: POST manual attendance record

**Database Impact:** None

**API Impact:** Modify scan response schema to include `candidates` array

**UI Impact:** New dialog component on `academy_face_scan_screen.dart`

**Testing Scenarios:**
1. Ambiguous scan → candidates shown → correct student selected → attendance recorded
2. Cancel selection → no attendance recorded
3. Single candidate → no dialog, direct match

**Acceptance Criteria:** Admin can resolve all ambiguous scans without leaving the kiosk screen.

---

### Bug #3 — Student ID Sequence Uses LIKE on Every Registration

**Current Behavior:**
```sql
SELECT MAX(CAST(SUBSTRING(id FROM LENGTH($1) + 1) AS INTEGER)) AS max_seq
FROM students WHERE id LIKE 'ACF-2026-%'
```
This runs a full table scan on every registration when the student count is large.

**Expected Behavior:** ID generation should be O(1), not O(n).

**Root Cause:** No sequence or serial column; ID is generated by scanning existing rows.

**Proposed Solution:**
- Add a PostgreSQL SEQUENCE per academy (e.g., `academy_student_seq`)
- Or use `SERIAL` / `GENERATED ALWAYS AS IDENTITY` for the numeric part
- Keep the `ACF-YYYY-` prefix format

**Database Impact:** New sequence object per academy schema

**API Impact:** None (internal change)

**UI Impact:** None

**Testing Scenarios:**
1. Register 1000 students → IDs generated correctly without collision
2. Delete student 500 → next registration gets 1001, not 500
3. Year changes to 2027 → sequence resets for new prefix

**Acceptance Criteria:** Registration response time does not degrade with academy size.

---

### Bug #4 — No Proactive Duplicate Face Check at Registration

**Current Behavior:** Two students with very similar faces can both be registered. The duplicate is only discovered at scan time via `ambiguous_match`.

**Expected Behavior:** During registration, warn the admin if the new student's face is too similar to an existing registered student.

**Root Cause:** The `POST /embed/batch` call at registration does not perform a similarity check against existing embeddings — only embedding generation.

**Proposed Solution:**
- After generating the new embedding, call `POST /match` to check if it matches any existing student above a warning threshold (e.g., 0.70, lower than the 0.75 match threshold)
- If a potential duplicate is found, return a warning with the matched student's name/ID
- Admin can proceed (override) or go back

**Database Impact:** None

**API Impact:** New optional response field `{ duplicate_warning: { student_id, name, confidence } }` on `POST /academy/students`

**UI Impact:** Warning dialog in registration step 4 if duplicate detected

**Testing Scenarios:**
1. Register identical photo → warning shown with matching student
2. Register different person → no warning
3. Twins registered → warning shown; admin confirms both are valid

**Acceptance Criteria:** Duplicate warning triggers for cosine similarity ≥ 0.70 during registration.

---

### Bug #5 — Auto Fee Generation Not Automated (Manual Trigger)

**Current Behavior:** Admin must manually tap "Generate Fees" button every month to create fee records.

**Expected Behavior:** Fees should be auto-generated on the 1st of every month.

**Root Cause:** No cron job or scheduler exists. `POST /api/academy/fees/generate` is a manual API call.

**Proposed Solution:**
- Add a Node.js cron job (using `node-cron`) that runs at `00:01 on the 1st of every month`
- Iterates over all active academies
- Calls `generateMonthlyFees()` for each

**Database Impact:** None (uses existing `fee_records` logic with ON CONFLICT guard)

**API Impact:** None (internal cron, not a new endpoint)

**UI Impact:** Admin still sees the manual "Generate" button as a fallback

**Testing Scenarios:**
1. 1st of month → fee records auto-generated for all active academies
2. Manual trigger after auto-generation → no duplicates created
3. Academy with no active enrollments → zero records generated, no error

**Acceptance Criteria:** Fee records for all active student-course enrollments exist by 00:05 on the 1st of each month.

---

### Bug #6 — Face Scan Screen Hangs if Camera Permission Previously Denied

**Current Behavior:** If the user previously denied camera permission and opens the face scan screen, the `initialize()` call throws `CameraAccessDenied` but in some Android versions the error is swallowed and the screen shows an infinite loading spinner instead of the "Enable in Settings" UI.

**Expected Behavior:** Always show the camera error UI with "Enable in Settings" + Retry.

**Root Cause:** The `availableCameras()` call returns an empty list (not an exception) on some Android builds when permission is denied, but the code path expecting `CameraException` never fires. The empty-list check exists but only throws a `CameraException('NoCamera', ...)` — this path shows "No camera found" instead of the permission message.

**Proposed Solution:**
- Before `availableCameras()`, explicitly check permission status using `permission_handler` package
- If denied → directly show "Camera permission denied" UI without attempting init
- If permanently denied → show "Open Settings" button that launches app settings

**Database Impact:** None

**API Impact:** None

**UI Impact:** Correct error message shown on first open after denial

**Testing Scenarios:**
1. Deny permission on first launch → correct error shown
2. Grant permission after denial → camera starts
3. Permanently deny → "Open Settings" button shown

**Acceptance Criteria:** No infinite spinner. Correct error + action button shown within 1 second of screen open when permission is denied.

---

## 15. Implementation Plan

### 15.1 Module-Wise Breakdown

| Module | Status | Description |
|--------|--------|-------------|
| Authentication (Super Admin) | ✅ Complete | Login, OTP reset, JWT |
| Academy Management | ✅ Complete | Create, activate, deactivate, delete |
| Student Registration | ✅ Complete | 4-step wizard, 2-phase save |
| Face Recognition Engine | ✅ Complete | ArcFace, Redis cache, quality gates |
| Attendance — Face Scan | ✅ Complete | Check-in/out, duplicate prevention |
| Attendance — Manual | ✅ Complete | Manual entry and override |
| Course Management | ✅ Complete | CRUD, academic year link |
| Academic Year Management | ✅ Complete | CRUD, set current |
| Fees — Manual Generate | ✅ Complete | On-demand generation |
| Fees — Collection | ✅ Complete | Collect, status machine |
| Fee Slip PDF | ✅ Complete | In-app PDF generation |
| Parent Portal | ✅ Complete | 2-step login, attendance + fee view |
| WhatsApp Notifications | ✅ Complete | Check-in/out, custom messages |
| QR Code Management | ✅ Complete | Generate, activate |
| Bulk Upload | ✅ Complete | Excel import |
| Reports | ✅ Complete | Attendance + fee reports |
| Offline Support | ✅ Complete | SQLite + sync service |

### 15.2 Recommended Development Order for Remaining Work / Fixes

```
Priority 1 — Critical Fixes (affects daily operations)
  1. Fix camera permission detection (Bug #6) — 0.5 day
  2. WhatsApp session persistence across restarts (Bug #1) — 2 days
  3. Auto fee generation cron (Bug #5) — 1 day

Priority 2 — Quality Improvements
  4. Ambiguous match resolution UI (Bug #2) — 2 days
  5. Duplicate face warning at registration (Bug #4) — 1.5 days

Priority 3 — Performance
  6. Student ID generation using PostgreSQL SEQUENCE (Bug #3) — 1 day
```

### 15.3 Dependencies Between Modules

```
academic_years ──────────► courses ──────────► student_courses ──────────► fee_records
                                                      │
                                                 students ────────────────► attendance
                                                      │
                                               face_embedding ────────────► Redis cache
                                                                                │
                                                                         attendance scan
```

- Courses depend on Academic Years (FK)
- Student enrollment depends on both Students and Courses
- Fee records depend on Student enrollment
- Face scan attendance depends on Redis cache (which depends on student face embedding)
- WhatsApp notifications depend on Attendance events and parent mobile numbers

### 15.4 Testing Strategy

**Unit Tests:**
- Face embedding quality gate logic (`face_analyzer.py`)
- Fee status machine transitions
- Student ID generation uniqueness under concurrent inserts
- JWT payload validation

**Integration Tests:**
- Student registration end-to-end (all 4 steps → DB record + Redis entry)
- Face scan → attendance record created
- Fee generation → correct records for active enrollments only
- Parent login 2-step → dashboard accessible

**Manual QA Scenarios:**
- Register 2 students → scan both → correct identification
- Register student without face → scan → unknown (correct)
- Scan twice within 10 minutes → duplicate blocked
- Checkout without check-in → error shown
- Generate fees for month → collect partial → collect rest → status = paid
- WhatsApp: connect → check-in → notification received
- Offline mode: student list loads from SQLite
- Academy deactivated → academy users cannot log in

### 15.5 Deployment Strategy

**Current Setup:**
```
Render:
  ├── eduscan-backend    (Node.js web service, auto-deploy on push to main)
  ├── eduscan-insightface (Python web service, auto-deploy on push to main)
  └── eduscan-redis      (Managed Redis instance)

Neon PostgreSQL:
  └── Single database, schema-per-academy

Flutter:
  └── Build APK / IPA → manual upload to Play Store / App Store
```

**Deployment Checklist:**
1. Set all required environment variables in Render dashboard (NOT in render.yaml — `sync: false` means dashboard-only)
2. `DATABASE_URL` — Neon connection string
3. `JWT_SECRET` — strong random string
4. `INSIGHTFACE_URL` — URL of eduscan-insightface service
5. `REDIS_URL` — Render Redis internal URL
6. `FIREBASE_CREDENTIALS` — FCM service account JSON
7. `WA_SESSION_PATH`, `WA_CLIENT_ID` — WhatsApp session config

**Zero-Downtime Deploy:**
- `reconcileAcademySchemas()` runs on startup — idempotent, safe for rolling deploy
- `runMigrations()` uses `IF NOT EXISTS` throughout — safe to run multiple times
- No destructive schema changes in current codebase

**Monitoring:**
- `GET /api/health` → DB connectivity check
- `GET /health` (InsightFace) → model readiness check
- `GET /whatsapp/status` → WhatsApp connection state
- Render dashboard → CPU/memory metrics, log streaming

---

## Appendix A — Environment Variables Reference

### Backend (`backend/.env`)
```env
DATABASE_URL=postgresql://user:pass@host/dbname?sslmode=require
JWT_SECRET=<strong_random_string_min_32_chars>
PORT=3000
NODE_ENV=production
INSIGHTFACE_URL=https://eduscan-insightface.onrender.com
REDIS_URL=redis://...
FIREBASE_CREDENTIALS=<base64_encoded_service_account_json>
RENDER_EXTERNAL_URL=https://eduscan-backend.onrender.com
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your@email.com
SMTP_PASS=app_password
```

### InsightFace Service (`insightface-service/.env`)
```env
DATABASE_URL=postgresql://...
REDIS_URL=redis://...
MODEL_NAME=buffalo_sc
MATCH_THRESHOLD=0.75
MARGIN_THRESHOLD=0.05
MIN_FACE_SIZE_PX=60
MAX_YAW_DEG=35
```

### WhatsApp Service
```env
WA_SESSION_PATH=./.wwebjs_auth
WA_CLIENT_ID=eduscan-wa
DATABASE_URL=postgresql://...
```

---

## Appendix B — Key File Locations

| File | Path | Purpose |
|------|------|---------|
| Main migrations | [backend/src/db/migrations.ts](backend/src/db/migrations.ts) | Shared schema |
| Academy migrations | [backend/src/db/academyMigrations.ts](backend/src/db/academyMigrations.ts) | Per-academy schema |
| Pool manager | [backend/src/db/poolManager.ts](backend/src/db/poolManager.ts) | PgBouncer-safe query runner |
| Scan controller | [backend/src/controllers/scanController.ts](backend/src/controllers/scanController.ts) | Attendance face scan |
| Fee controller | [backend/src/controllers/academy/feeController.ts](backend/src/controllers/academy/feeController.ts) | Fee management |
| Student controller | [backend/src/controllers/academy/studentController.ts](backend/src/controllers/academy/studentController.ts) | Student CRUD + registration |
| InsightFace routes | [insightface-service/app/routes.py](insightface-service/app/routes.py) | Face API endpoints |
| Face analyzer | [insightface-service/app/face_analyzer.py](insightface-service/app/face_analyzer.py) | ArcFace model wrapper |
| Redis cache | [insightface-service/app/redis_cache.py](insightface-service/app/redis_cache.py) | Embedding cache |
| WhatsApp service | [whatsapp-api/src/services/whatsappService.js](whatsapp-api/src/services/whatsappService.js) | WA client lifecycle |
| Face scan screen | [lib/screens/academy/academy_face_scan_screen.dart](lib/screens/academy/academy_face_scan_screen.dart) | Kiosk UI |
| Registration screen | [lib/screens/academy/academy_student_registration_screen.dart](lib/screens/academy/academy_student_registration_screen.dart) | 4-step wizard |
| Parent login | [lib/screens/academy/parent_login_screen.dart](lib/screens/academy/parent_login_screen.dart) | 2-step parent auth |
| API endpoints | [lib/constants/api_endpoints.dart](lib/constants/api_endpoints.dart) | All API URLs (Flutter) |
| Auth provider | [lib/providers/auth_provider.dart](lib/providers/auth_provider.dart) | Auth state (Flutter) |
| Face service | [lib/services/face_service.dart](lib/services/face_service.dart) | On-device face detection |
| Academy API service | [lib/services/academy_api_service.dart](lib/services/academy_api_service.dart) | Academy HTTP client |
| Render config | [render.yaml](render.yaml) | Production deployment |

---

*End of EduScan Complete System Documentation*
*This document reflects the codebase as of 2026-06-05 and must be updated whenever significant features are added or changed.*
