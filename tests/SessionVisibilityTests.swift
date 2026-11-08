import Foundation

@main
struct SessionVisibilityTests {
    static func main() {
        let socket = "/tmp/visibility.sock"
        let tmux = TmuxLocation(socketPath: "/tmp/tmux.sock", paneID: "%1")
        let surface = AgentLocation(process: ProcessIdentity(pid: 42, startedAt: "100.0"),
                                    applicationPID: 10, bundleID: TerminalIntegration.ghostty,
                                    tty: "/dev/ttys001", ghosttySurfaceID: "front")
        var terminalVisible = true
        var tmuxSelected = true
        var attached = true
        var herdrClient = surface
        var observedTTY: String?
        let visibility = SessionVisibility(
            herdrHost: { _ in attached ? herdrClient : nil },
            tmuxHost: { _ in attached ? surface : nil },
            tmuxSelected: { _ in tmuxSelected },
            observeHost: { agent in
                observedTTY = agent.location?.tty
                return terminalVisible && agent.location?.ghosttySurfaceID == "front"
            })
        let kinds = ["codex", "claude", "gemini", "opencode", "copilot", "other"]
        for kind in kinds {
            for host in ["terminal", "tmux", "herdr", "nested"] {
                var location = surface
                if host == "tmux" { location.tmux = tmux; location.tty = "/dev/inner" }
                if host == "herdr" || host == "nested" {
                    location.herdr = HerdrLocation(socketPath: socket, paneID: "pane")
                    location.tty = "/dev/inner"
                }
                herdrClient = surface
                if host == "nested" { herdrClient.tmux = tmux }
                func agent(_ state: AgentState) -> AgentInfo {
                    visibility.apply(AgentInfo(id: kind, name: kind, kind: kind, state: state,
                                               terminalID: "same-process", location: location))
                }
                func snapshot(_ state: AgentState, selected: Bool = true) -> [AgentInfo] {
                    let item = agent(state)
                    guard location.herdr != nil else { return [item] }
                    let pane = AgentInfo(id: "pane", name: kind, kind: kind, state: state,
                                         isFocused: selected)
                    let client = visibility.apply(AgentInfo(id: "host", name: "host", kind: "", state: .unknown,
                                                           location: herdrClient))
                    return SessionMerger.merge(system: [item], events: [],
                        herdr: [HerdrSnapshot(socketPath: socket, agents: [pane], host: attached ? client : nil)])
                }
                var activity = AgentActivity()
                activity.update(snapshot(.working), sessionVisible: true)
                activity.update(snapshot(.idle), sessionVisible: true)
                precondition(activity.completions.isEmpty, "\(kind) in \(host): visible completion is read")
                precondition(observedTTY == surface.tty, "Always inspect the outer frontend, not the inner PTY")

                terminalVisible = false
                activity.update(snapshot(.working), sessionVisible: true)
                activity.update(snapshot(.idle), sessionVisible: true)
                precondition(activity.results.count == 1, "\(kind) in \(host): background results remain unread")
                terminalVisible = true
                if location.herdr != nil {
                    activity.update(snapshot(.idle, selected: false), sessionVisible: true)
                    precondition(activity.results.count == 1, "An unselected Herdr pane remains unread")
                }
                if host == "tmux" || host == "nested" {
                    tmuxSelected = false
                    activity.update(snapshot(.idle), sessionVisible: true)
                    precondition(activity.results.count == 1, "An unselected outer tmux pane remains unread")
                    tmuxSelected = true
                }
                if host != "terminal" {
                    attached = false
                    activity.update(snapshot(.idle), sessionVisible: true)
                    precondition(activity.results.count == 1, "Detached multiplexers remain unread")
                    attached = true
                }
                activity.update(snapshot(.idle), sessionVisible: true)
                precondition(activity.completions.isEmpty, "Opening the exact result marks it read")
            }
        }

        // Pane-only providers and lifecycle events obey the same selection gate.
        let host = AgentInfo(id: "host", name: "host", kind: "", state: .unknown, isFocused: true, location: surface)
        let pane = AgentInfo(id: "pane", name: "claude", kind: "claude", state: .idle,
                             isFocused: true, location: AgentLocation(sessionID: "conversation"))
        let visible = SessionMerger.merge(system: [], events: [],
            herdr: [HerdrSnapshot(socketPath: socket, agents: [pane], host: host)])
        precondition(visible.first?.isFocused == true && visible.first?.location?.applicationPID == 10,
                     "Herdr panes without a discoverable agent still use their real visible client")
        let hiddenPane = AgentInfo(id: "pane", name: "claude", kind: "claude", state: .idle,
                                   location: AgentLocation(sessionID: "conversation"))
        let event = AgentInfo(id: "event", name: "claude", kind: "claude", state: .idle,
                              isFocused: true, location: AgentLocation(sessionID: "conversation"))
        let hidden = SessionMerger.merge(system: [], events: [event],
            herdr: [HerdrSnapshot(socketPath: socket, agents: [hiddenPane], host: host)])
        precondition(hidden.first?.isFocused == false, "Events cannot acknowledge an unselected Herdr pane")
        let unfocusedEvent = AgentInfo(id: "event", name: "claude", kind: "claude", state: .idle,
                                       location: AgentLocation(sessionID: "conversation"))
        let visibleEvent = SessionMerger.merge(system: [], events: [unfocusedEvent],
            herdr: [HerdrSnapshot(socketPath: socket, agents: [pane], host: host)])
        precondition(visibleEvent.first?.isFocused == true,
                     "A lifecycle event must preserve the exact visible conversation reported by Herdr")
        for kind in kinds {
            let event = visibility.apply(AgentInfo(id: kind, name: kind, kind: kind, state: .idle, location: surface))
            precondition(SessionMerger.merge(system: [], events: [event], herdr: []).first?.isFocused == true,
                         "Lifecycle visibility works for every agent kind")
        }
        var unseenLocation = surface
        unseenLocation.herdr = HerdrLocation(socketPath: socket, paneID: "unknown")
        let unseenPane = visibility.apply(AgentInfo(id: "unknown", name: "claude", kind: "claude", state: .idle,
                                                   location: unseenLocation))
        precondition(SessionMerger.merge(system: [unseenPane], events: [], herdr: []).first?.isFocused == false,
                     "An outer terminal cannot acknowledge Herdr before its pane selection is known")
        let shared = ["one", "two"].map { session -> AgentInfo in
            var location = surface
            location.sessionID = session
            return visibility.apply(AgentInfo(id: session, name: "claude", kind: "claude", state: .idle, location: location))
        }
        precondition(SessionMerger.merge(system: shared, events: [], herdr: []).allSatisfy { !$0.isFocused },
                     "One visible frontend cannot acknowledge several unidentified conversations")
        var outerHerdr = surface
        outerHerdr.herdr = HerdrLocation(socketPath: socket, paneID: "pane")
        var innerTmux = outerHerdr
        innerTmux.tmux = tmux
        let reverseNested = SessionVisibility(herdrHost: { _ in surface }, tmuxHost: { _ in outerHerdr },
            tmuxSelected: { _ in tmuxSelected }, observeHost: { $0.location?.tty == surface.tty })
        let nestedAgent = AgentInfo(id: "nested", name: "gemini", kind: "gemini", state: .idle, location: innerTmux)
        precondition(reverseNested.apply(nestedAgent).isFocused, "tmux inside Herdr resolves both layers")
        tmuxSelected = false
        precondition(!reverseNested.apply(nestedAgent).isFocused, "Herdr cannot bypass an unselected inner tmux pane")
        let nestedPane = AgentInfo(id: "pane", name: "gemini", kind: "gemini", state: .idle, isFocused: true)
        let nestedMerge = SessionMerger.merge(system: [reverseNested.apply(nestedAgent)], events: [],
            herdr: [HerdrSnapshot(socketPath: socket, agents: [nestedPane], host: host)])
        precondition(nestedMerge.first?.isFocused == false,
                     "Merging a visible Herdr host must retain the inner tmux selection check")

        // Real-world Codex /resume: two rollouts share one process, and Herdr
        // reports the current terminal title but no agent_session ID.
        func conversation(_ id: String, name: String, sequence: Int) -> AgentInfo {
            var location = surface
            location.workingDirectory = "/work/project"
            location.herdr = HerdrLocation(socketPath: socket, paneID: "codex-pane")
            location.sessionID = id
            location.sessionName = name
            return AgentInfo(id: id, name: "codex", kind: "codex", state: .idle,
                             completionSequence: sequence, terminalID: "same-tui", location: location)
        }
        func conversations(_ sequence: Int, duplicateName: Bool = false) -> [AgentInfo] {
            [conversation("old", name: duplicateName ? "Current" : "Previous", sequence: sequence),
             conversation("current", name: "Current", sequence: sequence)]
        }
        func codexSnapshot(_ sequence: Int, selected: Bool, duplicateName: Bool = false,
                           title: String = "⠙ Current | project") -> [AgentInfo] {
            let pane = AgentInfo(id: "codex-pane", name: "codex", kind: "codex", state: .idle,
                                 title: title, isFocused: selected)
            return SessionMerger.merge(system: conversations(sequence, duplicateName: duplicateName), events: [],
                herdr: [HerdrSnapshot(socketPath: socket, agents: [pane], host: host)])
        }
        var resumed = AgentActivity()
        resumed.update(codexSnapshot(0, selected: false), sessionVisible: true)
        resumed.update(codexSnapshot(1, selected: false), sessionVisible: true)
        precondition(resumed.results.count == 2)
        resumed.update(codexSnapshot(1, selected: true), sessionVisible: true)
        precondition(resumed.results.map(\.location?.sessionID) == ["old"],
                     "Manually opening the finished Codex conversation in Herdr acknowledges only its exact result")
        resumed.update(codexSnapshot(1, selected: false), sessionVisible: true)
        precondition(resumed.results.count == 1, "Leaving the tab must not replay the acknowledged completion")
        precondition(codexSnapshot(1, selected: true, duplicateName: true).allSatisfy { !$0.isFocused },
                     "Duplicate conversation names must remain ambiguous")
        for prefix in ["[ ! ] Action Required | ", "[ . ] Action Required | "] {
            let selected = codexSnapshot(1, selected: true, title: prefix + "Current | project").filter(\.isFocused)
            precondition(selected.map(\.location?.sessionID) == ["current"],
                         "Codex's attention title prefix must preserve exact conversation matching")
        }

        precondition(TerminalIntegration.ghosttyVisible("surface\u{1e}/dev/ttys001\u{1e}1", surfaceID: nil, tty: nil),
                     "A single Ghostty surface works without an exported surface ID")
        precondition(!TerminalIntegration.ghosttyVisible("surface\u{1e}/dev/ttys001\u{1e}2", surfaceID: nil, tty: nil),
                     "Multiple Ghostty surfaces must not be guessed")
        precondition(TerminalIntegration.ghosttyVisible("surface\u{1e}/dev/ttys001\u{1e}2",
                                                        surfaceID: "surface", tty: "/dev/ttys001"))
        precondition(!TerminalIntegration.ghosttyVisible("other\u{1e}/dev/ttys002\u{1e}2",
                                                         surfaceID: "surface", tty: "/dev/ttys001"))
        precondition(TerminalIntegration.ghosttyVisible("uuid\u{1e}/dev/ttys001\u{1e}2",
                                                        surfaceID: "0xhex", tty: "/dev/ttys001"),
                     "Ghostty's AppleScript UUID and hex surface ID identify the same open TTY")
        precondition(!TerminalIntegration.ghosttyVisible("uuid\u{1e}/dev/ttys002\u{1e}2",
                                                         surfaceID: "0xhex", tty: "/dev/ttys001"),
                     "A background Ghostty surface stays unread")
        precondition(!TerminalIntegration.ghosttyVisible("\u{1e}\u{1e}0", surfaceID: nil, tty: nil))

        // Ghostty 1.4 returns a UUID for the focused terminal while the process
        // environment carries a hex surface ID. The TTY must still acknowledge
        // a completed result when the exact surface is open.
        var ghosttyLocation = surface
        ghosttyLocation.ghosttySurfaceID = "0xhex"
        let ghosttyVisibility = SessionVisibility(
            herdrHost: { _ in nil }, tmuxHost: { _ in nil }, tmuxSelected: { _ in true },
            observeHost: { agent in
                guard let location = agent.location else { return false }
                return TerminalIntegration.ghosttyVisible("uuid\u{1e}/dev/ttys001\u{1e}2",
                                                          surfaceID: location.ghosttySurfaceID, tty: location.tty)
            })
        func ghosttyAgent(_ state: AgentState) -> AgentInfo {
            ghosttyVisibility.apply(AgentInfo(id: "codex", name: "codex", kind: "codex",
                                              state: state, location: ghosttyLocation))
        }
        var ghosttyActivity = AgentActivity()
        ghosttyActivity.update([ghosttyAgent(.working)], sessionVisible: true)
        ghosttyActivity.update([ghosttyAgent(.idle)], sessionVisible: true)
        precondition(ghosttyActivity.results.isEmpty,
                     "Opening the exact Ghostty TTY marks its completed result read")

        // The same conversation can be visible in one frontend while another
        // copy is unfocused (VS Code chat plus an idle TUI, or two Herdr panes).
        var editorSurface = surface
        editorSurface.sessionID = "shared"
        editorSurface.herdr = nil
        var tuiSurface = surface
        tuiSurface.sessionID = "shared"
        tuiSurface.applicationPID = 11
        tuiSurface.herdr = HerdrLocation(socketPath: socket, paneID: "shared-pane")
        let editorCopy = AgentInfo(id: "editor", name: "codex", kind: "codex", state: .idle,
                                   terminalID: "editor", isFocused: true, location: editorSurface)
        let tuiCopy = AgentInfo(id: "tui", name: "codex", kind: "codex", state: .idle,
                                terminalID: "tui", isFocused: false, location: tuiSurface)
        let copies = SessionMerger.merge(system: [editorCopy, tuiCopy], events: [], herdr: [])
        precondition(copies.count == 1 && copies[0].isFocused && copies[0].location?.applicationPID == 10,
                     "An unfocused duplicate must not hide or move a focused conversation")
        let idlePane = AgentInfo(id: "shared-pane", name: "codex", kind: "codex", state: .idle,
                                 isFocused: false, location: AgentLocation(sessionID: "shared"))
        let copiesWithPane = SessionMerger.merge(system: [editorCopy, tuiCopy], events: [],
            herdr: [HerdrSnapshot(socketPath: socket, agents: [idlePane], host: host)])
        precondition(copiesWithPane.count == 1 && copiesWithPane[0].isFocused,
                     "An unselected Herdr pane must not clear focus from another frontend")
        let eventCopy = AgentInfo(id: "event", name: "codex", kind: "codex", state: .idle,
                                  terminalID: "event", isFocused: false, location: AgentLocation(sessionID: "shared"))
        let copiesWithEvent = SessionMerger.merge(system: [editorCopy], events: [eventCopy], herdr: [])
        precondition(copiesWithEvent.count == 1 && copiesWithEvent[0].isFocused,
                     "An unfocused lifecycle copy must not hide a focused conversation")
        print("PASS: all agent kinds, terminal/tmux/Herdr/nested visibility, background results, detached clients, lifecycle events and duplicate representations")
    }
}
