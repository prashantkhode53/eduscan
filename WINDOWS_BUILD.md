# EduScan — Windows Desktop Build

This document describes the Windows desktop build of EduScan: how to build it,
what works, what is intentionally excluded, and why.

The Windows build ships the **management-console subset** of EduScan. It uses the
**same source code, same backend, and same database** as the Android app. All
Windows-specific differences are additive guards (`PlatformSupport.*` /
`Platform.isWindows`) — **the Android app and its APK are unchanged.**

---

## Prerequisites

1. **Flutter** (already used for the Android build).
2. **Visual Studio** (Community is fine) with the **"Desktop development with
   C++"** workload, including default components. This provides the MSVC
   toolchain Flutter uses to compile the Windows runner.
   - Verify with `flutter doctor` — the line
     `[√] Visual Studio - develop Windows apps` must be present.
   - Without it, `flutter build windows` fails at the native compile step.

> Note: scaffolding and all Dart code work were completed without Visual Studio
> (`flutter analyze` passes). VS is required only to *compile/run* the Windows
> app and to *package* the installer.

---

## Build

```sh
# 1. Resolve dependencies (once)
flutter pub get

# 2. Build the release executable
flutter build windows --release
```

Output (portable form — ship the whole folder, not just the .exe):

```
build/windows/x64/runner/Release/
  eduscan.exe
  *.dll
  data/
```

### Installer (.msix)

```sh
dart run msix:create
```

Produces `eduscan.msix` in `build/windows/x64/runner/Release/`. Config lives in
`pubspec.yaml` under `msix_config`. (An Inno Setup `Setup.exe` is an alternative
if a classic wizard installer is preferred.)

---

## What works on Windows (management console)

- Super Admin: login / OTP / password reset, dashboard, manage/register/view
  academies.
- Academy: login, admin dashboard.
- Students: list, detail, search, filter.
- **Student import**: bulk CSV/Excel upload (pick → parse → upload).
- Course master, academic-year master.
- Fees: view, collect, installments; PDF statements/receipts; **Excel export**.
- QR code generation.
- Attendance: viewing.
- Reports: viewing + PDF/CSV export.
- Parent dashboard (view attendance/fees — *not* the face login).
- Settings; offline SQLite cache; all API/auth/storage.

File save-and-open (PDF/Excel/CSV) works via a cross-platform helper
(`lib/utils/file_opener.dart`): mobile uses `open_filex`; Windows opens the file
through Explorer (because `open_filex` has no Windows implementation).

The offline SQLite cache works on Windows via `sqflite_common_ffi`, initialised
only on Windows in `lib/main.dart` (Android keeps the native `sqflite` plugin).

---

## What is EXCLUDED on Windows (and why)

These depend on mobile-only plugins with **no Windows support**. Their entry
points are hidden on Windows; the underlying screens are untouched (so Android is
unaffected). A safety-net "Not available on Windows" screen
(`lib/screens/windows_unsupported_screen.dart`) catches any deep-linked route.

| Excluded feature | Reason (plugin) |
|---|---|
| Student face registration (admin + legacy) | `camera` image stream + `google_mlkit_face_detection` |
| Student face re-capture | same |
| Live face-scan attendance / school check-in–out | same |
| Parent face-verified login | same |
| Push notifications (FCM) | `firebase_messaging` (no Windows entry) |
| Voice feedback (TTS) | only used by the face-scan screen, which is already excluded |

All of the above remain fully functional in the Android app.

### Consequence for student management on Windows

Single student registration and student **edit** both require the on-device face
wizard, so both are hidden on Windows. Add students on Windows via **bulk
Excel/CSV upload** (Dashboard → Register Student → Upload Excel). Viewing student
detail still works.

---

## How Android is kept unaffected

- A Windows build only added a `windows/` folder; `android/`, `lib/` screen
  internals, and the APK build are untouched.
- All platform differences are **additive**: new `if (PlatformSupport.*)` /
  `if (Platform.isWindows)` branches that evaluate to the original behaviour on
  Android.
- New deps are additive: `sqflite_common_ffi` (wired only inside
  `if (Platform.isWindows)`) and the `msix` **dev** dependency (build-time only,
  never bundled into the APK).

### Verify the APK still builds

```sh
flutter build apk --release
```

This should produce the same working APK as before these changes.

---

## Files changed for the Windows build

- `lib/main.dart` — Windows guards for Firebase/FCM/orientation; sqflite FFI init.
- `lib/utils/platform_support.dart` — *new*; feature-availability flags.
- `lib/utils/file_opener.dart` — *new*; cross-platform "open saved file".
- `lib/screens/windows_unsupported_screen.dart` — *new*; route safety net.
- `lib/app.dart` — face routes show the unsupported screen on Windows.
- Entry-point guards in: `academy_admin_dashboard.dart`,
  `academy/academy_student_list_screen.dart`, `student_detail_screen.dart`,
  `student_list_screen.dart`, `login_screen.dart`.
- `OpenFilex.open(...)` → `FileOpener.open(...)` in the 6 PDF/Excel/CSV files.
- `pubspec.yaml` — `sqflite_common_ffi` dep, `msix` dev dep, `msix_config`.
