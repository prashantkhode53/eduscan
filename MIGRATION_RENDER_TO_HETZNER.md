# EduScan — Migration Guide: Render → Hetzner + Coolify
> Level: Beginner | Estimated Total Time: 3–4 hours | Date: 2026-06-05

---

## Before You Start — Read This

### What We Are Doing (Simple Explanation)

Right now your app runs on **Render.com** — a company that rents you small computers
in the cloud to run your code. You pay them $49/month for separate pieces.

We are moving to **Hetzner** — a different company that rents you one bigger computer
for $9/month. Then we install **Coolify** on that computer — a free tool that gives
you the same push-to-deploy, SSL, and dashboard experience as Render.

```
BEFORE (Render)                          AFTER (Hetzner + Coolify)
──────────────────────────────           ──────────────────────────────
[Backend Service]     $7/month           [One Hetzner Server]  $9/month
[WhatsApp Service]    $7/month             ├── Backend
[InsightFace Service] $25/month            ├── WhatsApp
[Redis Service]       $10/month            ├── InsightFace
                     ──────────            └── Redis
Total:               $49/month
                                         Coolify (free, runs on server)
                                         Total: $9/month

Neon Database → stays exactly the same (no change)
Firebase FCM  → stays exactly the same (no change)
Flutter App   → only change: update the API server address
```

### Important: You Need a Domain Name

Your Flutter app connects to your backend using an address like:
`https://eduscan-backend.onrender.com`

On Hetzner, you will use your own domain:
`https://api.yourdomain.com`

If you don't have a domain yet, buy one before starting:
- **Namecheap.com** — search for a `.com` name, costs ~₹800/year
- **Cloudflare.com/registrar** — cheapest option, at-cost pricing
- You can use any domain you own

> If you absolutely don't have a domain, you can use the server's raw IP address
> for initial testing, but the Flutter app won't work in production without HTTPS.

---

## Checklist — What You Need Before Starting

Print this and tick each item:

- [ ] Hetzner account created (hetzner.com) — free to create, card needed
- [ ] Domain name purchased and you can access its DNS settings
- [ ] Your GitHub repository URL (the EduScan repo)
- [ ] Your Neon PostgreSQL connection string (`DATABASE_URL`) — copy from Render env vars
- [ ] Your `JWT_SECRET` value — copy from Render env vars
- [ ] Your Firebase service account JSON — copy from Render env vars
- [ ] Windows Terminal open (already installed on Windows 11)
  - Press `Win + X` → select "Windows Terminal"
- [ ] Notepad open — to temporarily save values during migration
- [ ] Render dashboard open in browser — to copy existing env vars
- [ ] **Do NOT delete Render services until migration is complete and tested**

---

## Phase 1 — Create Your Hetzner Server

**Time: 15 minutes**

### Step 1.1 — Create a Hetzner Account

1. Go to **hetzner.com**
2. Click **"Sign Up"** at top right
3. Fill in your details and verify your email
4. Add a payment method (credit card or PayPal)
   - Hetzner charges monthly, not upfront
   - You can delete the server anytime to stop billing

### Step 1.2 — Create a New Project

1. After login, you see the **Cloud Console**
2. Click **"+ New Project"**
3. Name it: `EduScan`
4. Click **"Add Project"**

### Step 1.3 — Create Your Server

1. Inside the EduScan project, click **"Add Server"**
2. Fill in each section:

**Location:**
- Choose **Nuremberg, Germany** (nbg1) — closest to India, good latency

**Image (Operating System):**
- Click **Ubuntu**
- Select **Ubuntu 22.04 LTS** (the one that says LTS)

> LTS = Long Term Support. It means security updates for 5 years. Always pick LTS.

**Type:**
- Click the **"Shared vCPU"** tab
- Look for **CX32** in the list
  - 4 vCPU, 8 GB RAM, 80 GB SSD
  - Price: ~€8.07/month
  - If CX32 is not visible, choose **CX31** (same specs, slightly older)
- Click on CX32 to select it

**SSH Keys (for secure login):**

We will use password login for simplicity as a beginner. Skip SSH keys for now.

> You will be emailed a root password after the server is created.

**Firewall:**
- Click **"Add Firewall"** → **"Create Firewall"**
- Name it: `eduscan-firewall`
- The default rules allow SSH (port 22), HTTP (80), HTTPS (443)
- Also add these rules manually:
  - Type: **Inbound**, Protocol: **TCP**, Port: **8000** (Coolify dashboard)
  - Type: **Inbound**, Protocol: **TCP**, Port: **8080** (InsightFace, temporary)
- Click **"Create Firewall"**

**Server Name:**
- Change it to: `eduscan-server`

**Click "Create & Buy Now"**

### Step 1.4 — Wait for the Server

1. The server takes about 30–60 seconds to start
2. You will see it appear with a green dot (Running)
3. Note down the **IP address** shown — example: `49.13.XXX.XXX`
4. You will also receive an email with the root password

---

## Phase 2 — Connect to Your Server

**Time: 10 minutes**

### Step 2.1 — Open Windows Terminal

Press `Win + X` and click **"Windows Terminal"** (or **"Terminal"**)

### Step 2.2 — Connect via SSH

Type this command (replace `49.13.XXX.XXX` with your actual server IP):

```
ssh root@49.13.XXX.XXX
```

Press Enter.

You will see:
```
The authenticity of host '49.13.XXX.XXX' can't be established.
Are you sure you want to continue connecting (yes/no)?
```

Type `yes` and press Enter.

Then enter the password from your email. Note: when typing a password in the
terminal, **nothing appears on screen** — that is normal. Type it and press Enter.

You will see something like:
```
Welcome to Ubuntu 22.04.4 LTS (GNU/Linux 5.15.0-101-generic x86_64)
root@eduscan-server:~#
```

The `root@eduscan-server:~#` means you are now inside your Hetzner server.

### Step 2.3 — Update the Server

Run these two commands one at a time:

```bash
apt update
```

Wait for it to finish, then:

```bash
apt upgrade -y
```

This updates all software on the server. Takes 2–3 minutes.

---

## Phase 3 — Install Coolify

**Time: 10 minutes**

### Step 3.1 — Run the Coolify Installer

While still connected to your server, run this single command:

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

This script automatically:
- Installs Docker
- Installs Coolify
- Sets up Traefik (the reverse proxy that handles SSL)
- Starts everything

Wait for it to complete. You will see lots of text scrolling. It takes 3–5 minutes.

When done, you will see something like:
```
Coolify is installed successfully!
You can access it at: http://49.13.XXX.XXX:8000
```

### Step 3.2 — Open Coolify Dashboard

1. Open your web browser
2. Go to: `http://49.13.XXX.XXX:8000`
   (Replace with your actual server IP)
3. You will see the Coolify setup screen

### Step 3.3 — Create Your Coolify Admin Account

1. Enter your email address
2. Create a password (save this in Notepad)
3. Click **"Register"**

### Step 3.4 — Initial Coolify Setup

Coolify will walk you through a setup wizard:

**Step "Servers":**
- You will see your server already listed as "localhost"
- Click **"Validate & continue"**
- Wait for validation (green checkmark = good)
- Click **"Next"**

**Step "Create your first project":**
- Click **"Create empty project"**
- Name: `eduscan`
- Click **"Create"** then **"Continue"**

**Step "Get wildcard domain":**
- We will set this up properly in Phase 4
- For now click **"Skip for now"** or **"Continue"**

You are now inside the Coolify dashboard. It looks similar to Render's dashboard.

---

## Phase 4 — Set Up Your Domain

**Time: 15 minutes**

> If you do not have a domain, skip to Phase 5 and use your IP address temporarily.
> Come back to this phase when you get a domain.

### Step 4.1 — Understand What We Are Doing

We need to point your domain to your Hetzner server IP. We do this by creating
**DNS records** at your domain registrar (Namecheap, Cloudflare, etc.)

We will create these subdomains:

| Subdomain | Points to | Purpose |
|-----------|-----------|---------|
| `api.yourdomain.com` | Your Hetzner IP | Node.js Backend |
| `face.yourdomain.com` | Your Hetzner IP | InsightFace service |
| `wa.yourdomain.com` | Your Hetzner IP | WhatsApp service |

### Step 4.2 — Add DNS Records

1. Log in to your domain registrar (Namecheap / Cloudflare / etc.)
2. Find **"DNS Management"** or **"DNS Records"** for your domain
3. Add these **A records**:

```
Type    Name    Value                TTL
────────────────────────────────────────
A       api     49.13.XXX.XXX        Auto
A       face    49.13.XXX.XXX        Auto
A       wa      49.13.XXX.XXX        Auto
```

Replace `49.13.XXX.XXX` with your actual Hetzner server IP.

4. Save the records

> DNS changes can take 5 minutes to 48 hours to propagate worldwide.
> Usually it works within 15–30 minutes.

### Step 4.3 — Set Wildcard Domain in Coolify

1. Go to Coolify dashboard → **"Servers"** (left sidebar)
2. Click on your server (localhost)
3. Find the **"Wildcard Domain"** field
4. Enter: `yourdomain.com`
5. Click **"Save"**

This tells Coolify to issue SSL certificates for `*.yourdomain.com`.

---

## Phase 5 — Deploy Redis

**Time: 5 minutes**

Redis is the cache that stores face embeddings for fast scanning.

### Step 5.1 — Add Redis in Coolify

1. In Coolify dashboard, click **"+ New"** (or **"New Resource"**)
2. Click **"Database"**
3. Click **"Redis"**
4. Fill in:
   - **Name:** `eduscan-redis`
   - **Version:** 7 (latest stable)
   - **Public Port:** Leave EMPTY (we don't want Redis exposed to internet)
5. Click **"Create Database"**
6. Click **"Start"**

Wait for the green dot to appear (Running).

### Step 5.2 — Get the Redis Internal URL

1. Click on **eduscan-redis**
2. You will see connection details
3. Look for the **"Internal URL"** — it looks like:
   ```
   redis://default:PASSWORD@eduscan-redis:6379
   ```
4. Copy this entire URL to Notepad — label it `REDIS_URL (internal)`

> **Internal URL** means only services on the same server can use it.
> This is FREE and FAST (no internet, just local network between containers).

---

## Phase 6 — Deploy InsightFace Service

**Time: 25 minutes** (most time is Docker build)

This is the Python face recognition service — the most important one.

### Step 6.1 — Connect GitHub to Coolify

1. In Coolify, click **"Sources"** in the left sidebar
2. Click **"+ Add"** → **"GitHub App"**
3. Follow the prompts to connect your GitHub account
4. Install the Coolify GitHub App on your repository
5. Give it access to your EduScan repository

### Step 6.2 — Create InsightFace Service

1. Click **"+ New"** → **"Application"**
2. Click **"GitHub"** (your connected account)
3. Select your **EduScan repository**
4. Fill in:
   - **Name:** `eduscan-insightface`
   - **Branch:** `main`
   - **Base Directory:** `/insightface-service`
     (This tells Coolify to look inside the `insightface-service` folder)
   - **Build Pack:** Select **"Dockerfile"**
     (Coolify will use the `Dockerfile` inside `insightface-service/`)

5. Click **"Continue"**

### Step 6.3 — Configure InsightFace Environment Variables

After creating the service, click on **"Environment Variables"** tab.

Add each of these one by one (click **"+ Add"** for each):

```
Variable Name          Value
────────────────────────────────────────────────────────────────────
DATABASE_URL           (paste your Neon PostgreSQL connection string)
REDIS_URL              (paste the Redis internal URL from Step 5.2)
MODEL_NAME             buffalo_sc
MATCH_THRESHOLD        0.75
MARGIN_THRESHOLD       0.05
MIN_FACE_SIZE_PX       60
MAX_YAW_DEG            35
PORT                   8080
```

> Where to find DATABASE_URL:
> Go to Render dashboard → your InsightFace service → Environment → copy DATABASE_URL

Click **"Save"**.

### Step 6.4 — Configure InsightFace Domain

1. Click on the **"Domains"** tab
2. Click **"+ Add Domain"**
3. Enter: `face.yourdomain.com`
4. Enable **"SSL"** (Let's Encrypt)
5. Set port: **8080**
6. Click **"Save"**

### Step 6.5 — Add Persistent Volume (Model Cache)

The InsightFace model is ~50MB and downloads from the internet on first start.
We save it in a persistent volume so it doesn't re-download every time.

1. Click on the **"Storages"** tab
2. Click **"+ Add"**
3. Fill in:
   - **Host Path:** Leave empty (auto-managed)
   - **Container Path:** `/root/.insightface`
   - **Name:** `insightface-model-cache`
4. Click **"Save"**

### Step 6.6 — Deploy InsightFace

1. Click **"Deploy"** (or the Play button)
2. Watch the **"Logs"** tab — you will see Docker building the image
3. The first build takes **10–15 minutes** (it compiles ONNX, OpenCV, etc.)
4. When you see `Application started` or `Uvicorn running on 0.0.0.0:8080` — it is running

**Verify it works:**
Open your browser and go to: `https://face.yourdomain.com/health`

You should see:
```json
{"status": "ok", "model": "buffalo_sc", "ready": true}
```

If `ready` is `false`, wait 30 more seconds and refresh — the model is still loading.

---

## Phase 7 — Deploy the Backend

**Time: 15 minutes**

### Step 7.1 — Create Backend Service

1. Click **"+ New"** → **"Application"** → **"GitHub"**
2. Select your EduScan repository
3. Fill in:
   - **Name:** `eduscan-backend`
   - **Branch:** `main`
   - **Base Directory:** `/backend`
   - **Build Pack:** Select **"Node.js"** (or "Nixpacks")
   - **Build Command:** `npm install && npm run build`
   - **Start Command:** `npm start`
4. Click **"Continue"**

### Step 7.2 — Configure Backend Environment Variables

Click **"Environment Variables"** tab and add all of these:

```
Variable Name              Value
──────────────────────────────────────────────────────────────────────────
DATABASE_URL               (your Neon PostgreSQL connection string)
JWT_SECRET                 (copy from Render backend env vars)
NODE_ENV                   production
PORT                       3000
INSIGHTFACE_URL            http://eduscan-insightface:8080
REDIS_URL                  (same Redis internal URL from Step 5.2)
FIREBASE_CREDENTIALS       (copy from Render backend env vars — the base64 JSON)
RENDER_EXTERNAL_URL        https://api.yourdomain.com
```

> **IMPORTANT:** Notice `INSIGHTFACE_URL` uses `http://eduscan-insightface:8080`
> This is the Docker internal network address — no internet needed between services.
> This is what makes the new setup faster. Services talk directly to each other.

> **SMTP variables** (only if you use email notifications):
> `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`

Click **"Save"**.

### Step 7.3 — Configure Backend Domain

1. Click **"Domains"** tab → **"+ Add Domain"**
2. Enter: `api.yourdomain.com`
3. Enable SSL, Port: **3000**
4. Click **"Save"**

### Step 7.4 — Deploy Backend

1. Click **"Deploy"**
2. Watch Logs tab
3. Build takes 3–5 minutes (npm install + TypeScript compile)
4. When you see `EduScan backend running on port 3000` — it is running

**Verify it works:**
Open browser: `https://api.yourdomain.com/api/health`

You should see:
```json
{
  "success": true,
  "status": "ok",
  "db": "connected",
  "server": "Render",
  "database": "Neon PostgreSQL"
}
```

> The `"server": "Render"` text is just a label in the code — ignore it.
> What matters is `"status": "ok"` and `"db": "connected"`.

---

## Phase 8 — Deploy WhatsApp Service

**Time: 10 minutes**

### Step 8.1 — Create WhatsApp Service

1. Click **"+ New"** → **"Application"** → **"GitHub"**
2. Select your EduScan repository
3. Fill in:
   - **Name:** `eduscan-whatsapp`
   - **Branch:** `main`
   - **Base Directory:** `/whatsapp-api`
   - **Build Pack:** **"Node.js"** (or Nixpacks)
   - **Build Command:** `npm install`
   - **Start Command:** `npm start`
4. Click **"Continue"**

### Step 8.2 — Configure WhatsApp Environment Variables

```
Variable Name     Value
────────────────────────────────────────────────────
DATABASE_URL      (your Neon PostgreSQL connection string)
NODE_ENV          production
PORT              3001
WA_SESSION_PATH   /app/.wwebjs_auth
WA_CLIENT_ID      eduscan-wa
```

Click **"Save"**.

### Step 8.3 — Add Persistent Volume for WhatsApp Session

This is critical. Without this, the WhatsApp session is lost every time you deploy.

1. Click **"Storages"** tab → **"+ Add"**
2. Fill in:
   - **Host Path:** Leave empty
   - **Container Path:** `/app/.wwebjs_auth`
   - **Name:** `whatsapp-session`
3. Click **"Save"**

> This persistent volume is the fix for Bug #1 (WhatsApp reconnects after every deploy).
> On Render, this was impossible. On Hetzner, it just works.

### Step 8.4 — Configure WhatsApp Domain

1. Click **"Domains"** tab → **"+ Add Domain"**
2. Enter: `wa.yourdomain.com`
3. Enable SSL, Port: **3001**
4. Click **"Save"**

### Step 8.5 — Deploy WhatsApp

1. Click **"Deploy"**
2. Watch Logs — takes 3–5 minutes
3. Puppeteer (Chromium) starts up — you will see WhatsApp initialization messages
4. When you see `WhatsApp client starting...` — it is running

**Reconnect WhatsApp:**
Since this is a new server, you need to scan QR once:
1. Open your Flutter app
2. Go to the WhatsApp/QR screen
3. Scan the new QR code with your phone

After scanning, the session is saved to the persistent volume. You will NOT need to scan again after future deployments.

---

## Phase 9 — Update Flutter App

**Time: 10 minutes**

Your Flutter app currently points to the Render URL. We need to update it to point
to your new Hetzner server.

### Step 9.1 — Find the API Endpoints File

Open your project in VS Code.

Navigate to: [lib/constants/api_endpoints.dart](lib/constants/api_endpoints.dart)

### Step 9.2 — Update the Base URL

Find the line that has your Render URL, for example:
```dart
static const String baseUrl = 'https://eduscan-backend.onrender.com';
```

Change it to your new Hetzner URL:
```dart
static const String baseUrl = 'https://api.yourdomain.com';
```

Also find if there is a separate InsightFace URL constant and update it:
```dart
// If this exists, update it too:
static const String insightfaceUrl = 'https://eduscan-insightface.onrender.com';
// Change to:
static const String insightfaceUrl = 'https://face.yourdomain.com';
```

### Step 9.3 — Rebuild Flutter App

Run in your terminal (from the project root):
```
flutter build apk --release
```

Or for testing on your connected phone:
```
flutter run
```

---

## Phase 10 — Test Everything

**Time: 30 minutes**

Do these tests IN ORDER. Fix any failures before moving to the next test.

### Test 1 — Backend Health Check
```
Open browser: https://api.yourdomain.com/api/health
Expected: { "status": "ok", "db": "connected" }
```

### Test 2 — InsightFace Health Check
```
Open browser: https://face.yourdomain.com/health
Expected: { "status": "ok", "model": "buffalo_sc", "ready": true }
```

### Test 3 — Academy Login
1. Open Flutter app
2. Try logging in with an academy account
3. Expected: Login succeeds, dashboard loads

### Test 4 — Student List Loads
1. After login, open Students screen
2. Expected: Your existing students from Neon database appear

### Test 5 — Face Scan
1. Go to Face Scan Attendance screen
2. Point camera at a registered student's face
3. Expected: Green overlay, check-in recorded

### Test 6 — Fee Record Loads
1. Open Fees screen
2. Expected: Existing fee records appear

### Test 7 — WhatsApp Notification (if connected)
1. Do a face scan for a student who has a parent mobile number
2. Expected: WhatsApp message received on parent's phone

### Test 8 — New Student Registration
1. Register a new test student with face capture
2. Expected: Student created, face registered, appears in list

---

## Phase 11 — Stop Render Services (After Testing)

**Only do this after ALL tests in Phase 10 pass.**

1. Go to Render dashboard
2. For each service (Backend, InsightFace, WhatsApp, Redis):
   - Open the service
   - Go to **"Settings"**
   - Scroll to bottom
   - Click **"Suspend Service"** (NOT delete — keep for 2 weeks as backup)
3. After 2 weeks of stable operation on Hetzner, you can delete the Render services

> **Suspending** stops billing immediately but keeps the configuration.
> **Deleting** is permanent and removes all settings.

---

## Understanding Your New Cost

```
Hetzner CX32               €8.07/month   (~₹720/month)
Neon PostgreSQL (Free)      $0/month
Firebase FCM                $0/month
Coolify (open source)       $0/month
Domain (annual / 12)       ~$1/month     (~₹90/month)
──────────────────────────────────────────────────────
Total                      ~$9/month     (~₹810/month)

Previous Render cost        $49/month    (~₹4,400/month)
Monthly savings             $40/month    (~₹3,600/month)
Annual savings             $480/year     (~₹43,000/year)
```

---

## Daily Management — What You Need to Know

### Deploying Code Changes

Whenever you push code to GitHub:
1. Go to Coolify dashboard
2. Click on the service (Backend, InsightFace, or WhatsApp)
3. Click the **"Redeploy"** button (or set up auto-deploy)

To enable **auto-deploy** (like Render):
1. Click on the service in Coolify
2. Go to **"General"** tab
3. Enable **"Auto Deploy on Push"**

Now every `git push` to `main` auto-deploys.

### Viewing Logs

1. Coolify dashboard → click any service → **"Logs"** tab
2. Logs are live (like Render logs)

### Restarting a Service

1. Click on the service
2. Click the **"Restart"** button (circular arrow icon)

### Checking Server Resources

1. SSH into your server: `ssh root@49.13.XXX.XXX`
2. Run: `htop`
3. This shows CPU and RAM usage in real time
4. Press `Q` to quit

### Updating Coolify Itself

Coolify updates itself. When a new version is available, you will see a notification
in the Coolify dashboard. Click **"Update"** — takes about 2 minutes.

---

## Troubleshooting — Common Problems

### Problem: "Cannot connect to server" when you SSH

**Possible causes:**
- You typed the wrong IP address
- The Hetzner firewall is blocking port 22
- The server is still starting up (wait 1 minute)

**Fix:**
1. Go to Hetzner dashboard → your server
2. Check the server is **Running** (green dot)
3. Check your firewall rules allow port 22 (SSH)
4. Try the Hetzner **Web Console** (in the server dashboard) as an alternative to SSH

### Problem: Coolify dashboard not loading at port 8000

**Possible cause:** Firewall not allowing port 8000

**Fix:**
1. Go to Hetzner dashboard → Firewalls → eduscan-firewall
2. Add rule: Inbound, TCP, Port 8000
3. Wait 30 seconds and try again

### Problem: InsightFace service shows `ready: false`

**Possible cause:** Model is still downloading on first start

**Fix:** Wait 2–3 minutes and refresh. The buffalo_sc model downloads ~50MB on first boot.

If it stays `false` after 5 minutes:
1. In Coolify, go to InsightFace → Logs
2. Look for error messages
3. Common fix: make sure `MODEL_NAME=buffalo_sc` is set in env vars

### Problem: Backend shows `"db": "disconnected"`

**Possible cause:** Wrong DATABASE_URL

**Fix:**
1. Coolify → eduscan-backend → Environment Variables
2. Check DATABASE_URL is correct (copy fresh from Neon dashboard)
3. Make sure it ends with `?sslmode=require`
4. Redeploy the backend

### Problem: Flutter app says "Network Error" or "No connection"

**Possible cause:** Base URL not updated in Flutter app OR SSL not working yet

**Fix:**
1. Check `api_endpoints.dart` has the correct new URL
2. Test the URL in browser — does it load?
3. If SSL is not yet active (DNS just changed), wait 30 minutes for Let's Encrypt

### Problem: WhatsApp QR code not showing

**Possible cause:** Puppeteer needs special Chrome flags in Docker

**Fix:**
1. Check Coolify → WhatsApp → Logs for error messages
2. The existing `whatsapp-api/` code already has the right Puppeteer flags for Docker
3. Try restarting: Coolify → WhatsApp → Restart button

### Problem: Face scan is very slow (>5 seconds)

**Possible cause:** InsightFace model was not pre-warmed (ONNX cold start)

**Fix:**
1. After InsightFace starts, visit `https://face.yourdomain.com/health` once
2. The first real scan triggers ONNX JIT compilation (~2 seconds)
3. All subsequent scans will be 200–350ms
4. See the ONNX Warmup optimization in the implementation document for a permanent fix

### Problem: "Relation does not exist" database error

**Possible cause:** DATABASE_URL is pointing to wrong Neon database or schema

**Fix:**
1. Make sure DATABASE_URL is the same Neon connection string as before
2. Do NOT create a new Neon project — use the existing one
3. Restart the backend — migrations run on startup

---

## Security — Basic Steps After Setup

Do these once after everything is working:

### 1. Change the Default SSH Port (Optional but Recommended)

Bots try to brute-force port 22 constantly. This is optional for beginners.

### 2. Set Up Automatic Security Updates

While SSH'd into your server, run:
```bash
apt install unattended-upgrades -y
dpkg-reconfigure unattended-upgrades
```
Press Enter to accept defaults. This auto-installs security patches.

### 3. Monitor Disk Space

Run this occasionally:
```bash
df -h
```
Your 80GB SSD should be fine for a long time. If it ever hits 80% full, Docker
build cache can be cleaned with: `docker system prune`

### 4. Change Root Password

After setup is stable, change the auto-generated root password:
```bash
passwd
```
Enter a new strong password. Save it somewhere safe.

---

## Backup Strategy

Your data is in Neon PostgreSQL — Neon automatically backs it up (7 days on Free tier).

For the Hetzner server configuration itself (no critical data there, all data is in Neon):
- Coolify → your project → **"Backups"** tab
- Add Cloudflare R2 or Backblaze B2 as backup destination (both have free tiers)
- Schedule weekly backups

The WhatsApp session (`.wwebjs_auth/`) is stored in the persistent volume.
If the server ever breaks and needs to be rebuilt, you will need to re-scan the
WhatsApp QR once — that's acceptable.

---

## Summary of All URLs After Migration

```
Service                  Old URL (Render)                     New URL (Hetzner)
───────────────────────────────────────────────────────────────────────────────
Backend API              eduscan-backend.onrender.com          api.yourdomain.com
InsightFace              eduscan-insightface.onrender.com      face.yourdomain.com
WhatsApp                 (internal to backend)                 wa.yourdomain.com
Redis                    redis-xxx.render.com:XXXXX            internal (no public URL)
Database (Neon)          ep-xxx.neon.tech                      ep-xxx.neon.tech (SAME)

Flutter app points to:   https://eduscan-backend.onrender.com  https://api.yourdomain.com
```

---

## Quick Reference — Coolify Buttons Explained

| Button | What it Does |
|--------|-------------|
| **Deploy** | Build the latest code and start the service |
| **Redeploy** | Pull latest code from GitHub and rebuild |
| **Restart** | Restart the running container (no rebuild) |
| **Stop** | Stop the container (billing continues for server, not service) |
| **Logs** | View live and historical container logs |
| **Environment Variables** | Add/edit/delete env vars |
| **Domains** | Add custom domain + SSL |
| **Storages** | Add persistent volumes |

---

*Migration guide complete. Save this file and follow each Phase in order.*
*Do not rush. Each Phase builds on the previous one.*
*Keep Render running in parallel until all tests in Phase 10 pass.*
