import test from "node:test";
import assert from "node:assert/strict";

import { combine, combinedDaySourceUsage } from "../src/usage.ts";

function report(usd, tokens, models) {
  return {
    todayUsd: usd,
    todayTokens: tokens,
    last30Usd: usd,
    last30Tokens: tokens,
    daily: [{ date: "2026-08-25", usd, tokens, models }],
    hourly: [],
    topModel: models[0]?.name ?? null,
    included: true,
    live: true,
    scannedAt: 1,
  };
}

class FakeElement {
  className = "";
  textContent = "";
  children = [];
  style = {};
  classList = {
    add: (...names) => {
      const classes = new Set(this.className.split(/\s+/).filter(Boolean));
      for (const name of names) classes.add(name);
      this.className = [...classes].join(" ");
    },
  };

  append(...children) {
    this.children.push(...children);
  }

  addEventListener() {}
}

function descendantsWithClass(root, wanted) {
  const found = [];
  for (const child of root.children) {
    if (child.className.split(/\s+/).includes(wanted)) found.push(child);
    found.push(...descendantsWithClass(child, wanted));
  }
  return found;
}

function renderedRows(section) {
  return descendantsWithClass(section, "agents-row").map((row) => ({
    name: descendantsWithClass(row, "agents-row-name")[0]?.textContent,
    amount: descendantsWithClass(row, "agents-row-amount")[0]?.textContent,
  }));
}

test("Cost by Model and Token hide only Kiro synthetic Other", async () => {
  const kiro = report(5.5, 550, [
    { name: "real-model", usd: 1, tokens: 100 },
    { name: "Other", usd: 4.5, tokens: 450 },
  ]);
  const combined = combine(null, null, null, null, null, kiro);
  assert.deepEqual(combinedDaySourceUsage(combined.daily[0], "kiro"), {
    usd: 5.5,
    tokens: 550,
  });
  assert.equal(combined.daily[0].models.some(
    (model) => model.source === "kiro" && model.name === "Other"), true);

  const previousDocument = globalThis.document;
  const previousStorage = globalThis.localStorage;
  const previousWindow = globalThis.window;
  let mode = "token";
  globalThis.document = { createElement: () => new FakeElement() };
  globalThis.localStorage = {
    getItem: (key) => key === "birdnion.costByMode" ? mode : "en",
    setItem: () => {},
    removeItem: () => {},
  };
  globalThis.window = { addEventListener: () => {} };

  const sidePanelStub = "\0all-agents-kiro-display-side-panel";
  const { createServer } = await import("vite");
  const server = await createServer({
    root: new URL("..", import.meta.url).pathname,
    configFile: false,
    server: { middlewareMode: true },
    appType: "custom",
    optimizeDeps: { noDiscovery: true },
    plugins: [{
      name: "all-agents-kiro-display-side-panel",
      enforce: "pre",
      resolveId(id, importer) {
        if (id === "./side-panel" && importer?.includes("/src/")) {
          return sidePanelStub;
        }
      },
      load(id) {
        if (id === sidePanelStub) {
          return "export const showModelsPanel=()=>{};export const showAgentPanel=()=>{};"
            + "export const showDayPanel=()=>{};export const showActivityPanel=()=>{};"
            + "export const bindHoverPanel=()=>{};export const closeDayPanelOnly=()=>{};";
        }
      },
    }],
  });

  try {
    const { costBySection } = await server.ssrLoadModule("/src/all-agents-sections.ts");
    assert.deepEqual(renderedRows(costBySection(combined, 1, () => {})), [
      { name: "real-model", amount: "100" },
    ]);

    mode = "model";
    assert.deepEqual(renderedRows(costBySection(combined, 1, () => {})), [
      { name: "real-model", amount: "$1.00" },
    ]);

    const claude = report(2, 200, [{ name: "Other", usd: 2, tokens: 200 }]);
    const mixed = combine(claude, null, null, null, null, kiro);
    mode = "token";
    assert.deepEqual(renderedRows(costBySection(mixed, 1, () => {})), [
      { name: "Other", amount: "200" },
      { name: "real-model", amount: "100" },
    ]);
    const { topModelsCard } = await server.ssrLoadModule("/src/all-tab.ts");
    assert.deepEqual(
      descendantsWithClass(topModelsCard(mixed), "top-model-name").map((node) => node.textContent),
      ["Other", "real-model"],
      "period ranking keeps real Claude Other but drops Kiro's synthetic bucket",
    );

    const { buildAgentPanelPayload } = await server.ssrLoadModule("/src/agent-panel-payload.ts");
    const payload = buildAgentPanelPayload({
      agentId: "kiro", displayName: "Kiro", source: "kiro", daily: mixed.daily,
    });
    assert.deepEqual(payload.costDays?.[0].models.map((model) => model.name), ["real-model"]);
    assert.equal(mixed.todayTokens, 750, "source/day totals remain conserved");
  } finally {
    await server.close();
    if (previousDocument === undefined) delete globalThis.document;
    else globalThis.document = previousDocument;
    if (previousStorage === undefined) delete globalThis.localStorage;
    else globalThis.localStorage = previousStorage;
    if (previousWindow === undefined) delete globalThis.window;
    else globalThis.window = previousWindow;
  }
});
