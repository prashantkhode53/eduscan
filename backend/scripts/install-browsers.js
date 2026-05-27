'use strict';
// Runs after `npm install` on every environment.
// On Render (and other Linux CI), Puppeteer v21+ requires an explicit
// `npx puppeteer browsers install chrome` — the package no longer bundles
// Chrome automatically.  This script is non-fatal so a missing Chrome
// shows up as a service error rather than a broken build.
const { execSync } = require('child_process');
const path = require('path');

try {
  console.log('[puppeteer] Installing Chromium browser...');
  execSync('npx puppeteer browsers install chrome', {
    stdio: 'inherit',
    cwd: path.join(__dirname, '..'),
  });
  console.log('[puppeteer] Chromium installed successfully.');
} catch (err) {
  console.warn(
    '[puppeteer] Chromium install failed — set PUPPETEER_EXECUTABLE_PATH if',
    'you have Chrome installed elsewhere.\n',
    err.message.split('\n')[0],
  );
  // Exit 0 so `npm install` still succeeds; the WhatsApp service will
  // report initError when it tries to launch Chrome.
  process.exit(0);
}
