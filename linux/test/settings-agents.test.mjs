import test from "node:test";
import assert from "node:assert/strict";

import {
  countAgentsByFilter,
  configOnlyAgents,
  enabledProviderIds,
  loadInstalledAgents,
  matchesAgentFilter,
  quotaProviderIds,
} from "../src/settings-agents.ts";

function agent(overrides = {}) {
  return {
    id: "claude",
    displayName: "Claude Code",
    kind: "cli",
    sourceLabel: "Claude Code / CLI",
    hasQuota: false,
    hasCost: false,
    hasConfig: true,
    cost90dUsd: null,
    ...overrides,
  };
}

test("derive current enabled and quota provider ids from live settings/status state", () => {
  assert.deepEqual(enabledProviderIds({
    providers: [
      { id: "claude", enabled: true },
      { id: "codex", enabled: false },
      { id: "grok", enabled: true },
    ],
  }), ["claude", "grok"]);

  assert.deepEqual(quotaProviderIds([
    { id: "claude", windows: [{ label: "5h" }] },
    { id: "codex", windows: [] },
    { id: "grok", windows: [{ label: "weekly" }] },
  ]), ["claude", "grok"]);
});

test("loadInstalledAgents forwards camelCase providerIdsWithQuota from current quota-bearing providers", async () => {
  const calls = [];
  const expectedAgents = [
    agent({ id: "claude", hasQuota: true }),
    agent({ id: "codex", displayName: "Codex CLI", hasQuota: false }),
  ];

  const invoke = async (cmd, args) => {
    calls.push([cmd, args]);
    if (cmd === "get_settings") {
      return {
        version: 1,
        providers: [
          { id: "claude", enabled: true },
          { id: "codex", enabled: true },
          { id: "grok", enabled: false },
        ],
      };
    }
    if (cmd === "provider_statuses") {
      assert.deepEqual(args, { ids: ["claude", "codex"] });
      return [
        { id: "claude", windows: [{ label: "5h" }] },
        { id: "codex", windows: [] },
      ];
    }
    if (cmd === "list_installed_agents") {
      assert.deepEqual(args, { providerIdsWithQuota: ["claude"] });
      return expectedAgents;
    }
    throw new Error(`Unexpected command: ${cmd}`);
  };

  const agents = await loadInstalledAgents(invoke);
  assert.deepEqual(agents, expectedAgents);
  assert.deepEqual(calls.map(([cmd]) => cmd), [
    "get_settings",
    "provider_statuses",
    "list_installed_agents",
  ]);
});

test("loadInstalledAgents avoids stale quota ids when nothing is enabled", async () => {
  const calls = [];
  const invoke = async (cmd, args) => {
    calls.push([cmd, args]);
    if (cmd === "get_settings") return { version: 1, providers: [{ id: "claude", enabled: false }] };
    if (cmd === "list_installed_agents") {
      assert.deepEqual(args, { providerIdsWithQuota: [] });
      return [agent({ id: "omp", displayName: "Oh My Pi" })];
    }
    throw new Error(`Unexpected command: ${cmd}`);
  };

  const agents = await loadInstalledAgents(invoke);
  assert.equal(agents.length, 1);
  assert.deepEqual(calls.map(([cmd]) => cmd), [
    "get_settings",
    "list_installed_agents",
  ]);
});

test("quota counts and filters follow backend hasQuota flags", () => {
  const agents = [
    agent({ id: "claude", hasQuota: true, hasCost: true }),
    agent({ id: "codex", displayName: "Codex CLI", hasQuota: false, hasCost: true }),
    agent({ id: "omp", displayName: "Oh My Pi", hasQuota: false, hasCost: false }),
  ];

  assert.deepEqual(countAgentsByFilter(agents), {
    all: 3,
    quota: 1,
    cost: 2,
    config: 1,
  });
  assert.equal(matchesAgentFilter(agents[0], "quota"), true);
  assert.equal(matchesAgentFilter(agents[1], "quota"), false);
  assert.equal(matchesAgentFilter(agents[2], "config"), true);
  assert.equal(matchesAgentFilter(agents[1], "all", "codex"), true);
  assert.equal(matchesAgentFilter(agents[1], "all", "claude"), false);
  assert.deepEqual(
    configOnlyAgents([
      agent({ id: "kiro", displayName: "Kiro", hasConfig: true }),
      agent({ id: "omp", displayName: "Oh My Pi", hasConfig: false }),
      agent({ id: "codex", hasConfig: true, hasCost: true }),
    ], ["kiro", "omp", "codex"]),
    [agent({ id: "kiro", displayName: "Kiro", hasConfig: true })],
  );
});
