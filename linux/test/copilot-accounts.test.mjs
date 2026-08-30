import test from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";

const stubs = new Map(Object.entries({
  "@tauri-apps/api/core": "export async function invoke() { throw new Error('unused'); }",
  "@tauri-apps/api/event": "export async function emit() {}",
  "@tauri-apps/plugin-opener": "export async function openUrl() {}",
}).map(([name, source]) => [name, `data:text/javascript,${encodeURIComponent(source)}`]));

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (stubs.has(specifier)) return { url: stubs.get(specifier), shortCircuit: true };
    const relative = (specifier.startsWith("./") || specifier.startsWith("../"))
      && !/[.]([cm]?js|ts|json)$/.test(specifier);
    return nextResolve(relative ? `${specifier}.ts` : specifier, context);
  },
});

const { performCopilotAccountMutation } = await import("../src/settings-copilot-login.ts");

test("Copilot mutation barrier invalidates before work and refreshes after", async () => {
  const order = [];
  const result = await performCopilotAccountMutation(
    async () => { order.push("operation"); return "next-state"; },
    async ({ phase, origin }) => { order.push(`${phase}:${origin}`); },
  );
  assert.equal(result, "next-state");
  assert.deepEqual(order, ["before:settings", "operation", "after:settings"]);
});

test("Copilot mutation barrier always sends the after pulse on failure", async () => {
  const order = [];
  await assert.rejects(() => performCopilotAccountMutation(
    async () => { order.push("operation"); throw new Error("failed"); },
    async ({ phase }) => { order.push(phase); },
  ));
  assert.deepEqual(order, ["before", "operation", "after"]);
});
