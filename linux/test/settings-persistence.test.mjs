import test from "node:test";
import assert from "node:assert/strict";

import { saveRevisionedSettings } from "../src/settings-persistence.ts";

test("serializes saves and advances the shared in-memory revision", async () => {
  const settings = { settingsRevision: 5, value: "first" };
  const seen = [];
  let finishFirst;
  const command = async (snapshot) => {
    seen.push({ revision: snapshot.settingsRevision, value: snapshot.value });
    if (seen.length === 1) {
      return new Promise((resolve) => { finishFirst = () => resolve(6); });
    }
    return 7;
  };

  const first = saveRevisionedSettings(settings, command);
  await Promise.resolve();
  settings.value = "second";
  const second = saveRevisionedSettings(settings, command);
  await Promise.resolve();
  assert.equal(seen.length, 1);

  finishFirst();
  assert.equal(await first, 6);
  assert.equal(await second, 7);
  assert.deepEqual(seen.map(({ revision }) => revision), [5, 6]);
  assert.equal(settings.settingsRevision, 7);
});

test("refuses fallback settings without a backend revision", async () => {
  const settings = { value: "unsafe fallback" };
  let invoked = false;

  await assert.rejects(
    saveRevisionedSettings(settings, async () => {
      invoked = true;
      return 1;
    }),
    /missing a valid revision/,
  );
  assert.equal(invoked, false);
});

test("a failed save does not poison the per-object queue", async () => {
  const settings = { settingsRevision: 2 };
  await assert.rejects(
    saveRevisionedSettings(settings, async () => { throw new Error("stale"); }),
    /stale/,
  );
  assert.equal(
    await saveRevisionedSettings(settings, async () => 3),
    3,
  );
});

test("an in-flight save never lowers a newer external snapshot revision", async () => {
  const settings = { settingsRevision: 5, value: "before" };
  let finishSave;
  const saving = saveRevisionedSettings(
    settings,
    async () => new Promise((resolve) => { finishSave = () => resolve(6); }),
  );
  await Promise.resolve();

  // Simulates settings-tab applying a complete revision-7 snapshot emitted
  // by an account mutation in another webview before save(rev5) returns.
  settings.settingsRevision = 7;
  settings.value = "canonical";
  finishSave();

  assert.equal(await saving, 7);
  assert.equal(settings.settingsRevision, 7);
  assert.equal(settings.value, "canonical");
});
