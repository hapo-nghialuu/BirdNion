import test from "node:test";
import assert from "node:assert/strict";

import {
  activeUsageSourceIds,
  combine,
  combinedDaySourceUsage,
  combinedWindowSourceTotals,
  digestWindowStats,
  monthlyForecast,
  USAGE_SOURCE_IDS,
} from "../src/usage.ts";

function report({ usd, tokens, last30Usd = usd, last30Tokens = tokens }) {
  return {
    todayUsd: usd,
    todayTokens: tokens,
    last30Usd,
    last30Tokens,
    daily: [{
      date: "2026-08-25",
      usd,
      tokens,
      models: [{ name: "kiro-model", usd, tokens }],
    }],
    hourly: [],
    topModel: "kiro-model",
    included: true,
    live: true,
    scannedAt: 1,
  };
}

function budgetDay(date, usd) {
  return { date, usd };
}

test("Kiro participates in combined last-30 totals", () => {
  const combined = combine(null, null, null, null, null, report({
    usd: 4,
    tokens: 400,
    last30Usd: 9,
    last30Tokens: 900,
  }));

  assert.equal(combined.last30Usd, 9);
  assert.equal(combined.last30Tokens, 900);
  assert.deepEqual(USAGE_SOURCE_IDS, ["claude", "codex", "grok", "kiro", "omp", "pi"]);
  assert.deepEqual(combinedDaySourceUsage(combined.daily[0], "kiro"), {
    usd: 4,
    tokens: 400,
  });
  assert.deepEqual(combinedWindowSourceTotals(combined.daily).kiro, {
    usd: 4,
    tokens: 400,
  });

  const tokenOnly = combine(null, null, null, null, null, report({ usd: 0, tokens: 100 }));
  assert.deepEqual(activeUsageSourceIds(tokenOnly.daily), ["kiro"]);
});

test("Kiro participates in digest totals and top-source selection", () => {
  const combined = combine(null, null, null, null, null, report({ usd: 4, tokens: 400 }));
  const stats = digestWindowStats(
    combined.daily,
    "2026-08-25",
    "2026-08-25",
    new Set(["kiro"]),
  );

  assert.equal(stats.usd, 4);
  assert.equal(stats.tokens, 400);
  assert.equal(stats.topSource, "kiro");
});

test("Kiro synthetic Other conserves totals but never wins model rankings", () => {
  const kiro = report({ usd: 5.5, tokens: 550 });
  kiro.daily[0].models = [
    { name: "real-model", usd: 1, tokens: 100 },
    { name: "Other", usd: 4.5, tokens: 450 },
  ];
  kiro.topModel = "real-model";
  const combined = combine(null, null, null, null, null, kiro);
  const stats = digestWindowStats(
    combined.daily,
    "2026-08-25",
    "2026-08-25",
    new Set(["kiro"]),
  );

  assert.equal(combined.todayTokens, 550);
  assert.deepEqual(combined.topModels.map((model) => model.name), ["real-model"]);
  assert.equal(stats.tokens, 550);
  assert.equal(stats.topModel?.name, "real-model");
});

test("Kiro provider budget never includes another source", () => {
  const combined = combine(
    report({ usd: 90, tokens: 900 }),
    null,
    null,
    null,
    null,
    report({ usd: 10, tokens: 100 }),
  );
  const forecast = monthlyForecast(
    combined.daily,
    100,
    new Date(2026, 7, 25, 12),
    "kiro",
    "week",
  );

  assert.equal(forecast?.monthToDateUsd, 10);
});

test("weekly budget follows ISO Monday-Sunday boundaries", () => {
  const sunday = monthlyForecast(
    [budgetDay("2026-08-17", 17), budgetDay("2026-08-23", 23)],
    100,
    new Date(2026, 7, 23, 12),
    "total",
    "week",
  );
  assert.equal(sunday?.monthToDateUsd, 40);
  assert.equal(sunday?.daysElapsed, 7);

  const monday = monthlyForecast(
    [budgetDay("2026-08-23", 23), budgetDay("2026-08-24", 24)],
    100,
    new Date(2026, 7, 24, 12),
    "total",
    "week",
  );
  assert.equal(monday?.monthToDateUsd, 24);
  assert.equal(monday?.daysElapsed, 1);
});

test("weekly budget counts local calendar days across DST", () => {
  const previousTimeZone = process.env.TZ;
  process.env.TZ = "Asia/Gaza";
  try {
    assert.notEqual(
      new Date(2024, 3, 15).getTimezoneOffset(),
      new Date(2024, 3, 21).getTimezoneOffset(),
    );
    const forecast = monthlyForecast(
      [budgetDay("2024-04-15", 70)],
      100,
      new Date(2024, 3, 21, 12),
      "total",
      "week",
    );

    assert.equal(forecast?.daysElapsed, 7);
    assert.equal(forecast?.projectedUsd, 70);
  } finally {
    if (previousTimeZone == null) delete process.env.TZ;
    else process.env.TZ = previousTimeZone;
  }
});

test("Kiro agent panel receives its real cost days and local log", async () => {
  globalThis.localStorage ??= {
    getItem: () => "en",
    setItem: () => {},
    removeItem: () => {},
  };
  const { buildAgentPanelPayload } = await import("../src/agent-panel-payload.ts");
  const combined = combine(null, null, null, null, null, report({ usd: 4, tokens: 400 }));
  const payload = buildAgentPanelPayload({
    agentId: "kiro",
    displayName: "Kiro",
    daily: combined.daily,
    source: "kiro",
  });

  assert.equal(payload.costDays?.[0]?.usd, 4);
  assert.equal(payload.costDays?.[0]?.tokens, 400);
  assert.equal(payload.costDays?.[0]?.models[0]?.source, "kiro");
  assert.equal(payload.configRows.some((row) => row.value === "~/.kiro/sessions/cli"), true);
});
