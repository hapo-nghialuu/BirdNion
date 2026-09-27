# CodexBar upstream research (2026-09-26)

Source: `steipete/CodexBar` @ `5aaa29f` (v0.67.x). BirdNion vendors a trimmed
`CodexBarCore` in `Vendor/CodexBar`; upstream has since grown to **87 providers**
plus a CLI, widgets, and a JS plugin engine. This note records what is worth
learning/porting and the plugin API contract used by the plugin engine work.

## Learnings / candidate features

1. **JS/TS plugin engine** — ~40 providers run as bundled `.js`/`.ts` plugins
   executed by QuickJS (`Sources/CodexBarCore/Resources/Plugins/`,
   engine in `Sources/CodexBarCore/Plugins/`). Users can drop in new providers
   without an app release; manifests declare endpoints, auth, settings and
   capabilities (`browser-cookies`, `http-status`, `persistent-storage`).
2. **Cross-platform CLI** — `codexbar usage --json`, `config providers|enable|
   set-api-key --stdin`, `serve` (local HTTP JSON). Unlocks scripting and
   third-party surfaces (the Omarchy bar widget consumes `serve`).
3. **Burn Down widgets (WidgetKit)** — desktop widget drawing burn-down for
   any quota with used + window + reset (`Sources/CodexBarWidget`).
4. **Hooks** — `HookEvent` (usage updated / threshold crossed / reset) →
   user-defined shell commands (`Sources/CodexBarCore/Hooks/`).
5. **Stay Awake** — IOPMAssertion while a local agent session is live
   (`StatusItemController+AgentSessions.swift`). Fits BirdNion's agent-scan
   model.
6. **Credential-expiry notifications** — account-scoped, one alert per failure
   episode, never include tokens/emails (`docs/credential-notifications.md`).
   BirdNion already has quota-threshold alerts; auth-expiry is the gap.
7. **iCloud sync + portable preferences** — sync snapshots/settings between
   Macs (`Sync/`), export/import UI prefs as versioned JSON.
8. **Preferred Currency** — spend estimates in user's currency with daily FX
   rates and offline fallback (`CurrencyExchange.swift`), VND included.
9. **Shared reporting periods** — month-to-date / all-history across menu,
   Usage & Spend, CLI, HTTP output, widgets.
10. **Status health dots** — provider service-status polling surfaces incident
    badges in Settings sidebar + menu bar icon overlay.
11. **Homebrew one-click upgrade** — `brew upgrade --cask` from menu/About
    (BirdNion's UpdateChecker only links to the release page).
12. **Process practices** — every sensitive feature ships a `docs/<name>.md`
    with `summary`/`read_when` frontmatter + a written contract (cookie-denial
    persistence, atomic credential writes, notification episode scoping);
    detailed CHANGELOG with per-PR credits.

## New providers upstream has that BirdNion lacks

Mistral, Kimi, Augment, Vertex AI, Manus, T3 Chat, Factory/Droid, Venice, Warp,
Zed, Windsurf, AMP, Abacus, Codebuff, Doubao, Stepfun, Synthetic, Moonshot,
HuggingFace, Replicate, Wayfinder, LiteLLM, llmman, DevPass, Atlas Cloud,
Vercel AI Gateway, Raycast, Aixy, xKiro, Sakana, Bifrost, Chutes, DeepInfra,
Fireworks, GitKraken, Hyper, LLMProxy, Muse, NeuralWatt, Perplexity, Qoder,
ZenMux, ai&, ClawRouter, HelmCode, ClinePass, Qwen Cloud, Azure OpenAI,
Alibaba Token Plan, Nous Portal, Muse Code, Atlas Cloud, ZoomMate (~60 total).

## Plugin API contract (what BirdNion's engine mirrors)

Each plugin is one `.js` (or `.ts`) file calling `defineProvider({...})`:

```js
defineProvider({
  id: "atlascloud",
  name: "Atlas Cloud",
  endpoints: ["https://api.atlascloud.ai"],          // allowed origins only
  auth: { type: "bearer", secret: "ATLASCLOUD_API_KEY" },
  settings: [{ key: "ATLASCLOUD_API_KEY", title: "Atlas Cloud API key", type: "secure" }],
  capabilities: ["http-status"],                     // browser-cookies | http-status | persistent-storage
  async fetchUsage(ctx) {
    const r = await ctx.http.get("https://api.atlascloud.ai/public/v1/balance");
    if (r.status === 401) throw ctx.fail.authenticationExpired("...");
    // ...parse r.bodyText, build snapshot
    return {
      primary: { usedPercent: 42, windowMinutes: 300, resetsAt: "..." },
      extraWindows: [{ id: "w", title: "Weekly", usedPercent: 10 }],
      details: [{ title: "Balance", rows: [{ label: "Available", value: "$5.00" }] }],
      identity: { loginMethod: "API" },
      dataConfidence: "exact",
    };
  },
});
```

`ctx` surface: `http.get/getJSON/post/postJSON/getWithOptional` (bounded,
endpoint-scoped), `settings.get/getSecret`, `browser.*` (cookie broker),
`html.*`, `date.*`, `format.*`, `fail.*` (typed errors: authenticationExpired,
missingCredential, permissionDenied, rateLimited, providerUnavailable,
parseFailure, networkFailure, apiFailure), `cache`, `storage`, `jwt.decode`,
`log`, `pct(used,limit)`, `amountFromPercent`, `env.timeZone`.

Result (`CodexBarUsageSnapshot`): `primary`/`secondary`/`tertiary`/
`extraWindows` rate windows (`usedPercent`, `windowMinutes`, `resetsAt`,
`resetDescription`), `cost` (`used/limit/currency/balance`), `costUsage`
(daily ledger), `identity` (email/org/loginMethod), `details` sections,
`subscriptionRenewsAt/ExpiresAt`, `dataConfidence`.

Mapping to BirdNion: rate windows → `QuotaWindow` (usedPct/remainingPct/
resetDate/windowSeconds, `usageKnown:false` → isInactive semantics),
`cost` → `ProviderCostSnapshot`, `details` → provider detail rows,
`identity` → `accountLabel`.

Key design files upstream (for reference when porting):
- `Sources/CodexBarCore/Plugins/ProviderPluginEngine.swift`,
  `QuickJSProviderPluginEngine.swift`, `ProviderPluginManifest.swift`,
  `ProviderPluginSnapshotMapper.swift`, `UserProviderPlugins.swift`
- `Resources/Plugins/codexbar-plugin.d.ts` — full TypeScript contract
