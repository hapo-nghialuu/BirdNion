import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "vite";

const values = new Map([["birdnion.lang", "en"]]);
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: { language: "en-US", languages: ["en-US"] },
});
Object.defineProperty(globalThis, "localStorage", {
  configurable: true,
  value: {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: (key) => values.delete(key),
  },
});

class FakeElement {
  constructor(tagName) {
    this.tagName = tagName.toUpperCase();
    this.classList = {
      add: (...names) => {
        this.className = [...new Set([...this.className.split(/\s+/), ...names])]
          .filter(Boolean).join(" ");
      },
      toggle: (name, force) => {
        const names = new Set(this.className.split(/\s+/).filter(Boolean));
        if (force) names.add(name);
        else names.delete(name);
        this.className = [...names].join(" ");
      },
    };
  }
  className = "";
  textContent = "";
  children = [];
  style = {};
  attributes = new Map();
  listeners = new Map();
  title = "";
  append(...children) { this.children.push(...children); }
  setAttribute(name, value) { this.attributes.set(name, value); }
  addEventListener(name, callback) { this.listeners.set(name, callback); }
}

Object.defineProperty(globalThis, "document", {
  configurable: true,
  value: { createElement: (tag) => new FakeElement(tag) },
});

function renderedText(root) {
  return [root.textContent, ...root.children.map(renderedText)].filter(Boolean).join(" ");
}

const stubs = new Map([
  ["@tauri-apps/api/core", "export const invoke=()=>Promise.resolve();"],
  ["@tauri-apps/api/event", "export const emit=()=>Promise.resolve();export const listen=()=>Promise.resolve(()=>{});"],
  ["@tauri-apps/plugin-opener", "export const openUrl=()=>Promise.resolve();"],
]);
const server = await createServer({
  root: new URL("..", import.meta.url).pathname,
  configFile: false,
  server: { middlewareMode: true, hmr: false },
  appType: "custom",
  optimizeDeps: { noDiscovery: true },
  plugins: [{
    name: "allowance-tauri-stubs",
    enforce: "pre",
    resolveId(id) {
      if (stubs.has(id)) return `\0allowance:${id}`;
    },
    load(id) {
      if (!id.startsWith("\0allowance:")) return;
      return stubs.get(id.slice("\0allowance:".length));
    },
  }],
});
const { providerCard, quotaAllowanceText } = await server.ssrLoadModule("/src/provider-tab.ts");
test.after(async () => server.close());

test("native allowance formats exact USD and character values", () => {
  assert.equal(quotaAllowanceText({
    used: 4.2,
    remaining: 5.8,
    limit: 10,
    unit: "usd",
  }), "$5.80 remaining of $10.00");

  assert.equal(quotaAllowanceText({
    used: 5_000,
    remaining: 5_000,
    limit: 10_000,
    unit: "characters",
  }), "5,000 characters remaining of 10,000 characters");
});

test("missing or invalid native values stay unavailable", () => {
  assert.equal(quotaAllowanceText(undefined), null);
  assert.equal(quotaAllowanceText({ unit: "credits" }), null);
  assert.equal(quotaAllowanceText({ used: Number.NaN, unit: "credits" }), null);
});

test("provider card renders native allowance without inventing a reset", () => {
  const card = providerCard({
    id: "hapo",
    displayName: "Hapo AI Hub",
    windows: [{
      label: "Week",
      usedPct: 42,
      remainingPct: 58,
      windowSeconds: 604_800,
      allowance: { used: 4.2, remaining: 5.8, limit: 10, unit: "usd" },
    }],
    lastUpdated: 2_000_000_000,
    sourceLabel: "API",
  });
  const text = renderedText(card);
  assert.match(text, /\$5\.80 REMAINING OF \$10\.00/);
  assert.doesNotMatch(text, /RESETS IN/);
});
