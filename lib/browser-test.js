#!/usr/bin/env node
// fleet/lib/browser-test.js — Playwright driver a worker runs via `node` to
// functionally test the web app it itself started. Drives the SYSTEM Chromium
// (no bundled-browser download) via playwright-core.
//
// Modes (one flag apart, per RESEARCH-agent-testing.md):
//   headless (default)        : launch /usr/bin/chromium headless, own lifecycle.
//   headed   (FLEET_HEADED=1) : connect over CDP to an already-visible window the
//                               wrapper launched + Hyprland-tiled, drive it, and
//                               DETACH (leave it open for the human).
//
// Knowledge channels captured: console errors, network, DOM, screenshot→file.
// Control: goto + a pluggable agent-supplied interaction/assert hook.
//
// Env:
//   FLEET_URL     (required) dev-server URL to test.
//   FLEET_HEADED  '1' → headed/CDP mode (else headless).
//   FLEET_CDP     CDP endpoint to connectOverCDP (e.g. http://localhost:9222); headed mode.
//   FLEET_CHROMIUM  chromium executable path (default /usr/bin/chromium).
//   FLEET_SHOT    screenshot output path (default ./.fleet/shots/shot.png).
//   FLEET_HOOK    path to a JS module exporting `async (page) => ({...asserts})`.
//   FLEET_TIMEOUT navigation timeout ms (default 30000).
//
// Always prints a single JSON object to stdout: { url, ok, title, dom, errs,
// netReqs, netFails, asserts, hookError, screenshot, error }. Exit 0 even on a
// page error (the JSON carries the failure) — fail-silent like the rest of fleet.

const path = require('path');
const fs = require('fs');

async function main() {
  const { chromium } = require('playwright-core');

  const url = process.env.FLEET_URL || '';
  const headed = process.env.FLEET_HEADED === '1';
  const cdp = process.env.FLEET_CDP || '';
  const exe = process.env.FLEET_CHROMIUM || '/usr/bin/chromium';
  const shot = process.env.FLEET_SHOT || path.join('.fleet', 'shots', 'shot.png');
  const hookPath = process.env.FLEET_HOOK || '';
  const timeout = parseInt(process.env.FLEET_TIMEOUT || '30000', 10);

  if (!url) { throw new Error('FLEET_URL not set'); }

  const errs = [], netReqs = [], netFails = [];
  let browser, page, owns = true; // owns: headless launch we must close

  if (headed && cdp) {
    // Attach to the visible window the wrapper already launched + tiled. close()
    // only disconnects CDP — it does NOT kill the process, so the human keeps it.
    browser = await chromium.connectOverCDP(cdp, { timeout });
    owns = false;
    const ctx = browser.contexts()[0] || (await browser.newContext());
    page = ctx.pages().find(p => !p.isClosed()) || (await ctx.newPage());
  } else {
    browser = await chromium.launch({ headless: !headed, executablePath: exe });
    const ctx = await browser.newContext();
    page = await ctx.newPage();
  }

  page.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  page.on('pageerror', e => errs.push(String(e && e.message || e)));
  page.on('requestfinished', r => { try { netReqs.push(r.url()); } catch (_) {} });
  page.on('requestfailed', r => { try { netFails.push(r.url()); } catch (_) {} });

  let ok = true, navErr = '';
  try {
    await page.goto(url, { waitUntil: 'networkidle', timeout });
  } catch (e) {
    ok = false; navErr = String(e && e.message || e);
  }

  // Pluggable interaction/assert hook: a module exporting async (page) => object.
  let asserts = {}, hookError = '';
  if (hookPath) {
    try {
      const hook = require(path.resolve(hookPath));
      const fn = (typeof hook === 'function') ? hook : hook.default;
      if (typeof fn === 'function') {
        const r = await fn(page);
        if (r && typeof r === 'object') asserts = r;
      } else {
        hookError = 'hook did not export a function';
      }
    } catch (e) {
      hookError = String(e && e.message || e);
    }
  }

  // Generic DOM snapshot (app-specific reads belong in the hook).
  let title = '', dom = '';
  try { title = await page.title(); } catch (_) {}
  try {
    dom = await page.evaluate(() =>
      (document.body ? document.body.innerText : '').slice(0, 2000));
  } catch (_) {}

  // Screenshot → file the agent can Read. Headed needs the window genuinely
  // on-screen (Wayland won't composite an occluded surface — RESEARCH §a).
  let screenshot = '', shotErr = '';
  try {
    fs.mkdirSync(path.dirname(shot), { recursive: true });
    await page.screenshot({ path: shot, timeout });
    screenshot = path.resolve(shot);
  } catch (e) {
    shotErr = String(e && e.message || e);
  }

  try { if (owns) await browser.close(); else await browser.close(); } catch (_) {}
  // (CDP browser.close() detaches without killing the launched process.)

  process.stdout.write(JSON.stringify({
    url, headed, ok,
    title, dom,
    errs, netReqs, netFails,
    asserts, hookError,
    screenshot, shotErr,
    navErr,
  }, null, 2) + '\n');
}

main().catch(e => {
  process.stdout.write(JSON.stringify({ ok: false, error: String(e && e.message || e) }) + '\n');
  process.exit(0); // fail-silent: the JSON carries the failure
});
