# Feature research — round 2 (2026-10-01)

Sources: upstream `steipete/CodexBar` @ `5aaa29f` (v0.67.1), `ryoppippi/ccusage`
(~19 CLI usage sources), BirdNion tree @ `7b6be8b`. Round 1 ported plugin
engine (#33), Burn Down widget (#34), Hooks (#35). This note lists what is
still worth building, ordered by estimated value/effort.

## Still open from round 1 (upstream already ships these)

1. **Stay Awake** — `IOPMAssertion` while a local agent session is live;
   opt-in toggle + menu indicator (upstream `StatusItemController+AgentSessions`).
   Fits BirdNion's installed-agent detection (`InstalledAgentDetectors.swift`).
2. **Credential-expiry notifications** — BirdNion has quota-threshold alerts
   but silent auth expiry is the gap; upstream contract: account-scoped, one
   alert per failure episode, never include tokens/emails
   (upstream `docs/credential-notifications.md`).
3. **Portable preferences** — export/import UI settings as versioned JSON,
   keeps dotfiles-friendly config (upstream `Sources/CodexBarCore/Sync/`).
4. **Preferred Currency (VND!)** — spend estimates in local currency with
   daily FX rates + offline fallback; upstream added VND, THB, IDR…
   Fits BirdNion's Cost tab directly.
5. **BirdNion CLI** — `birdnion usage --json`, `config set-api-key --stdin`,
   `serve` local HTTP JSON. Unlocks scripting + third-party bars (upstream's
   `serve` feeds the Omarchy widget).

## New since round 1 (upstream 0.67.x)

6. **One-click Homebrew upgrade** — menu item + About button run
   `brew upgrade --cask birdnion`; BirdNion currently only links releases.
7. **Shared reporting periods** — month-to-date vs all-history picker shared
   across menus/spend/CLI/widgets; BirdNion's cost periods are hard-coded.
8. **Usage & Spend lazy rows + session naming** — newest-30 rows + "Show all"
   (6× faster layout on long ledgers), sessions named from thread metadata
   and ranked by cost, masked when hide-personal-info is on.
9. **Provider switcher shortcuts** — customizable keyboard shortcuts to jump
   between providers in the popover.
10. **Sidebar health dots** — gray until known; BirdNion sidebar search/index
    could show per-provider service status.

## New providers to port (upstream registry, mostly plugin `.js`)

11. **xKiro** — daily free-token allowance, midnight UTC reset.
12. **Raycast** — monthly AI credits via bundled plugin.
13. **Aixy** — key-scoped usage + personal/shared budgets.
14. **LiteLLM** — per-model token breakdown + budgets.
15. **Venice / ClinePass / Nous Portal / Muse Code / Sakana AI** — each ships
    as a plugin; cheap to port now that BirdNion has the plugin engine.

## From ccusage (cost-scan coverage gap)

BirdNion scans 7 local sources (Claude, Codex, Grok, Kiro, OMP, Pi, Devin).
ccusage covers ~19. Missing sources whose data is local files:

16. **OpenCode / OpenCode Go cost** — providers exist, no local cost scanner.
17. **Gemini CLI / Copilot CLI cost** — JSONL logs, same scanner shape.
18. **Antigravity local history** — upstream decodes its local DB as a marked
    lower bound; BirdNion only reads quota.
19. **Cursor agent / Amp / Droid / Kimi / Qwen / Goose** — local JSONL usage;
    each is a `*CostScanner` port.
20. **Statusline feed** — ccusage emits a compact line for Claude Code's
    statusLine hook; BirdNion could write the same from live quota state so
    the terminal shows quota while coding.

## Native ideas (not from upstream)

21. **Runway forecast** — `QuotaAllowance` typed used/limit + history →
    "hết quota sau ~X ngày" row; the contract shipped in #29 spec'd this as
    P1 and left it pending.
22. **Quota history sparkline** — per-window mini chart over time (snapshot
    log per publish; same data the Burn Down widget already persists).
23. **Budget alerts** — daily/weekly USD cap per provider → notification
    when projected spend crosses it (differs from quota alerts: money, not %).
24. **Popover glance mode** — single-line summary row (worst-off provider +
    today spend) so users don't expand the panel.

## Priority suggestion

Quick wins: 6 (brew upgrade), 4 (VND currency), 2 (credential-expiry alerts).
Highest leverage: 5 (CLI — enables scripting + external surfaces), 21 (runway
— completes the allowance contract's own roadmap), 1 (Stay Awake).
Coverage: 11–15 (port upstream plugins — nearly free with the plugin engine),
16–19 (cost-scan coverage vs ccusage).
