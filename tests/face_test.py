#!/usr/bin/env python3
"""
EduScan face recognition integration test.

Downloads AI-generated face images (thispersondoesnotexist.com),
registers N students, then tests check-in and check-out scans.

Usage:
    pip install httpx
    python tests/face_test.py

Environment variables (all optional):
    BACKEND_URL      default: https://eduscan-j4cg.onrender.com
    ADMIN_USERNAME   default: admin
    ADMIN_PASSWORD   required — set this
    NUM_STUDENTS     default: 10  (max 50 recommended for free-tier)
    SKIP_DOWNLOAD    set to 1 to reuse previously downloaded faces
"""

import asyncio
import base64
import json
import os
import random
import time
from pathlib import Path

import httpx

# ── Config ─────────────────────────────────────────────────────────────────────

BACKEND_URL    = os.getenv("BACKEND_URL", "https://eduscan-j4cg.onrender.com")
ADMIN_USERNAME = os.getenv("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "")
NUM_STUDENTS   = int(os.getenv("NUM_STUDENTS", "10"))
SKIP_DOWNLOAD  = os.getenv("SKIP_DOWNLOAD", "0") == "1"
FACES_DIR      = Path("tests/test_faces")

FIRST_NAMES = ["Aarav", "Priya", "Ravi", "Sneha", "Kiran", "Meera",
               "Arjun", "Pooja", "Rohan", "Nisha", "Vijay", "Anita",
               "Suresh", "Kavya", "Rahul", "Divya", "Anil", "Sonal"]
LAST_NAMES  = ["Sharma", "Patel", "Singh", "Kumar", "Gupta", "Mehta",
               "Shah", "Verma", "Joshi", "Nair", "Reddy", "Iyer"]
CLASSES     = ["1", "2", "3", "4", "5", "6", "7", "8"]
DIVISIONS   = ["A", "B", "C"]

# ── Colour helpers ─────────────────────────────────────────────────────────────

GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
RESET  = "\033[0m"
BOLD   = "\033[1m"

def ok(msg):  print(f"  {GREEN}✓{RESET} {msg}")
def fail(msg): print(f"  {RED}✗{RESET} {msg}")
def warn(msg): print(f"  {YELLOW}!{RESET} {msg}")

# ── Helpers ────────────────────────────────────────────────────────────────────

def b64(path: Path) -> str:
    return base64.b64encode(path.read_bytes()).decode()

def rand_student() -> dict:
    return {
        "first_name":    random.choice(FIRST_NAMES),
        "last_name":     random.choice(LAST_NAMES),
        "mobile":        f"98{random.randint(10000000, 99999999)}",
        "parent_name":   f"Parent {random.choice(LAST_NAMES)}",
        "gender":        random.choice(["male", "female"]),
        "dob":           "2010-06-15",
        "class_grade":   random.choice(CLASSES),
        "division":      random.choice(DIVISIONS),
        "roll_no":       random.randint(1, 99),
        "academic_year": "2025-26",
        "institution":   "EduScan Test School",
    }

# ── Download faces ─────────────────────────────────────────────────────────────

async def download_faces(n: int, client: httpx.AsyncClient) -> list[Path]:
    FACES_DIR.mkdir(parents=True, exist_ok=True)
    paths = []
    print(f"\nDownloading {n} AI-generated face images…")
    for i in range(n):
        path = FACES_DIR / f"face_{i:03d}.jpg"
        if SKIP_DOWNLOAD and path.exists():
            print(f"  [{i+1:2d}/{n}] Using cached {path.name}")
            paths.append(path)
            continue
        downloaded = False
        for attempt in range(3):
            try:
                r = await client.get(
                    "https://thispersondoesnotexist.com",
                    headers={"User-Agent": "Mozilla/5.0"},
                    timeout=20,
                    follow_redirects=True,
                )
                if r.status_code == 200 and len(r.content) > 5000:
                    path.write_bytes(r.content)
                    print(f"  [{i+1:2d}/{n}] {path.name}  {len(r.content)//1024}KB")
                    paths.append(path)
                    downloaded = True
                    break
                warn(f"[{i+1}/{n}] HTTP {r.status_code}, retrying…")
            except Exception as e:
                warn(f"[{i+1}/{n}] attempt {attempt+1} error: {e}")
            await asyncio.sleep(2)
        if not downloaded:
            fail(f"Could not download face {i+1}")
        await asyncio.sleep(1.2)  # polite delay
    return paths

# ── Auth ───────────────────────────────────────────────────────────────────────

async def login(client: httpx.AsyncClient) -> str:
    r = await client.post(
        f"{BACKEND_URL}/api/auth/login",
        json={"username": ADMIN_USERNAME, "password": ADMIN_PASSWORD},
        timeout=15,
    )
    body = r.json()
    token = (body.get("data") or {}).get("token") or body.get("token")
    if not token:
        raise RuntimeError(f"Login failed ({r.status_code}): {r.text[:300]}")
    ok(f"Logged in as '{ADMIN_USERNAME}'")
    return token

async def get_kiosk_key(client: httpx.AsyncClient, token: str) -> str:
    r = await client.get(
        f"{BACKEND_URL}/api/settings",
        headers={"Authorization": f"Bearer {token}"},
        timeout=15,
    )
    settings = (r.json().get("data") or {})
    key = settings.get("kiosk_api_key", "")
    if not key:
        raise RuntimeError("kiosk_api_key not found in settings")
    ok(f"Kiosk key: {key[:8]}…")
    return key

# ── Student registration ───────────────────────────────────────────────────────

async def register_student(
    client: httpx.AsyncClient,
    token: str,
    face_path: Path,
) -> dict:
    payload = rand_student()
    face_b64 = b64(face_path)
    payload["face_images"] = [face_b64] * 5  # 5 samples from same image

    r = await client.post(
        f"{BACKEND_URL}/api/students",
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
        timeout=90,  # InsightFace cold-start can take 60s
    )
    if r.status_code not in (200, 201):
        raise RuntimeError(f"HTTP {r.status_code}: {r.text[:300]}")

    body = r.json()
    data = body.get("data") or body
    # Response may wrap student under data.student or return flat
    student = data.get("student") or data
    sid = student.get("id") or student.get("_id")
    if not sid:
        raise RuntimeError(f"No id in response: {json.dumps(data)[:200]}")
    return {
        "id":         sid,
        "name":       f"{payload['first_name']} {payload['last_name']}",
        "face_path":  face_path,
    }

# ── Scan ───────────────────────────────────────────────────────────────────────

async def scan(
    client: httpx.AsyncClient,
    kiosk_key: str,
    face_path: Path,
    mode: str,
) -> dict:
    r = await client.post(
        f"{BACKEND_URL}/api/attendance/scan",
        json={
            "image_base64": b64(face_path),
            "mode":         mode,
            "timestamp":    time.strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
        headers={"X-Kiosk-Key": kiosk_key},
        timeout=25,
    )
    return r.json()

# ── Main ───────────────────────────────────────────────────────────────────────

async def main():
    if not ADMIN_PASSWORD:
        print(f"{RED}ERROR: Set ADMIN_PASSWORD environment variable.{RESET}")
        print("  e.g.  ADMIN_PASSWORD=yourpassword python tests/face_test.py")
        return

    print(f"\n{BOLD}{'='*60}{RESET}")
    print(f"{BOLD}  EduScan Face Recognition Integration Test{RESET}")
    print(f"  Backend : {BACKEND_URL}")
    print(f"  Students: {NUM_STUDENTS}")
    print(f"{BOLD}{'='*60}{RESET}")

    async with httpx.AsyncClient() as client:

        # ── Auth ──────────────────────────────────────────────────────────────
        print(f"\n{BOLD}[AUTH]{RESET}")
        try:
            token     = await login(client)
            kiosk_key = await get_kiosk_key(client, token)
        except Exception as e:
            print(f"{RED}Auth failed: {e}{RESET}")
            return

        # ── Download faces ────────────────────────────────────────────────────
        face_paths = await download_faces(NUM_STUDENTS, client)
        if not face_paths:
            print(f"{RED}No faces downloaded. Aborting.{RESET}")
            return

        # ── Register students ─────────────────────────────────────────────────
        print(f"\n{BOLD}[PHASE 1 — Registration] ({len(face_paths)} students){RESET}")
        students = []
        reg_pass = reg_fail = 0
        for i, fp in enumerate(face_paths):
            label = f"[{i+1:2d}/{len(face_paths)}]"
            try:
                s = await register_student(client, token, fp)
                students.append(s)
                ok(f"{label} {s['name']:25s}  id={s['id']}")
                reg_pass += 1
            except Exception as e:
                fail(f"{label} {fp.name}: {e}")
                reg_fail += 1
            await asyncio.sleep(0.8)

        print(f"\n  Registered: {GREEN}{reg_pass} OK{RESET}  {RED}{reg_fail} failed{RESET}")

        if not students:
            print(f"{RED}No students registered. Skipping scan tests.{RESET}")
            return

        # ── Check-in ──────────────────────────────────────────────────────────
        print(f"\n{BOLD}[PHASE 2 — Check-in scans] ({len(students)} students){RESET}")
        ci_pass = ci_fail = 0
        for i, s in enumerate(students):
            label = f"[{i+1:2d}/{len(students)}]"
            try:
                result  = await scan(client, kiosk_key, s["face_path"], "checkin")
                action  = result.get("action", "?")
                matched = (result.get("student") or {}).get("id", "?")
                correct = matched == s["id"]
                accepted = action in ("checkin", "already_checked_in")
                if correct and accepted:
                    ok(f"{label} {s['name']:25s}  action={action}")
                    ci_pass += 1
                else:
                    fail(f"{label} {s['name']:25s}  action={action}  matched={matched}  expected={s['id']}")
                    ci_fail += 1
            except Exception as e:
                fail(f"{label} {s['name']}: {e}")
                ci_fail += 1
            await asyncio.sleep(0.4)

        print(f"\n  Check-in: {GREEN}{ci_pass} PASS{RESET}  {RED}{ci_fail} FAIL{RESET}")

        # ── Check-out ─────────────────────────────────────────────────────────
        print(f"\n{BOLD}[PHASE 3 — Check-out scans] ({len(students)} students){RESET}")
        co_pass = co_fail = 0
        for i, s in enumerate(students):
            label = f"[{i+1:2d}/{len(students)}]"
            try:
                result  = await scan(client, kiosk_key, s["face_path"], "checkout")
                action  = result.get("action", "?")
                matched = (result.get("student") or {}).get("id", "?")
                correct = matched == s["id"]
                accepted = action in ("checkout", "already_checked_out")
                if correct and accepted:
                    ok(f"{label} {s['name']:25s}  action={action}")
                    co_pass += 1
                else:
                    fail(f"{label} {s['name']:25s}  action={action}  matched={matched}  expected={s['id']}")
                    co_fail += 1
            except Exception as e:
                fail(f"{label} {s['name']}: {e}")
                co_fail += 1
            await asyncio.sleep(0.4)

        print(f"\n  Check-out: {GREEN}{co_pass} PASS{RESET}  {RED}{co_fail} FAIL{RESET}")

        # ── Cross-match false-positive test ───────────────────────────────────
        if len(students) >= 2:
            print(f"\n{BOLD}[PHASE 4 — False-positive check]{RESET}")
            print("  Scanning student A's face — must NOT match student B")
            fp_pass = fp_fail = 0
            for i in range(min(len(students), 10)):  # check first 10
                s_correct = students[i]
                s_wrong   = students[(i + 1) % len(students)]
                label     = f"[{i+1:2d}]"
                try:
                    result  = await scan(client, kiosk_key, s_correct["face_path"], "checkin")
                    matched = (result.get("student") or {}).get("id", "?")
                    if matched != s_wrong["id"]:
                        ok(f"{label} {s_correct['name']:25s} not matched to {s_wrong['name']}")
                        fp_pass += 1
                    else:
                        fail(f"{label} {s_correct['name']:25s} WRONGLY matched to {s_wrong['name']}")
                        fp_fail += 1
                except Exception as e:
                    fail(f"{label} error: {e}")
                    fp_fail += 1
                await asyncio.sleep(0.4)
            print(f"\n  False-positive: {GREEN}{fp_pass} OK{RESET}  {RED}{fp_fail} wrong matches{RESET}")

        # ── Summary ───────────────────────────────────────────────────────────
        total = len(students)
        n_fp  = min(total, 10) if total >= 2 else 0
        overall_pass = (
            reg_pass == len(face_paths) and
            ci_pass  == total and
            co_pass  == total
        )
        print(f"\n{BOLD}{'='*60}{RESET}")
        print(f"{BOLD}  RESULTS{RESET}")
        print(f"{'='*60}")
        print(f"  Registration : {reg_pass}/{len(face_paths)}")
        print(f"  Check-in     : {ci_pass}/{total}")
        print(f"  Check-out    : {co_pass}/{total}")
        if n_fp:
            fp_result = locals().get("fp_pass", 0)
            print(f"  False-pos    : {fp_result}/{n_fp} clean")
        status = f"{GREEN}ALL PASS{RESET}" if overall_pass else f"{YELLOW}PARTIAL{RESET}"
        print(f"\n  Overall: {status}")
        print(f"{BOLD}{'='*60}{RESET}\n")


if __name__ == "__main__":
    asyncio.run(main())
