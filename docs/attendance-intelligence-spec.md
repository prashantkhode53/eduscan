# EduScan — Attendance Intelligence (v1) — spec

Read-only analytics over the existing per-academy `attendance` table. **No schema
change, no migrations, no new tables. Admin-only UI. Daily model (no per-session
features).**

---

## Hard constraints

1. **No schema change / migrations / new tables.** Everything is read-only SQL
   aggregation over the existing per-academy `attendance` table
   (`UNIQUE(student_id, date)`, one row per student per day).
2. **Admin-only.** New screens are tiles on `academy_admin_dashboard.dart`. No new
   parent screens. Parent alerts reuse the existing fire-and-forget FCM helper
   (`sendFcm` in `backend/src/utils/fcm.ts`). No SMS/WhatsApp.
3. **Daily model.** No per-session / per-subject / test-type features in v1.

---

## Data source (confirmed by verify pass)

The only v1 source is the per-academy `attendance` table:

| Column | Type | Notes |
|---|---|---|
| `student_id` | VARCHAR(20) FK | e.g. `ACF-2026-00001` |
| `date` | DATE | pg returns a JS `Date`, not a string |
| `time_in` / `time_out` | TIME | `HH:MM:SS` string from pg, server-clock UTC |
| `duration_mins` | INT | |
| `status` | `present\|absent\|late\|holiday` | rows are upserted on check-in |
| `checkin_mode` / `checkout_mode` | VARCHAR | |
| `confidence_in` / `confidence_out` | DECIMAL | |

No marks/results, homework, tests/exams, or grades modules exist anywhere in the
repo, so attendance-vs-marks, test-participation, and homework factors are
**out of scope** for v1. (`fee_records` exists but v1 stays attendance-only per
Part C; fee discipline is the first factor to add later.)

### Attendance % denominator — DECISION

There is no working-days calendar table and rows are only reliably written on the
days students attend (`present`/`late`). The denominator for attendance % is:

> **open days** = `COUNT(DISTINCT date)` across the whole academy in the window,
> excluding `status = 'holiday'`.

A student's attendance % = `(their present + late days) / open days * 100`. This is
self-calibrating (it learns which days the academy was actually open), needs no
schema change, and correctly treats a student's missing open-days as absences.

---

## Attendance Score v1 (re-normalized)

Pure function. Only factors with real data; v1 default weights:

| Factor | Weight | Source |
|---|---|---|
| Attendance % | 50 | (present + late) / open days |
| Punctuality | 25 | late-day rate (lower late rate → higher score) |
| Regularity & recent trend | 25 | consecutive absences + recent-vs-prior decline |

Bands: **Green ≥85 · Yellow 70–84 · Orange 50–69 · Red <50**. Returns the
per-factor breakdown. Do not hard-code v1 weights — they are declared in one place
so the original 40/20/15/10/10/5 weighting can be restored once marks/homework/fee
modules are confirmed.

---

## Logic specs

**Patterns** (rolling window, default 8 weeks): Monday/weekend absentee, seasonal
dip, late-comer (>50% late days), consecutive-absence run (≥3), sharp drop (recent
vs prior window), not-seen-in-X-days.

**Defaulter workflow** (thresholds on attendance %): `<85` FCM nudge · `<75` FCM +
Today-list flag · `<65` counselor-call task · `<50` parent-meeting task · `<40`
recovery-plan note. Reuse `sendFcm`; de-dupe / rate-limit per stage.

**Risk band** (Low/Med/High — never a %): weighted over attendance %, trend slope,
consecutive absences, late rate, days-since-last-seen. Returns top factors.

---

## Code layout

- **Backend:** read-only controllers under `backend/src/controllers/academy/`
  (e.g. `attendanceInsightsController.ts`), GET routes under
  `/api/academy/attendance-insights`. All scoring lives in a separate, unit-tested
  pure module: `backend/src/services/attendanceScoring.ts`
  (tests: `attendanceScoring.test.ts`, run with `npm test` → Node's built-in
  `node:test`). SQL aggregation only; tenancy via `academyQuery` from
  `poolManager.ts`.
- **Flutter (admin):** new **"Attendance"** tile in the Quick Actions grid on
  `academy_admin_dashboard.dart` → `AttendanceHubScreen` (tabbed: Today /
  Students / Defaulters; tapping a student → score detail).
- **Flutter (parent):** the existing **"Last 30 Days"** history card header on
  `parent_dashboard_screen.dart` becomes tappable ("View all →") → opens
  `ParentAttendanceScreen` (month + date-range filters, **Excel download**).

---

## UI map (approved)

### Admin — Academy Login → Quick Actions → "Attendance"

`AttendanceHubScreen`, tabbed:

| Tab | Contents | Actions |
|---|---|---|
| **Today** (default) | Action-list cards: below 85%, ≥3 consecutive absences, sharp drop, not-seen-in-X-days | per-student **"Nudge parent"** button (manual, one `sendFcm`) |
| **Students** | Searchable list; band chip (Green/Yellow/Orange/Red) + attendance %; year/course filter | tap → Student score detail |
| **Defaulters** | Grouped by stage (<85 nudge … <40 recovery) | **Nudge** / **Mark task done** |
| **Student detail** | Score gauge + per-factor breakdown (50/25/25), Risk band (Low/Med/High **+ factors, never a %**), pattern badges, month heatmap | **Nudge parent**, **Download (Excel)** |

### Parent — Dashboard → "Last 30 Days" card → "View all →"

`ParentAttendanceScreen`:

- **Month filter** (YYYY-MM picker) with summary (Present/Absent/Late/%).
- **Date-range filter** (From–To).
- Records list (date · day · in/out · duration · status chip).
- **Download → Excel (.xlsx)** via the `fee_excel_service` pattern, opened with
  `file_opener.dart`. File: `Attendance_<ChildName>_<period>.xlsx`. Generated
  on-device from fetched rows — **no new file-serving endpoint.**

---

## Decisions (approved)

- **Parent download format:** Excel (.xlsx) only.
- **Nudge:** manual admin button only (one `sendFcm` per tap). No auto-nudge →
  avoids needing a "last nudged stage" store under the no-schema-change rule.
  Natural de-dupe (admin won't re-tap).
- **Parent entry point:** tappable "Last 30 Days" history card (not AppBar icon).

---

## Endpoints (additive — no schema change)

**Admin** — all under `academyAuthMiddleware` + `requireRole('admin','teacher')`,
scoped to the caller's academy schema:

| Method | Path | Returns |
|---|---|---|
| GET | `/api/academy/attendance-insights/today` | Today action list (below threshold, ≥3 consecutive absences, sharp drops, not-seen-in-X-days) |
| GET | `/api/academy/attendance-insights/students` | Paged student list with score band + attendance % |
| GET | `/api/academy/attendance-insights/:studentId/score` | Attendance Score + per-factor breakdown + risk + patterns for one student |
| GET | `/api/academy/attendance-insights/defaulters` | Students grouped by defaulter stage |

**Parent** — under `parentAuthMiddleware`, scoped to the parent's own
`studentId`/academy. **Extend the existing** `GET /api/academy/parent/attendance`
(currently `days`-only) to also accept `month=YYYY-MM` or `from`/`to`. No new
parent endpoint; download is client-side from the returned rows.

> Nudge reuses the existing `sendFcm` helper in `attendanceController.ts`; no new
> alert endpoint, no new table.
