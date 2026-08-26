import test from "node:test";
import assert from "node:assert/strict";

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

async function loadInsightsModule() {
  const { createServer } = await import("vite");
  const server = await createServer({
    root: new URL("..", import.meta.url).pathname,
    configFile: false,
    server: { middlewareMode: true },
    appType: "custom",
    optimizeDeps: { noDiscovery: true },
  });
  return {
    module: await server.ssrLoadModule("/src/insights-pane.ts"),
    close: () => server.close(),
  };
}

test("Insights renders canonical labels for all six local cost sources", async () => {
  const loaded = await loadInsightsModule();

  try {
    const { sourceName } = loaded.module;
    assert.deepEqual(
      ["claude", "codex", "grok", "kiro", "omp", "pi"].map(sourceName),
      ["Claude", "Codex", "Grok", "Kiro", "Oh My Pi", "Pi"],
    );
  } finally {
    await loaded.close();
  }
});

test("activity drops Kiro revoked while its delayed scan is in flight", async () => {
  const loaded = await loadInsightsModule();
  try {
    const { createInsightsActivityRequestCoordinator } = loaded.module;
    const kiroScan = deferred();
    const kiroStarted = deferred();
    let canonical = new Set(["claude", "kiro"]);
    const coordinator = createInsightsActivityRequestCoordinator({
      readCanonicalSources: async () => new Set(canonical),
      scanSource: async (source) => {
        if (source === "kiro") {
          kiroStarted.resolve();
          return kiroScan.promise;
        }
        return { todayUsd: 1, todayTokens: 10, daily: [], hourly: [], models: [] };
      },
    });

    const loading = coordinator.load();
    await kiroStarted.promise;
    canonical = new Set(["claude"]);
    kiroScan.resolve({ todayUsd: 99, todayTokens: 990, daily: [], hourly: [], models: [] });
    const result = await loading;

    assert.equal(result.current, true);
    assert.equal(result.value.claude.todayUsd, 1);
    assert.equal(result.value.kiro, null);
  } finally {
    await loaded.close();
  }
});

test("newer activity generation rejects an older delayed completion", async () => {
  const loaded = await loadInsightsModule();
  try {
    const { createInsightsActivityRequestCoordinator } = loaded.module;
    const oldScan = deferred();
    const oldStarted = deferred();
    let scanCount = 0;
    const coordinator = createInsightsActivityRequestCoordinator({
      readCanonicalSources: async () => new Set(["claude"]),
      scanSource: async () => {
        scanCount += 1;
        if (scanCount === 1) {
          oldStarted.resolve();
          return oldScan.promise;
        }
        return { todayUsd: 2, todayTokens: 20, daily: [], hourly: [], models: [] };
      },
    });

    const older = coordinator.load();
    await oldStarted.promise;
    const newer = await coordinator.load();
    oldScan.resolve({ todayUsd: 99, todayTokens: 990, daily: [], hourly: [], models: [] });

    assert.equal(newer.current, true);
    assert.equal(newer.value.claude.todayUsd, 2);
    assert.deepEqual(await older, { current: false, value: null });
  } finally {
    await loaded.close();
  }
});

test("history rejects a delayed report containing a provider revoked during await", async () => {
  const loaded = await loadInsightsModule();
  try {
    const { createInsightsHistoryRequestCoordinator } = loaded.module;
    const delayedReport = deferred();
    const reportStarted = deferred();
    let canonical = new Set(["codex"]);
    const coordinator = createInsightsHistoryRequestCoordinator({
      readCanonicalSources: async () => new Set(canonical),
      fetchReport: async () => {
        reportStarted.resolve();
        return delayedReport.promise;
      },
    });

    const loading = coordinator.load(7, null);
    await reportStarted.promise;
    canonical = new Set();
    delayedReport.resolve({
      days: 7,
      overview: {
        current7Usd: 20,
        current7Tokens: 200,
        previous7Usd: 0,
        previous7Tokens: 0,
        changePct: null,
        topSource: { source: "codex", usd: 20, tokens: 200 },
        topModel: { source: "codex", name: "gpt", usd: 20, tokens: 200 },
        topProject: null,
        confidence: [{ source: "codex", state: "history", scannedAt: null }],
      },
      projects: [],
      selectedProject: null,
    });
    const result = await loading;

    assert.equal(result.current, true);
    assert.equal(result.value, null);
  } finally {
    await loaded.close();
  }
});
