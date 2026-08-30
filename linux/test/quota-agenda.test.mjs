import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "vite";

const NOW = 2_000_000_000;

function window(label, remainingPct, extra = {}) {
  return { label, usedPct: 100 - remainingPct, remainingPct, ...extra };
}

function status(id, windows, extra = {}) {
  return {
    id,
    displayName: `Provider ${id}`,
    windows,
    lastUpdated: NOW - 60,
    sourceLabel: "OAuth",
    accountLabel: `${id}-private`,
    signedInEmail: `${id}@example.com`,
    ...extra,
  };
}

function agentsFor(statuses) {
  return statuses.map((item) => ({ id: item.id, displayName: `Agent ${item.id}` }));
}

class FakeElement {
  constructor(tagName) {
    this.tagName = tagName.toUpperCase();
    this.classList = {
      add: (...names) => {
        this.className = [...new Set([...this.className.split(/\s+/), ...names])]
          .filter(Boolean).join(" ");
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

  append(...children) {
    this.children.push(...children);
  }

  replaceChildren(...children) {
    this.children = [...children];
  }

  setAttribute(name, value) {
    this.attributes.set(name, value);
  }

  addEventListener(name, callback) {
    this.listeners.set(name, callback);
  }

  click() {
    this.listeners.get("click")?.({});
  }
}

function descendantsWithClass(root, wanted) {
  const found = [];
  for (const child of root.children) {
    if (child.className.split(/\s+/).includes(wanted)) found.push(child);
    found.push(...descendantsWithClass(child, wanted));
  }
  return found;
}

function renderedText(root) {
  return [root.textContent, ...root.children.map(renderedText)].filter(Boolean).join(" ");
}

const sidePanelStub = "\0quota-agenda-side-panel";
const server = await createServer({
  root: new URL("..", import.meta.url).pathname,
  configFile: false,
  server: { middlewareMode: true, hmr: false },
  appType: "custom",
  optimizeDeps: { noDiscovery: true },
  plugins: [{
    name: "quota-agenda-side-panel",
    enforce: "pre",
    resolveId(id, importer) {
      if (id === "./side-panel" && importer?.includes("/src/")) return sidePanelStub;
    },
    load(id) {
      if (id === sidePanelStub) return "export const showAgentPanel=()=>{};";
    },
  }],
});
const agenda = await server.ssrLoadModule("/src/quota-agenda.ts");
const agendaSection = await server.ssrLoadModule("/src/quota-agenda-section.ts");
const configuredSection = await server.ssrLoadModule("/src/configured-agents-section.ts");
test.after(async () => server.close());

test("Agenda selector uses nearest explicit primary reset and centralized flags", () => {
  const candidate = status("selector", [
    window("Inactive", 99, { resetsAt: NOW + 1, isInactive: true }),
    window("Bonus Credits", 5, { resetsAt: NOW + 2 }),
    window("Daily Routines", 6, { resetsAt: NOW + 3 }),
    window("Gia hạn", 100, { resetsAt: NOW + 4 }),
    window("Weekly", 10, { resetsAt: NOW + 200 }),
    window("Session", 80, { resetsAt: NOW + 100 }),
  ]);

  assert.equal(agenda.selectQuotaAgendaWindow(candidate, NOW).label, "Session");
  assert.equal(agenda.isQuotaAgendaSupplementary(window("Số dư", 100)), true);
  assert.equal(agenda.isQuotaAgendaSupplementary(
    window("Provider bonus", 100, { isSupplementary: true })), true);
  assert.equal(agenda.isQuotaAgendaSupplementary(window("Daily Routines", 90)), true);
  assert.equal(agenda.isQuotaAgendaInactive(status("freemodel", []),
    window("5 giờ", 100, { subtitle: "$0.00 / $0.00" })), true);
  assert.equal(agenda.selectQuotaAgendaWindow(status("freemodel", [
    window("5 giờ", 100, { subtitle: "$0.00 / $0.00", resetsAt: NOW + 10 }),
    window("Tuần", 65, { subtitle: "$3.50 / $10.00", resetsAt: NOW + 20 }),
  ]), NOW).label, "Tuần");
  assert.equal(agenda.selectQuotaAgendaWindow(status("fallback", [
    window("First primary", 70),
    window("Lowest primary", 40),
  ]), NOW).label, "Lowest primary");
  assert.equal(agenda.selectQuotaAgendaWindow(
    status("supplementary-only", [window("Bonus Credits", 50)]), NOW), null);
});

test("Agenda suppresses catalog races and ambiguous provider placeholders", () => {
  const statuses = [status("known", [window("Session", 70)])];
  assert.deepEqual(agenda.buildQuotaAgendaRows(statuses, {
    agents: null,
    staleWarnings: new Map(),
    hidePersonalInfo: false,
    nowSeconds: NOW,
  }), []);

  assert.equal(agenda.selectQuotaAgendaWindow(status("kiro", [
    window("Credits", 100),
  ]), NOW), null);
  assert.equal(agenda.selectQuotaAgendaWindow(status("cursor", [
    window("Plan", 100),
    window("On-demand", 100, { subtitle: "$5.00 / $0.00" }),
  ]), NOW), null);
  assert.equal(agenda.selectQuotaAgendaWindow(status("claude", [
    window("Chi phí 30 ngày", 100),
  ]), NOW), null);
  assert.equal(agenda.selectQuotaAgendaWindow(status("cursor", [
    window("Plan", 100, { subtitle: "$0.00 / $20.00" }),
  ]), NOW).label, "Plan");
});

test("Agenda sorts scheduled, awaiting, unknown, then stale without reset inference", () => {
  const statuses = [
    status("late", [window("Weekly", 70, { resetsAt: NOW + 200 })]),
    status("unknown", [window("Session", 60, { windowSeconds: 18_000 })]),
    status("awaiting", [window("Session", 40, { resetsAt: NOW - 100 })], {
      lastUpdated: NOW - 200,
    }),
    status("past-observed", [window("Session", 30, { resetsAt: NOW - 100 })], {
      lastUpdated: NOW - 50,
    }),
    status("stale", [window("Session", 20, { resetsAt: NOW + 50 })]),
    status("early", [window("Session", 80, { resetsAt: NOW + 100 })]),
  ];
  const rows = agenda.buildQuotaAgendaRows(statuses, {
    agents: agentsFor(statuses),
    staleWarnings: new Map([["stale", { kind: "rateLimited", lastGoodUpdated: NOW - 60 }]]),
    hidePersonalInfo: false,
    nowSeconds: NOW,
  });

  assert.deepEqual(rows.map((row) => row.providerId), [
    "early", "late", "awaiting", "unknown", "past-observed", "stale",
  ]);
  assert.equal(rows[2].state, "awaitingRefresh");
  assert.equal(rows[2].remainingPct, null, "pre-reset observation cannot claim current quota");
  assert.equal(rows[3].state, "unknown");
  assert.equal(rows[3].resetAt, null, "windowSeconds must never infer a reset");
  assert.equal(rows[4].percentageKind, "current", "post-reset observation remains current");
  assert.equal(rows[5].percentageKind, "lastKnown");
  assert.equal(rows[5].resetAt, null, "stale data must not claim the next reset");
});

test("Agenda privacy and row/+N clicks route directly to provider tabs", () => {
  const previousDocument = globalThis.document;
  const previousStorage = globalThis.localStorage;
  const values = new Map([["birdnion.lang", "en"]]);
  globalThis.document = { createElement: (tag) => new FakeElement(tag) };
  globalThis.localStorage = {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: (key) => values.delete(key),
  };

  try {
    const statuses = [1, 2, 3, 4].map((n) => status(
      `p${n}`,
      [window("Session", 90 - n, { resetsAt: NOW + n * 100 })],
    ));
    const selected = [];
    const section = agendaSection.quotaAgendaSection(statuses, {
      agents: statuses.map((item, index) => ({ id: item.id, displayName: `Agent ${index + 1}` })),
      staleWarnings: new Map(),
      hidePersonalInfo: true,
      onProviderSelect: (id) => selected.push(id),
      nowSeconds: NOW,
    });

    assert.equal(descendantsWithClass(section, "quota-agenda-row").length, 3);
    const text = renderedText(section);
    assert.match(text, /QUOTA AGENDA/);
    assert.match(text, /Agent 1/);
    assert.match(text, /Provider p1/);
    assert.match(text, /SESSION/);
    assert.match(text, /89%/);
    assert.match(text, /resets in/);
    assert.match(text, /OAuth/);
    assert.match(text, /Account hidden/);
    assert.match(text, /1m ago/);
    assert.doesNotMatch(text, /p1-private|p1@example\.com/);

    descendantsWithClass(section, "quota-agenda-row")[0].click();
    descendantsWithClass(section, "quota-agenda-more")[0].click();
    assert.deepEqual(selected, ["p1", "p4"]);

    const nonCurrentStatuses = [
      status("awaiting-ui", [window("Session", 40, { resetsAt: NOW - 100 })], {
        lastUpdated: NOW - 200,
      }),
      status("stale-ui", [window("Session", 20, { resetsAt: NOW + 100 })]),
    ];
    const nonCurrent = agendaSection.quotaAgendaSection(nonCurrentStatuses, {
      agents: agentsFor(nonCurrentStatuses),
      staleWarnings: new Map([[
        "stale-ui", { kind: "rateLimited", lastGoodUpdated: NOW - 60 },
      ]]),
      hidePersonalInfo: true,
      onProviderSelect: () => {},
      nowSeconds: NOW,
    });
    const nonCurrentText = renderedText(nonCurrent);
    assert.match(nonCurrentText, /Awaiting refresh/);
    assert.match(nonCurrentText, /Last known/);
    assert.match(nonCurrentText, /20%\*/);
    assert.doesNotMatch(nonCurrentText, /resets in/);

    values.set("birdnion.lang", "vi");
    const visibleAccount = agendaSection.quotaAgendaSection(statuses.slice(0, 1), {
      agents: agentsFor(statuses.slice(0, 1)),
      staleWarnings: new Map(),
      hidePersonalInfo: false,
      onProviderSelect: () => {},
      nowSeconds: NOW,
    });
    assert.match(renderedText(visibleAccount), /LỊCH QUOTA/);
    assert.match(renderedText(visibleAccount), /p1-private/);

    const missingAccountStatuses = [
      status("no-account", [window("Session", 70)], {
        accountLabel: undefined,
        signedInEmail: undefined,
      }),
    ];
    const missingAccount = agendaSection.quotaAgendaSection(missingAccountStatuses, {
      agents: agentsFor(missingAccountStatuses),
      staleWarnings: new Map(),
      hidePersonalInfo: true,
      onProviderSelect: () => {},
      nowSeconds: NOW,
    });
    assert.match(renderedText(missingAccount), /Tài khoản chưa rõ/);
    assert.doesNotMatch(renderedText(missingAccount), /Đã ẩn tài khoản/);

    const visibility = agendaSection.quotaAgendaSection([
      status("hidden", [window("Session", 60)]),
      status("opencodego", [window("Session", 70)]),
    ], {
      agents: [{ id: "opencode", displayName: "OpenCode" }],
      staleWarnings: new Map(),
      hidePersonalInfo: false,
      onProviderSelect: () => {},
      nowSeconds: NOW,
    });
    const visibilityText = renderedText(visibility);
    assert.doesNotMatch(visibilityText, /Provider hidden/);
    assert.match(visibilityText, /OpenCode/);
    assert.match(visibilityText, /Provider opencodego/);

    values.set("birdnion.lang", "en");
    const slot = agendaSection.quotaAgendaSlot(statuses.slice(0, 1), {
      agents: agentsFor(statuses.slice(0, 1)),
      staleWarnings: new Map(),
      hidePersonalInfo: false,
      onProviderSelect: () => {},
      nowSeconds: NOW,
    });
    assert.match(renderedText(slot), /89%/);
    const updated = [status("p1", [window("Session", 24, { resetsAt: NOW + 100 })])];
    agendaSection.refreshQuotaAgendaSlot(slot, updated, {
      agents: agentsFor(updated),
      staleWarnings: new Map([["p1", { kind: "rateLimited", lastGoodUpdated: NOW - 60 }]]),
      hidePersonalInfo: true,
      onProviderSelect: () => {},
      nowSeconds: NOW,
    });
    assert.match(renderedText(slot), /24%\*/);
    assert.match(renderedText(slot), /Last known/);
    assert.doesNotMatch(renderedText(slot), /p1-private|p1@example\.com/);
    agendaSection.refreshQuotaAgendaSlot(slot, updated, {
      agents: null,
      staleWarnings: new Map(),
      hidePersonalInfo: false,
      onProviderSelect: () => {},
      nowSeconds: NOW,
    });
    assert.equal(slot.children.length, 0);

    const configuredSlot = configuredSection.configuredAgentsSlot([
      { id: "p1", displayName: "Agent p1" },
    ]);
    assert.equal(configuredSlot.children.length, 1);
    configuredSection.refreshConfiguredAgentsSlot(configuredSlot, []);
    assert.equal(configuredSlot.children.length, 0, "Agenda transition removes configured duplicate");
    configuredSection.refreshConfiguredAgentsSlot(configuredSlot, [
      { id: "p1", displayName: "Agent p1" },
    ]);
    assert.equal(configuredSlot.children.length, 1, "missing Agenda restores configured row");
  } finally {
    if (previousDocument === undefined) delete globalThis.document;
    else globalThis.document = previousDocument;
    if (previousStorage === undefined) delete globalThis.localStorage;
    else globalThis.localStorage = previousStorage;
  }
});
