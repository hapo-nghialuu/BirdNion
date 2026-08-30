import test from "node:test";
import assert from "node:assert/strict";

const autoPrime = await import("../src/codex-auto-prime.ts");

class MemoryStorage {
  values = new Map();

  getItem(key) {
    return this.values.get(key) ?? null;
  }

  setItem(key, value) {
    this.values.set(key, String(value));
  }
}

function codexStatus(usedPct, windowSeconds = 18_000) {
  return {
    id: "codex",
    displayName: "Codex",
    lastUpdated: 1,
    windows: [{
      label: "5 giờ",
      usedPct,
      remainingPct: 100 - usedPct,
      windowSeconds,
    }],
  };
}

function enabledStorage(minutes = 8 * 60 + 55) {
  const storage = new MemoryStorage();
  autoPrime.saveCodexAutoPrimePreferences({ enabled: true, scheduledMinutes: minutes }, storage);
  return storage;
}

test("auto-prime defaults off at 08:55 and clamps persisted minutes", () => {
  const storage = new MemoryStorage();
  assert.deepEqual(autoPrime.loadCodexAutoPrimePreferences(storage), {
    enabled: false,
    scheduledMinutes: 535,
    lastAttemptMs: 0,
  });

  autoPrime.saveCodexAutoPrimePreferences({ enabled: true, scheduledMinutes: 9_999 }, storage);
  assert.equal(autoPrime.loadCodexAutoPrimePreferences(storage).scheduledMinutes, 1439);
});

test("decision catches up after schedule but skips used windows and same-day attempts", () => {
  const now = new Date(2026, 7, 30, 9, 5);
  const common = { now, enabled: true, scheduledMinutes: 535, lastAttemptMs: 0 };
  assert.equal(autoPrime.shouldPrimeCodex(common), true);
  assert.equal(autoPrime.shouldPrimeCodex({ ...common, now: new Date(2026, 7, 30, 8, 54) }), false);
  assert.equal(autoPrime.shouldPrimeCodex({ ...common, windowUsedPct: 1 }), false);
  assert.equal(autoPrime.shouldPrimeCodex({
    ...common,
    lastAttemptMs: new Date(2026, 7, 30, 8, 56).getTime(),
  }), false);
  assert.equal(autoPrime.shouldPrimeCodex({
    ...common,
    lastAttemptMs: new Date(2026, 7, 29, 9, 5).getTime(),
  }), true);
});

test("5h detector prefers semantic duration and ignores supplementary windows", () => {
  const status = codexStatus(7);
  status.windows.unshift({
    label: "Bonus 5h",
    usedPct: 99,
    remainingPct: 1,
    isSupplementary: true,
  });
  assert.equal(autoPrime.codexFiveHourUsedPct(status), 7);
  assert.equal(autoPrime.codexFiveHourUsedPct(codexStatus(12, undefined)), 12);
});

test("attempt stamps before await and an overlapping tick cannot invoke twice", async () => {
  const storage = enabledStorage();
  const now = new Date(2026, 7, 30, 9, 5);
  let release;
  const pending = new Promise((resolve) => { release = resolve; });
  let calls = 0;
  const invokePrime = async () => {
    calls += 1;
    await pending;
    return true;
  };

  const first = autoPrime.maybePrimeCodex({ status: codexStatus(0), invokePrime, now, storage });
  assert.equal(Number(storage.getItem(autoPrime.CODEX_AUTO_PRIME_LAST_ATTEMPT_KEY)), now.getTime());
  assert.equal(await autoPrime.maybePrimeCodex({ status: codexStatus(0), invokePrime, now, storage }), "skipped");
  release();
  assert.equal(await first, "succeeded");
  assert.equal(calls, 1);
});

test("failed process remains one attempt for the day and never reports success", async () => {
  const storage = enabledStorage();
  const now = new Date(2026, 7, 30, 9, 5);
  let successCalls = 0;
  const result = await autoPrime.maybePrimeCodex({
    status: codexStatus(0),
    invokePrime: async () => false,
    onSuccess: () => { successCalls += 1; },
    now,
    storage,
  });
  assert.equal(result, "attempted");
  assert.equal(successCalls, 0);
  assert.equal(await autoPrime.maybePrimeCodex({
    status: codexStatus(0),
    invokePrime: async () => true,
    now,
    storage,
  }), "skipped");
});
