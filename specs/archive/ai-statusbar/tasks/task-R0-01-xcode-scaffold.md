# Task R0-01: Xcode project scaffold

**Requirement:** Foundation — provides the macOS app target that every later task imports
**Status:** done
**Priority:** P0
**Estimated Effort:** S
**Dependencies:** none
**Spec:** specs/ai-statusbar/

## Context

- **Why**: Every later task (services, providers, views) is `import`ed by the app target. Without a buildable SwiftUI macOS app there is nothing to run.
- **Current state**: Greenfield. No Xcode project exists under `/Users/nghialuutrung/Desktop/statusbar`.
- **Target outcome**: A buildable `AIStatusbar.app` that, when launched, displays a single icon in the macOS menu bar (no Dock icon) and an empty `MenuBarExtra` popover that says "AI Statusbar". The project layout matches `docs/system-architecture.md` §7.

## Constraints

- **MUST**: Deployment target `macOS 13.0` (required for `MenuBarExtra`).
- **MUST**: `Info.plist` `LSUIElement = YES` so the app is menu-bar-only (no Dock icon, no menu bar).
- **MUST**: SwiftUI App lifecycle (`@main` on an `App`-conforming struct), not `AppDelegate`-only.
- **MUST NOT**: Use Xcode-managed signing; ad-hoc local signing only.
- **MUST NOT**: Add third-party SwiftPM dependencies. Everything in foundation/SDK.
- **SCOPE**: Project files only. No provider, no config service — those are later tasks.

## Steps

- [x] 1. Create the Xcode project at `AIStatusbar.xcodeproj/`.
  - Business intent: gives every later code file a target to live in.
  - Code detail: Single macOS app target named `AIStatusbar`, SwiftUI lifecycle, deployment target `13.0`, bundle id `com.local.aistatusbar`, scheme shared.
  - _Requirements: 1.1, 9.1_

- [x] 2. Add `Info.plist` with `LSUIElement = YES`, `CFBundleName = AIStatusbar`, `CFBundleShortVersionString = 0.1.0`.
  - Business intent: makes the app menu-bar-only.
  - Code detail: at `AIStatusbar/Info.plist`.
  - _Requirements: 1.1_

- [x] 3. Add `AIStatusbarApp.swift` with `@main` `App` struct and a `MenuBarExtra` showing the system image `chart.bar.xaxis` and a popover placeholder Text("AI Statusbar").
  - Business intent: proves the menu bar entry is wired before any feature is built.
  - Code detail: `MenuBarExtra("AI Statusbar", systemImage: "chart.bar.xaxis") { Text("AI Statusbar") }`.
  - _Requirements: 1.1, 1.2, 9.2_

- [x] 4. Create the empty group folders that match `docs/system-architecture.md` §7: `AIStatusbar/Views/`, `AIStatusbar/Services/`, `AIStatusbar/Models/`, `AIStatusbar/Providers/`, `AIStatusbar/Resources/`.
  - Business intent: prevents later "where does this go?" friction.
  - Code detail: directories with a `.gitkeep` each so git tracks them.
  - _Requirements: 9.4_

- [x] 5. Disable code signing for Debug; use ad-hoc for Release in build settings.
  - Business intent: lets the user `xcodebuild` locally without an Apple Developer account.
  - Code detail: `CODE_SIGN_IDENTITY = "-"` and `CODE_SIGN_STYLE = Manual` for Release; `CODE_SIGNING_REQUIRED = NO` for Debug.
  - _Requirements: 9.1_

- [x] 6. Verification — build and run.
  - _Requirements: 9.1, 9.2_

## Requirements

- 1.1 — App displays single menu bar icon, no Dock icon.
- 1.2 — Clicking the icon opens a popover.
- 9.1 — `xcodebuild -scheme AIStatusbar -configuration Debug build` exits 0.
- 9.2 — Built `.app` launches and the menu bar icon appears within 2s.
- 9.4 — No orphan modules; every later service is imported by `AIStatusbarApp` (verified once those tasks land).

## Related Files

| Path | Action | Description |
|---|---|---|
| `AIStatusbar.xcodeproj/project.pbxproj` | Create | Xcode project file |
| `AIStatusbar/Info.plist` | Create | Menu-bar-only configuration |
| `AIStatusbar/AIStatusbarApp.swift` | Create | `@main` App + `MenuBarExtra` placeholder |
| `AIStatusbar/Views/.gitkeep` | Create | Tracks empty group |
| `AIStatusbar/Services/.gitkeep` | Create | Tracks empty group |
| `AIStatusbar/Models/.gitkeep` | Create | Tracks empty group |
| `AIStatusbar/Providers/.gitkeep` | Create | Tracks empty group |
| `AIStatusbar/Resources/.gitkeep` | Create | Tracks empty group |

## Completion Criteria

- [ ] `xcodebuild -scheme AIStatusbar -configuration Debug build` exits 0 and writes a `Debug/AIStatusbar.app` artifact.
- [ ] Running `open Debug/AIStatusbar.app` shows a single `chart.bar.xaxis` icon in the menu bar within 2 seconds and no Dock icon.
- [ ] Clicking the icon opens a popover with the placeholder text "AI Statusbar".
- [ ] Info.plist contains `LSUIElement = YES` (verified via `plutil -p`).
- [ ] No third-party SwiftPM dependencies are referenced.
- [ ] All group folders exist and are tracked by git.

## Evidence

- [ ] Automated verification
  - Command(s): `xcodebuild -scheme AIStatusbar -configuration Debug build 2>&1 | tail -20`
  - Expected proof: `** BUILD SUCCEEDED **`, exit 0.
- [ ] Artifact / runtime verification
  - Inspect: `~/Library/Developer/Xcode/DerivedData/AIStatusbar-*/Build/Products/Debug/AIStatusbar.app/Contents/Info.plist`
  - Expect: `LSUIElement: YES`, `CFBundleShortVersionString: 0.1.0`.
- [ ] Runtime reachability verification
  - Entrypoint/caller: `open` of the built `.app`.
  - Expect: menu bar icon appears; popover opens on click.
- [ ] Contract / negative-path verification
  - Check: launch the app, then check `ps -ax | grep AIStatusbar` — no Dock entry, only a single process.
  - Expect: single process, no Dock icon (Dock stays empty for this app).

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| macOS < 13 on BOSS machine | Medium | Verify `sw_vers -productVersion` returns ≥ 13.0 before scaffolding; if not, BOSS can run software update or build target falls back. |
| xcodegen unavailable on host | Low | Fall back to writing `project.pbxproj` by hand using a minimal known-good template. |
| Code signing blocks local build | Low | Set `CODE_SIGNING_REQUIRED=NO` for Debug; ad-hoc for Release. |
