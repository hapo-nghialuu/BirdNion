import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";

const tauriCore = `data:text/javascript,${encodeURIComponent(
  "export async function invoke() { throw new Error('unused in pure test'); }",
)}`;
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "@tauri-apps/api/core") return { url: tauriCore, shortCircuit: true };
    const relative = (specifier.startsWith("./") || specifier.startsWith("../"))
      && !/[.]([cm]?js|ts|json)$/.test(specifier);
    return nextResolve(relative ? `${specifier}.ts` : specifier, context);
  },
});

const { profileHealth } = await import("../src/ai-coding-profile-popover.ts");

const proxy = { running: false, claudeProfileId: null, codexProfileId: null };
const row = {
  agent: "claude",
  profileId: "one",
  name: "One",
  expectedSnapshot: "opaque",
  ready: true,
  active: false,
  current: false,
  usesProxy: false,
  targetPath: "~/.claude/settings.json",
  profileFlag: null,
};

test("profile health is derived from real config and proxy facts", () => {
  assert.equal(profileHealth({ ...row, ready: false }, proxy), "needsSetup");
  assert.equal(profileHealth(row, proxy), "ready");
  assert.equal(profileHealth({ ...row, active: true }, proxy), "stale");
  assert.equal(profileHealth({ ...row, current: true }, proxy), "stale");
  assert.equal(profileHealth({ ...row, active: true, current: true }, proxy), "active");
  assert.equal(profileHealth({
    ...row,
    active: true,
    current: true,
    usesProxy: true,
  }, proxy), "stale");
  assert.equal(profileHealth({
    ...row,
    active: true,
    current: true,
    usesProxy: true,
  }, { running: true, claudeProfileId: "one", codexProfileId: null }), "active");
});

test("a different provider proxy cannot make a profile active", () => {
  const codex = { ...row, agent: "codex", active: true, current: true, usesProxy: true };
  assert.equal(profileHealth(codex, {
    running: true,
    claudeProfileId: "one",
    codexProfileId: "other",
  }), "stale");
});
