'use strict';
/**
 * Installs Chromium for Puppeteer (v21+ no longer auto-downloads Chrome).
 *
 * Install target priority:
 *   1. PUPPETEER_CACHE_DIR env var (set this in Render / CI)
 *   2. <project-root>/.puppeteer-browsers  (fallback — part of build artifact)
 *
 * Using a project-local directory ensures Chrome survives Render deploys and
 * service restarts without needing a separate persistent disk.
 */

const { execSync, spawnSync } = require('child_process');
const path  = require('path');
const fs    = require('fs');

const projectRoot   = path.resolve(__dirname, '..');
const defaultCache  = path.join(projectRoot, '.puppeteer-browsers');
const cacheDir      = process.env.PUPPETEER_CACHE_DIR || defaultCache;

console.log('[chrome-install] ─────────────────────────────────');
console.log('[chrome-install] Cache dir:', cacheDir);

// Ensure cache dir exists before handing it to Puppeteer
try { fs.mkdirSync(cacheDir, { recursive: true }); } catch { /* ok */ }

const env = { ...process.env, PUPPETEER_CACHE_DIR: cacheDir };

// ── Step 1: Install ──────────────────────────────────────────────────────────

try {
  console.log('[chrome-install] Running: npx puppeteer browsers install chrome');
  execSync('npx puppeteer browsers install chrome', {
    stdio:  'inherit',
    cwd:    projectRoot,
    env,
  });
} catch (err) {
  console.warn('[chrome-install] Install failed:', err.message.split('\n')[0]);
  console.warn('[chrome-install] Chrome will be auto-detected at startup.');
  console.warn('[chrome-install] Override with PUPPETEER_EXECUTABLE_PATH env var.');
  process.exit(0); // Non-fatal — service will report initError on launch
}

// ── Step 2: Find and print the installed binary path ────────────────────────
// This makes the path visible in Render build logs for easy debugging.

try {
  const result = spawnSync(
    'node', ['-e',
      `const p=require('puppeteer');` +
      `p.executablePath && console.log(p.executablePath())`
    ],
    { cwd: projectRoot, env, encoding: 'utf8' }
  );
  const chromePath = (result.stdout || '').trim();
  if (chromePath) {
    console.log('[chrome-install] Chrome executable:', chromePath);
    // Write the path to a file so the service can read it as a fallback
    try {
      fs.writeFileSync(
        path.join(projectRoot, '.chrome-path'),
        chromePath,
        'utf8'
      );
    } catch { /* non-fatal */ }
  }
} catch { /* non-fatal */ }

console.log('[chrome-install] Done. PUPPETEER_CACHE_DIR=' + cacheDir);
console.log('[chrome-install] ─────────────────────────────────');
