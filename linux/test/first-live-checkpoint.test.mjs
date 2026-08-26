import test from "node:test";
import assert from "node:assert/strict";

import {
  FIRST_LIVE_CHECKPOINTS_KEY,
  beginFirstLiveAttempt,
  checkpointDurationMs,
  canAcknowledgeVisiblePaint,
  completeFirstLiveAttempt,
  firstLivePhase,
  firstLivePersistenceResult,
  loadFirstLiveCheckpoints,
  registerFirstLiveInvalidationBarrier,
  saveFirstLiveCheckpoint,
  shouldApplyFirstLiveCompletion,
  shouldRetainFirstLiveTestOnInvalidation,
} from "../src/first-live-checkpoint.ts";

const ATTEMPT_ID = "11111111-1111-4111-8111-111111111111";

function memoryStorage() {
  const values = new Map();
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
  };
}

function checkpoint(providerId, source, second) {
  const attempt = beginFirstLiveAttempt({
    providerId,
    detectedSource: source,
    setupSavedAtMs: second * 1_000,
    probeStartedAtMs: second * 1_000,
    attemptId: `00000000-0000-4000-8000-${String(second).padStart(12, "0")}`,
    appVersion: "0.10.25",
  });
  assert.ok(attempt);
  return completeFirstLiveAttempt(attempt, second * 1_000 + 1_000, second * 1_000 + 2_000);
}

test("receipt schema and privacy contract match macOS", () => {
  const attempt = beginFirstLiveAttempt({
    providerId: "claude",
    detectedSource: "secret-token-should-not-persist",
    setupSavedAtMs: 100_000,
    probeStartedAtMs: 101_000,
    attemptId: ATTEMPT_ID,
    appVersion: "0.10.25",
  });
  assert.ok(attempt);
  const receipt = completeFirstLiveAttempt(attempt, 102_000, 102_250);

  assert.deepEqual(Object.keys(receipt).sort(), [
    "appVersion", "attemptId", "freshResultReceivedAtMs", "liveRenderedAtMs",
    "platform", "probeStartedAtMs", "providerId", "setupSavedAtMs", "source",
  ]);
  assert.equal(receipt.source, "Claude Code / CLI");
  assert.equal(receipt.platform, "linux");
  assert.equal(checkpointDurationMs(receipt), 1_250);
  assert.doesNotMatch(JSON.stringify(receipt), /secret-token/);
});

test("Guided Setup becomes live only from the current explicit probe", () => {
  assert.equal(firstLivePhase("idle", false, false), "needsSource");
  assert.equal(firstLivePhase("idle", false, true), "readyToTest");
  assert.equal(firstLivePhase("testing", true, true), "testing");
  assert.equal(firstLivePhase("live", false, false), "live");
  assert.equal(firstLivePhase("live", true, true), "failed");
  assert.equal(firstLivePhase("failed", false, true), "failed");
  assert.equal(shouldApplyFirstLiveCompletion("claude", 2, 2, "claude", true), true);
  assert.equal(shouldApplyFirstLiveCompletion("claude", 2, 1, "claude", true), false);
  assert.equal(shouldApplyFirstLiveCompletion("claude", 2, 2, "codex", true), false);
  assert.equal(shouldApplyFirstLiveCompletion("claude", 2, 2, "claude", false), false);
  assert.equal(shouldRetainFirstLiveTestOnInvalidation("testing"), true);
  assert.equal(shouldRetainFirstLiveTestOnInvalidation("live"), false);
  assert.equal(shouldRetainFirstLiveTestOnInvalidation("failed"), false);
  assert.equal(shouldRetainFirstLiveTestOnInvalidation("idle"), false);
  assert.equal(shouldRetainFirstLiveTestOnInvalidation(undefined), false);
});

test("account invalidation listener is a mount barrier, not fire-and-forget", async () => {
  let finishRegistration;
  let registeredHandler;
  let mounted = false;
  const registration = registerFirstLiveInvalidationBarrier(
    (handler) => {
      registeredHandler = handler;
      return new Promise((resolve) => { finishRegistration = resolve; });
    },
    () => { mounted = true; },
  );

  await Promise.resolve();
  assert.equal(mounted, false);
  let barrierResolved = false;
  void registration.then(() => { barrierResolved = true; });
  await Promise.resolve();
  assert.equal(barrierResolved, false);

  finishRegistration(() => {});
  await registration;
  assert.equal(barrierResolved, true);
  registeredHandler();
  assert.equal(mounted, true);
});

test("visible paint requires native visible, restored, and focused window", () => {
  assert.equal(canAcknowledgeVisiblePaint(true, true, false, true), true);
  assert.equal(canAcknowledgeVisiblePaint(false, true, false, true), false);
  assert.equal(canAcknowledgeVisiblePaint(true, false, false, true), false);
  assert.equal(canAcknowledgeVisiblePaint(true, true, true, true), false);
  assert.equal(canAcknowledgeVisiblePaint(true, true, false, false), false);
});

test("store keeps latest successful receipt per provider", () => {
  const storage = memoryStorage();
  const first = checkpoint("codex", "Codex CLI", 100);
  const latest = checkpoint("codex", "Codex CLI", 200);
  const grok = checkpoint("grok", "Grok sessions", 300);

  assert.equal(saveFirstLiveCheckpoint(first, storage), true);
  assert.equal(saveFirstLiveCheckpoint(grok, storage), true);
  assert.equal(saveFirstLiveCheckpoint(latest, storage), true);
  assert.equal(saveFirstLiveCheckpoint(first, storage), false);
  assert.deepEqual(loadFirstLiveCheckpoints(storage), { codex: latest, grok });
});

test("store normalizes entries and preserves an unreadable root", () => {
  const storage = memoryStorage();
  const valid = checkpoint("claude", "Claude Code", 100);
  assert.equal(saveFirstLiveCheckpoint(valid, storage), true);
  assert.equal(saveFirstLiveCheckpoint({ ...valid, attemptId: "not-a-uuid" }, storage), false);
  assert.equal(saveFirstLiveCheckpoint({
    ...valid,
    attemptId: "00000000-0000-0000-0000-000000000000",
  }, storage), false);
  assert.deepEqual(loadFirstLiveCheckpoints(storage).claude, valid);

  storage.setItem(FIRST_LIVE_CHECKPOINTS_KEY, JSON.stringify({
    claude: { ...valid, credential: "SECRET" },
    codex: { attemptId: "corrupt" },
  }));
  assert.deepEqual(loadFirstLiveCheckpoints(storage), { claude: valid });
  const grok = checkpoint("grok", "Grok sessions", 200);
  assert.equal(saveFirstLiveCheckpoint(grok, storage), true);
  assert.doesNotMatch(storage.getItem(FIRST_LIVE_CHECKPOINTS_KEY), /SECRET|credential/);

  const corruptRoot = "{broken";
  storage.setItem(FIRST_LIVE_CHECKPOINTS_KEY, corruptRoot);
  assert.equal(saveFirstLiveCheckpoint(valid, storage), false);
  storage.setItem(FIRST_LIVE_CHECKPOINTS_KEY, "{broken");
  assert.deepEqual(loadFirstLiveCheckpoints(storage), {});
  assert.equal(storage.getItem(FIRST_LIVE_CHECKPOINTS_KEY), corruptRoot);

  const wrongRoot = "[]";
  storage.setItem(FIRST_LIVE_CHECKPOINTS_KEY, wrongRoot);
  assert.equal(saveFirstLiveCheckpoint(valid, storage), false);
  assert.equal(storage.getItem(FIRST_LIVE_CHECKPOINTS_KEY), wrongRoot);

  const unknownRoot = JSON.stringify({ unknown: valid });
  storage.setItem(FIRST_LIVE_CHECKPOINTS_KEY, unknownRoot);
  assert.deepEqual(loadFirstLiveCheckpoints(storage), {});
  assert.equal(saveFirstLiveCheckpoint(valid, storage), false);

  const oversizedRoot = "x".repeat(64 * 1024 + 1);
  storage.setItem(FIRST_LIVE_CHECKPOINTS_KEY, oversizedRoot);
  assert.deepEqual(loadFirstLiveCheckpoints(storage), {});
  assert.equal(saveFirstLiveCheckpoint(valid, storage), false);
});

test("future receipt is dropped and cannot lock current success", () => {
  const storage = memoryStorage();
  const current = checkpoint(
    "claude",
    "Claude Code",
    Math.floor(Date.now() / 1_000) - 5,
  );
  const futureMs = Date.now() + 86_400_000;
  const future = {
    ...current,
    attemptId: "22222222-2222-4222-8222-222222222222",
    setupSavedAtMs: futureMs,
    probeStartedAtMs: futureMs + 1,
    freshResultReceivedAtMs: futureMs + 2,
    liveRenderedAtMs: futureMs + 3,
  };
  storage.setItem(FIRST_LIVE_CHECKPOINTS_KEY, JSON.stringify({ claude: future }));

  assert.deepEqual(loadFirstLiveCheckpoints(storage), {});
  assert.equal(saveFirstLiveCheckpoint(current, storage), true);
  assert.deepEqual(loadFirstLiveCheckpoints(storage), { claude: current });

  const nearFutureMs = Date.now() + 4 * 60 * 1_000;
  const nearFuture = {
    ...current,
    attemptId: "33333333-3333-4333-8333-333333333333",
    setupSavedAtMs: nearFutureMs,
    probeStartedAtMs: nearFutureMs + 1,
    freshResultReceivedAtMs: nearFutureMs + 2,
    liveRenderedAtMs: nearFutureMs + 3,
  };
  storage.setItem(FIRST_LIVE_CHECKPOINTS_KEY, JSON.stringify({ claude: nearFuture }));
  assert.deepEqual(loadFirstLiveCheckpoints(storage), { claude: nearFuture });
  assert.equal(saveFirstLiveCheckpoint(nearFuture, storage), false);
  assert.equal(saveFirstLiveCheckpoint(current, storage), true);
  assert.deepEqual(loadFirstLiveCheckpoints(storage), { claude: current });
});

test("unknown version and cross-provider source fail closed", () => {
  assert.equal(beginFirstLiveAttempt({
    providerId: "claude",
    detectedSource: "Claude Code",
    appVersion: "unknown",
  }), null);
  assert.equal(beginFirstLiveAttempt({
    providerId: "claude",
    detectedSource: "Claude Code",
    appVersion: "token=sk-secret",
  }), null);
  assert.equal(beginFirstLiveAttempt({
    providerId: "claude",
    detectedSource: "Claude Code",
    appVersion: "sk-ant-api03-abcdef123456",
  }), null);
  const attempt = beginFirstLiveAttempt({
    providerId: "claude",
    detectedSource: "Grok sessions",
    setupSavedAtMs: 100_000,
    probeStartedAtMs: 101_000,
    attemptId: ATTEMPT_ID,
    appVersion: "0.10.25",
  });
  assert.ok(attempt);
  assert.equal(attempt.source, "Claude Code / CLI");
  assert.ok(beginFirstLiveAttempt({
    providerId: "claude",
    detectedSource: "Claude Code",
    appVersion: "0.10.25-beta.1",
  }));
});

test("storage denial never changes verification into a thrown error", () => {
  const valid = checkpoint("claude", "Claude Code", 100);
  const denied = {
    getItem: () => { throw new Error("denied"); },
    setItem: () => { throw new Error("denied"); },
  };
  assert.deepEqual(loadFirstLiveCheckpoints(denied), {});
  assert.equal(saveFirstLiveCheckpoint(valid, denied), false);
  assert.deepEqual(firstLivePersistenceResult(false), {
    state: "failed",
    feedbackKey: "guidedSetupReceiptSaveFailed",
  });
  assert.deepEqual(firstLivePersistenceResult(true), { state: "live" });
});
