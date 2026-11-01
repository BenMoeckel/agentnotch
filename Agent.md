# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build
xcodebuild -project AgentNotch.xcodeproj -scheme AgentNotch -configuration Debug -destination 'platform=macOS' build

# Run (after build)
open ~/Library/Developer/Xcode/DerivedData/AgentNotch-*/Build/Products/Debug/AgentNotch.app

# Regenerate project.pbxproj (after adding/removing Swift files)
python3 gen_pbxproj.py
```

## Tests

Tests are Swift `@main` executables with `precondition`-based assertions — no test framework.

```bash
# Run a test file directly via swift (example)
swift tests/ActivityTests.swift

# Or build & run via Xcode
xcodebuild -project AgentNotch.xcodeproj -scheme AgentNotch test
```

## Architecture

**macOS menu bar / notch overlay** — runs as `.accessory` (no Dock icon), overlays the physical notch area.

### Data flow

```
ProcessDiscovery (sysctl) ──┐
AgentEventStore (JSON files)─┤
                             ├─ AgentClient (merge + poll every 1s)
HerdrProvider (Unix socket) ─┘   └─ AgentActivity (completion tracking)
                                       └─ NotchBarView (SwiftUI, @EnvironmentObject)
                                            └─ NotchPanel (NSPanel, above menu bar)
```

### Key files

| File | Role |
|---|---|
| `Agents/AgentModel.swift` | `AgentInfo`, `AgentState`, `AgentActivity` — all domain logic |
| `Agents/AgentClient.swift` | `AgentClient` (ObservableObject) — orchestrates all sources, merges via `SessionMerger`, owns `HerdrProvider` instances per socket |
| `Agents/ProcessDiscovery.swift` | sysctl process scan; `AgentCatalog` maps executables/packages to agent kinds; `needsArguments` skips KERN_PROCARGS2 for unrecognised processes |
| `Agents/AgentEventStore.swift` | Reads JSON event files from `~/Library/Application Support/AgentNotch/events/` for agents/extensions that can't be screen-scraped |
| `Agents/SessionNavigator.swift` | `focus()` — resolves a location to an on-screen window via AX API, AppleScript, or tmux selection |
| `Integrations/HerdrProvider.swift` | Unix socket RPC to one Herdr daemon instance (`agent.list`, `agent.focus`); multiple instances can run simultaneously |
| `Integrations/TerminalIntegration.swift` | Screen-scrapes Terminal.app / iTerm2 / Ghostty via AppleScript to infer `AgentState` |
| `Integrations/TmuxIntegration.swift` | Reads tmux pane content and resolves the attached client terminal |
| `Integrations/LocalCommand.swift` | Bounded subprocess runner used by terminal integrations |
| `Window/NotchDetector.swift` | Computes notch geometry from `NSScreen.auxiliaryTopLeftArea/Right` |
| `Window/NotchPanel.swift` | `NSPanel` subclass; lives above the menu bar, never becomes key/main |
| `Window/NotchSpaceManager.swift` | Keeps the panel on all Spaces via private CGS API |
| `Views/NotchBarView.swift` | Compact (icon row) ↔ expanded (two-column list) toggle on 1s hover delay |

### Agent detection — three sources, merged

1. **`ProcessDiscovery`** — sysctl scan every second; `AgentCatalog.needsArguments` gates expensive KERN_PROCARGS2 reads to shells, interpreters, and known agents only.
2. **`AgentEventStore`** — JSON drop files for IDE extensions and other hosts that can't be process-inspected. Files must be ≤16 KB, timestamp must postdate the process start, and expire after 24h.
3. **`HerdrProvider`** — one instance per unique socket path. Provides exact pane state (`working`/`blocked`/`idle`/`done`) that overrides the screen-scraped `unknown` state. `SessionMerger.merge()` matches Herdr panes to discovered processes by `HerdrLocation`.

### Completion tracking

`AgentActivity.update()` fires a completion when `completion_seq` advances or when an agent transitions `working → idle/done` (fallback without sequence numbers). Results expire after 24h. Acknowledgement requires a matching `UUID` token to prevent stale acks clearing newer results.

### Session focus / navigation

`AgentClient.focus()` dispatches to `SessionNavigator.focus()` on a dedicated queue. It resolves tmux pane → attached client terminal, then raises the correct window via AX API (prefers `windowTitle` match, falls back to `workingDirectory`-based title heuristic). Requires Accessibility permission; degrades gracefully by activating the app without selecting a specific window.

### Window placement

`NotchDetector.geometry()` selects the built-in camera display independently of focus, falling back to the primary external display in clamshell mode. `NotchPlacement` shares the current geometry with SwiftUI. `AppDelegate` refreshes it on display changes, wake and Space changes, with a delayed recheck after transitions. `NotchPanel` retains the current anchor and requested size, repairs system-driven moves/resizes, and bypasses AppKit's `constrainFrameRect` to avoid menu-bar drift.
