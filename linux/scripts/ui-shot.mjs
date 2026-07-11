import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';
import os from 'os';

const OUT = '/Users/nghialuutrung/Desktop/birdnion/docs/images/ui-shots';
fs.mkdirSync(OUT, { recursive: true });

function loadJson(p, fallback) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch { return fallback; }
}

const settings = loadJson(path.join(os.homedir(), '.config/birdnion/settings.json'), { version: 1, providers: [] });
const history = loadJson(path.join(os.homedir(), '.config/birdnion/cost-history.json'), { version: 1, sources: {} });

function historyToReport(source) {
  const byDay = history.sources?.[source] || {};
  const dates = Object.keys(byDay).sort();
  // last 90
  const last = dates.slice(-90);
  const daily = last.map(date => {
    const d = byDay[date] || { usd: 0, tokens: 0, models: [] };
    return {
      date,
      usd: d.usd || 0,
      tokens: d.tokens || 0,
      models: (d.models || []).map(m => ({ name: m.name, usd: m.usd || 0, tokens: m.tokens || 0 })),
    };
  });
  // pad to 90 if empty
  if (daily.length === 0) {
    const today = new Date();
    for (let i = 89; i >= 0; i--) {
      const d = new Date(today); d.setDate(d.getDate() - i);
      const ds = d.toISOString().slice(0, 10);
      daily.push({ date: ds, usd: 0, tokens: 0, models: [] });
    }
  }
  const today = daily[daily.length - 1] || { usd: 0, tokens: 0 };
  const last30 = daily.slice(-30);
  const last30Usd = last30.reduce((s, d) => s + d.usd, 0);
  const last30Tokens = last30.reduce((s, d) => s + d.tokens, 0);
  // hourly empty for non-claude; for claude fake sparse if needed
  const hourly = [];
  if (source === 'claude') {
    for (let h = 0; h < 24; h++) {
      hourly.push({ hour: `2026-07-11T${String(h).padStart(2,'0')}:00`, usd: 0, tokens: 0 });
    }
  }
  const topModel = daily.flatMap(d => d.models).sort((a,b)=>b.usd-a.usd)[0]?.name ?? null;
  return {
    todayUsd: today.usd,
    todayTokens: today.tokens,
    last30Usd,
    last30Tokens,
    daily,
    hourly,
    topModel,
  };
}

const enabled = (settings.providers || []).filter(p => p.enabled === true);
const statuses = (enabled.length ? enabled : [
  { id: 'claude' }, { id: 'codex' }, { id: 'grok' }, { id: 'minimax' }, { id: 'hapo' }, { id: 'freemodel' }
]).map(p => {
  const id = p.id;
  const names = {
    claude: 'Claude', codex: 'Codex', grok: 'Grok', openai: 'OpenAI', ollama: 'Ollama',
    minimax: 'MiniMax', hapo: 'AI Hub', freemodel: 'FreeModel', openrouter: 'OpenRouter',
  };
  return {
    id,
    displayName: names[id] || id,
    accountLabel: null,
    planName: id === 'grok' ? 'SuperGrok' : null,
    windows: id === 'grok' ? [
      { label: 'Session', usedPct: 12, remainingPct: 88, resetsAt: null, subtitle: null },
      { label: 'Monthly', usedPct: 34, remainingPct: 66, resetsAt: null, subtitle: null },
    ] : id === 'claude' ? [
      { label: '5h', usedPct: 40, remainingPct: 60, resetsAt: null, subtitle: null },
      { label: '7d', usedPct: 55, remainingPct: 45, resetsAt: null, subtitle: null },
    ] : id === 'codex' ? [
      { label: '5h', usedPct: 20, remainingPct: 80, resetsAt: null, subtitle: null },
      { label: 'Weekly', usedPct: 50, remainingPct: 50, resetsAt: null, subtitle: null },
    ] : [
      { label: 'Usage', usedPct: 25, remainingPct: 75, resetsAt: null, subtitle: null },
    ],
    error: null,
    cost: null,
    extras: null,
    updatedAt: new Date().toISOString(),
  };
});

const claude = historyToReport('claude');
const codex = historyToReport('codex');
const grok = historyToReport('grok');

async function main() {
  let browser;
  try {
    browser = await chromium.launch({ headless: true, channel: 'chrome' });
  } catch (e) {
    console.log('chrome channel failed', e.message);
    browser = await chromium.launch({ headless: true });
  }
  const page = await browser.newPage({ viewport: { width: 420, height: 720 }, deviceScaleFactor: 2 });

  await page.addInitScript(({ claude, codex, grok, statuses, settings }) => {
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
      test_provider: async ({ id }) => statuses.find(s => s.id === id) || statuses[0],
      provider_storage: async () => 0,
      format_storage_bytes: async ({ bytes }) => `${bytes} bytes`,
      check_for_update: async () => null,
      get_version: async () => '0.8.6-dev',
    };
    // Tauri v2 bridge shape used by @tauri-apps/api
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
    // plugin stubs
    window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener: () => {} };
  }, { claude, codex, grok, statuses, settings });

  await page.goto('http://localhost:1420/', { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForTimeout(1200);

  // All tab
  await page.locator('button.tab', { hasText: 'All' }).click().catch(() => {});
  await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(OUT, '01-all.png'), fullPage: true });

  // Period 7 days
  await page.locator('button.pill', { hasText: '7' }).first().click().catch(() => {});
  await page.waitForTimeout(300);
  await page.screenshot({ path: path.join(OUT, '02-all-7d.png'), fullPage: true });

  // Grok tab
  const grokTab = page.locator('button.tab', { hasText: 'Grok' });
  if (await grokTab.count()) {
    await grokTab.click();
    await page.waitForTimeout(500);
    await page.screenshot({ path: path.join(OUT, '03-grok.png'), fullPage: true });
  }

  // Claude tab
  const claudeTab = page.locator('button.tab', { hasText: 'Claude' });
  if (await claudeTab.count()) {
    await claudeTab.click();
    await page.waitForTimeout(500);
    await page.screenshot({ path: path.join(OUT, '04-claude.png'), fullPage: true });
  }

  // Settings
  await page.locator('button.tab', { hasText: '⚙' }).click();
  await page.waitForTimeout(800);
  await page.screenshot({ path: path.join(OUT, '05-settings-providers.png'), fullPage: true });

  // General section
  const chung = page.locator('button.settings-section-btn', { hasText: /Chung|General/ });
  if (await chung.count()) {
    await chung.click();
    await page.waitForTimeout(400);
    await page.screenshot({ path: path.join(OUT, '06-settings-general.png'), fullPage: true });
  }

  // About
  const about = page.locator('button.settings-section-btn', { hasText: /Giới thiệu|About/ });
  if (await about.count()) {
    await about.click();
    await page.waitForTimeout(400);
    await page.screenshot({ path: path.join(OUT, '07-settings-about.png'), fullPage: true });
  }

  // Scroll providers for more of list
  await page.locator('button.settings-section-btn', { hasText: 'Providers' }).click().catch(() => {});
  await page.waitForTimeout(300);
  await page.evaluate(() => {
    const list = document.querySelector('.settings-provider-list') || document.querySelector('.settings');
    if (list) list.scrollTop = 400;
  });
  await page.waitForTimeout(200);
  await page.screenshot({ path: path.join(OUT, '08-settings-providers-scroll.png'), fullPage: true });

  await browser.close();
  console.log('shots written to', OUT);
  for (const f of fs.readdirSync(OUT).filter(x => x.endsWith('.png'))) {
    const st = fs.statSync(path.join(OUT, f));
    console.log(f, st.size);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
