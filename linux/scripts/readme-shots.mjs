// README screenshot capture for the Instrument redesign — mocks the Tauri
// bridge with representative fake data (same technique as ui-shot.mjs) and
// shoots the current popover ("All" tab) + Settings ("General" pane) for
// docs/images/usage-overview.png and docs/images/general-settings.png.
//
// Requires `npm i --no-save playwright` first (not a project dependency —
// only needed to regenerate these screenshots).
//
// Usage: node scripts/readme-shots.mjs <output-dir>
// (run `npm run dev` in another terminal first, so localhost:1420 is up)
import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';

const OUT = process.argv[2];
if (!OUT) {
  console.error('Usage: node scripts/readme-shots.mjs <output-dir>');
  process.exit(1);
}
fs.mkdirSync(OUT, { recursive: true });

function daily(n, seedBase, modelName) {
  const out = [];
  const today = new Date('2026-08-15T00:00:00Z');
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(today); d.setDate(d.getDate() - i);
    const date = d.toISOString().slice(0, 10);
    const phase = (n - i) / n;
    const r = Math.abs(Math.sin(seedBase + i * 0.7));
    const active = r > (phase < 0.5 ? 0.34 : 0.06);
    const usd = active ? (phase < 0.5 ? 3 + r * 40 : 40 + r * 260) : 0;
    const tokens = Math.round(usd * 45000);
    out.push({ date, usd, tokens, models: active ? [{ name: modelName, usd: usd * 0.7, tokens: Math.round(tokens * 0.7) }] : [] });
  }
  return out;
}

function report(seed, topModel) {
  const dailyArr = daily(120, seed, topModel);
  const last30 = dailyArr.slice(-30);
  const today = dailyArr[dailyArr.length - 1];
  return {
    todayUsd: today.usd,
    todayTokens: today.tokens,
    last30Usd: last30.reduce((s, d) => s + d.usd, 0),
    last30Tokens: last30.reduce((s, d) => s + d.tokens, 0),
    daily: dailyArr,
    hourly: [],
    topModel,
    scannedAt: Date.now(),
    included: true,
    live: true,
  };
}

const claude = report(1, 'claude-opus-4-8');
const codex = report(2, 'gpt-5.4');
const grok = report(3, 'grok-5');

const statuses = [
  { id: 'claude', displayName: 'Claude', accountLabel: null, planName: 'Max 20x', windows: [
    { label: '5h', usedPct: 82, remainingPct: 18, resetsAt: new Date(Date.now() + 2 * 3600e3).toISOString(), subtitle: null },
    { label: 'Weekly (all models)', usedPct: 36, remainingPct: 64, resetsAt: new Date(Date.now() + 4 * 86400e3).toISOString(), subtitle: null },
  ], error: null, cost: null, extras: null, updatedAt: new Date().toISOString() },
  { id: 'codex', displayName: 'Codex', accountLabel: null, planName: null, windows: [
    { label: '5h', usedPct: 24, remainingPct: 76, resetsAt: null, subtitle: null },
  ], error: null, cost: null, extras: null, updatedAt: new Date().toISOString() },
  { id: 'grok', displayName: 'Grok', accountLabel: null, planName: 'SuperGrok', windows: [
    { label: 'Session', usedPct: 58, remainingPct: 42, resetsAt: null, subtitle: null },
  ], error: null, cost: null, extras: null, updatedAt: new Date().toISOString() },
];

const settings = {
  version: 1,
  appearance: 'light',
  providers: [
    { id: 'claude', enabled: true, refreshInterval: null, showInTray: true, displayName: null },
    { id: 'codex', enabled: true, refreshInterval: null, showInTray: true, displayName: null },
    { id: 'grok', enabled: true, refreshInterval: null, showInTray: true, displayName: null },
    { id: 'minimax', enabled: false },
    { id: 'openrouter', enabled: false },
  ],
};

function installBridge(page) {
  return page.addInitScript(({ claude, codex, grok, statuses, settings }) => {
    localStorage.setItem('birdnion.lang', 'en');
    const handlers = {
      claude_usage_report: async () => claude,
      codex_usage_report: async () => codex,
      grok_usage_report: async () => grok,
      provider_statuses: async () => statuses,
      claude_admin_usage: async () => null,
      get_settings: async () => settings,
      save_settings: async () => null,
      get_autostart: async () => false,
      set_autostart: async () => null,
      set_tray_tooltip: async () => null,
      set_tray_status: async () => null,
      notify: async () => null,
      classify_provider_error: async () => null,
      test_provider: async ({ id }) => statuses.find((s) => s.id === id) || statuses[0],
      provider_storage: async () => 0,
      format_storage_bytes: async ({ bytes }) => `${bytes} bytes`,
      check_for_update: async () => null,
      get_version: async () => '1.6.0',
      open_settings_window: async () => null,
      quit_app: async () => null,
    };
    window.__TAURI_INTERNALS__ = {
      transformCallback: (cb, once) => {
        const id = Math.floor(Math.random() * 1e9);
        window[`_${id}`] = (result) => { if (once) delete window[`_${id}`]; cb(result); };
        return id;
      },
      invoke: async (cmd, args = {}) => {
        if (handlers[cmd]) return handlers[cmd](args);
        console.warn('unmocked invoke', cmd, args);
        return null;
      },
      metadata: { currentWindow: { label: 'main' }, currentWebview: { label: 'main' } },
    };
    window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener: () => {} };
  }, { claude, codex, grok, statuses, settings });
}

async function main() {
  // Some sandboxes pin a system Chromium instead of Playwright's own
  // download; fall back to it only if present, otherwise let Playwright
  // resolve its normal bundled browser.
  const sandboxChromium = '/opt/pw-browsers/chromium';
  const browser = await chromium.launch({
    headless: true,
    ...(fs.existsSync(sandboxChromium) ? { executablePath: sandboxChromium } : {}),
  });

  // --- Popover: All tab, light theme ---
  {
    const page = await browser.newPage({ viewport: { width: 420, height: 900 }, deviceScaleFactor: 2 });
    await installBridge(page);
    await page.goto('http://localhost:1420/index.html', { waitUntil: 'networkidle', timeout: 30000 });
    await page.waitForTimeout(1000);
    await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'light'));
    await page.waitForTimeout(200);
    const container = page.locator('#app.container, .container').first();
    await container.screenshot({ path: path.join(OUT, 'popover-all.png') });
    await page.close();
  }

  // --- Settings: General pane, light theme ---
  {
    const page = await browser.newPage({ viewport: { width: 960, height: 660 }, deviceScaleFactor: 2 });
    await installBridge(page);
    await page.goto('http://localhost:1420/settings.html', { waitUntil: 'networkidle', timeout: 30000 });
    await page.waitForTimeout(1200);
    await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'light'));
    // Un-clip the scrollable content pane so the full pane (not just one
    // 620px-tall window's worth) renders for the screenshot, then resize
    // the viewport to match its natural height.
    await page.addStyleTag({ content: '.settings-window{height:auto!important} .sw-content{overflow:visible!important}' });
    await page.waitForTimeout(200);
    const win = page.locator('.settings-window').first();
    const box = await win.boundingBox();
    await page.setViewportSize({ width: 960, height: Math.ceil(box.height) + 20 });
    await page.waitForTimeout(150);
    await win.screenshot({ path: path.join(OUT, 'settings-general.png') });
    await page.close();
  }

  await browser.close();
  console.log('shots written to', OUT);
  for (const f of fs.readdirSync(OUT).filter((x) => x.endsWith('.png'))) {
    console.log(f, fs.statSync(path.join(OUT, f)).size);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
