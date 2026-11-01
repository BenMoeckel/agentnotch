import Foundation

@main
struct DiscoveryTests {
    static func process(_ pid: Int32, parent: Int32 = 1, executable: String = "zsh", args: [String]? = nil,
                        tty: String? = "/dev/ttys001", env: [String: String] = [:], start: String = "100.0") -> SystemProcess {
        SystemProcess(identity: ProcessIdentity(pid: pid, startedAt: start), parentPID: parent, executable: executable,
                      arguments: args ?? [executable], environment: env, tty: tty, workingDirectory: "/work/project")
    }

    static func main() throws {
        precondition(AgentCatalog.kind(executable: "/opt/bin/codex", arguments: ["codex", "hello"]) == "codex")
        precondition(AgentCatalog.kind(executable: "/usr/bin/node", arguments: ["node", "--no-warnings", "/node_modules/@anthropic-ai/claude-code/cli.js"]) == "claude")
        precondition(AgentCatalog.kind(executable: "node", arguments: ["node", "server.js", "codex"]) == nil)
        precondition(AgentCatalog.kind(executable: "sh", arguments: ["sh", "-c", "codex"]) == nil)
        precondition(AgentCatalog.kind(executable: "node", arguments: ["node", "-e", "require('codex')"]) == nil)
        precondition(AgentCatalog.kind(executable: "node", arguments: ["node", "/tmp/claude-code-not-an-agent/cli.js"]) == nil)

        var argc: Int32 = 3
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/bin/node\0\0node\0/path/codex.js\0\0HERDR_PANE_ID=w1:p1\0SECRET=never-retain\0TMUX=/tmp/a,b,7,0\0\0".utf8)
        let command = ProcessDiscovery.parseCommand(bytes)!
        precondition(command.1 == ["node", "/path/codex.js", ""], "Empty argv entries must not eat environment data")
        precondition(command.2 == ["HERDR_PANE_ID": "w1:p1", "TMUX": "/tmp/a,b,7,0"])
        precondition(ProcessDiscovery.parseCommand([0, 0]) == nil)

        let host = HostApplication(pid: 10, bundleID: "com.apple.Terminal")
        let processes = [process(10, executable: "Terminal", tty: nil), process(11, parent: 10, executable: "login"),
                         process(12, parent: 11, env: ["HERDR_PANE_ID": "w1:p1", "HERDR_SOCKET_PATH": "/tmp/a.sock"]),
                         process(13, parent: 12, executable: "node", args: ["node", "/node_modules/@openai/codex/bin/codex.js"]),
                         process(14, parent: 13, executable: "codex"),
                         process(15, parent: 12, executable: "claude", tty: "/dev/ttys002")]
        let agents = ProcessDiscovery.agents(in: processes, applications: [host])
        precondition(agents.count == 2, "Collapse launcher/native duplicate, preserve independent agents")
        let codex = agents.first { $0.kind == "codex" }!
        precondition(codex.location?.applicationPID == 10, "Walk through login to the actual GUI host")
        precondition(codex.location?.tty == "/dev/ttys001")
        precondition(codex.location?.herdr == HerdrLocation(socketPath: "/tmp/a.sock", paneID: "w1:p1"))
        let reused = ProcessDiscovery.agents(in: [process(13, executable: "codex", start: "200.0")], applications: [])
        precondition(reused[0].id != codex.id, "PID reuse must not navigate to a different session")
        let appServer = process(16, executable: "codex",
                                args: ["codex", "app-server", "--listen", "unix:///tmp/codex.sock"],
                                tty: "/dev/ttys004",
                                env: ["HERDR_PANE_ID": "w1:p9", "HERDR_SOCKET_PATH": "/tmp/a.sock",
                                      "TMUX": "/tmp/tmux,1,0", "TMUX_PANE": "%1",
                                      "GHOSTTY_SURFACE_ID": "surface"])
        let appServerAgent = ProcessDiscovery.agents(in: [appServer], applications: []).first!
        precondition(appServerAgent.location?.tty == nil && appServerAgent.location?.herdr == nil &&
                     appServerAgent.location?.tmux == nil && appServerAgent.location?.ghosttySurfaceID == nil,
                     "A shared Codex app server must not inherit its launcher's terminal target")
        let nestedAgents = [process(50, executable: "codex", tty: nil), process(51, parent: 50, tty: nil),
                            process(52, parent: 51, executable: "codex", tty: nil)]
        precondition(ProcessDiscovery.agents(in: nestedAgents, applications: []).count == 2,
                     "Independent agents launched by another agent are not launcher duplicates")
        let cycle = [process(20, parent: 21), process(21, parent: 20)]
        precondition(ProcessDiscovery.ancestry(of: 20, in: Dictionary(uniqueKeysWithValues: cycle.map { ($0.identity.pid, $0) })).count == 2)
        let tmux = ProcessDiscovery.agents(in: [process(30, executable: "claude", env: ["TMUX": "/tmp/a,b,7,0", "TMUX_PANE": "%2"])], applications: [])
        precondition(tmux[0].location?.tmux?.socketPath == "/tmp/a,b")

        let editor = HostApplication(pid: 40, bundleID: "com.microsoft.VSCode")
        let extensionProcesses = [process(40, executable: "Electron", tty: nil),
                                  process(41, parent: 40, executable: "Code Helper (Plugin)", tty: nil),
                                  process(42, parent: 41, executable: "codex", tty: nil)]
        let extensionAgents = ProcessDiscovery.agents(in: extensionProcesses, applications: [editor])
        precondition(extensionAgents.count == 1 && extensionAgents[0].location?.applicationPID == 40)
        precondition(extensionAgents[0].location?.tty == nil)
        var editorActivity = AgentActivity()
        editorActivity.update(extensionAgents)
        precondition(editorActivity.active.isEmpty && editorActivity.results.isEmpty,
                     "An extension backend process is not an active conversation")
        let launchedEditor = [process(40, parent: 12, executable: "Electron", tty: nil),
                              process(42, parent: 40, executable: "codex", tty: nil,
                                      env: ["HERDR_PANE_ID": "w1:p1", "TMUX": "/tmp/tmux,1,0", "TMUX_PANE": "%1"])]
        let editorSession = ProcessDiscovery.agents(in: Array(processes.prefix(3)) + launchedEditor, applications: [host, editor]).first!
        precondition(editorSession.location?.applicationPID == 40 && editorSession.location?.tty == nil)
        precondition(editorSession.location?.herdr == nil && editorSession.location?.tmux == nil,
                     "An editor launched from a multiplexer owns its own agent sessions")

        let working = AgentInfo(id: codex.id, name: "codex", kind: "codex", state: .working,
                                terminalID: codex.terminalID, isFocused: true, location: codex.location)
        let pane = AgentInfo(id: "w1:p1", name: "reviewer", kind: "codex", state: .idle,
                             completionSequence: 1, terminalID: "terminal-a", isFocused: true)
        let merged = SessionMerger.merge(system: [working], events: [], herdr: [HerdrSnapshot(socketPath: "/tmp/a.sock", agents: [pane])])
        precondition(merged.count == 1 && merged[0].id == working.id && merged[0].state == .idle)
        precondition(merged[0].isFocused, "Focus combines the pane flag with its actual host visibility")
        let background = SessionMerger.merge(system: [codex], events: [], herdr: [HerdrSnapshot(socketPath: "/tmp/a.sock", agents: [pane])])
        precondition(!background[0].isFocused)
        let twoServers = SessionMerger.merge(system: [], events: [], herdr: [HerdrSnapshot(socketPath: "/tmp/a.sock", agents: [pane]), HerdrSnapshot(socketPath: "/tmp/b.sock", agents: [pane])])
        precondition(Set(twoServers.map(\.id)).count == 2, "Pane IDs from different servers must not collide")
        var activity = AgentActivity()
        activity.update([working])
        activity.update(merged)
        precondition(activity.results.count == 1, "Provider enrichment keeps completion identity stable")
        activity.update([codex])
        precondition(activity.results.count == 1, "Losing status data cannot erase unread results")

        var nativeLocation = codex.location!
        nativeLocation.sessionID = "same-conversation"
        let native = AgentInfo(id: "native-copy", name: "codex", kind: "codex", state: .working,
                               completionSequence: 2, completionSource: "native:codex",
                               terminalID: codex.terminalID, location: nativeLocation)
        var backendLocation = nativeLocation
        backendLocation.tty = nil
        let backend = AgentInfo(id: "backend-copy", name: "codex", kind: "codex", state: .working,
                                terminalID: "backend", location: backendLocation)
        let nativePane = AgentInfo(id: "w1:p1", name: "codex", kind: "codex", state: .done,
                                   completionSequence: 90, location: AgentLocation(sessionID: "same-conversation"))
        let copies = SessionMerger.merge(system: [native, backend], events: [],
                                        herdr: [HerdrSnapshot(socketPath: "/tmp/a.sock", agents: [nativePane])])
        precondition(copies.count == 1 && copies[0].state == .working && copies[0].terminalID == codex.terminalID,
                     "Frontend, shared backend and pane must produce one conversation with native state")
        precondition(copies[0].completionSequence == 2 && copies[0].completionSource == "native:codex")
        let blockedPane = AgentInfo(id: "w1:p1", name: "codex", kind: "codex", state: .blocked,
                                    completionSequence: 90, location: AgentLocation(sessionID: "same-conversation"))
        let blockedCopies = SessionMerger.merge(system: [native, backend], events: [],
                                                herdr: [HerdrSnapshot(socketPath: "/tmp/a.sock", agents: [blockedPane])])
        precondition(blockedCopies.count == 1 && blockedCopies[0].state == .blocked,
                     "A live approval request must override a native turn that is still in progress")
        precondition(blockedCopies[0].completionSequence == 2 && blockedCopies[0].completionSource == "native:codex",
                     "Blocked pane state must not replace native completion identity")
        let processAndPane = SessionMerger.merge(system: [working], events: [],
                                                 herdr: [HerdrSnapshot(socketPath: "/tmp/a.sock", agents: [nativePane])])
        precondition(processAndPane.count == 1 && processAndPane[0].id == copies[0].id,
                     "Pane session identity must survive enrichment of a bare process")
        let paneOnly = SessionMerger.merge(system: [], events: [],
                                          herdr: [HerdrSnapshot(socketPath: "/tmp/a.sock", agents: [nativePane])])
        precondition(paneOnly[0].id == copies[0].id, "Conversation identity must survive provider arrival and disappearance")
        let explicit = AgentInfo(id: "event-copy", name: "codex", kind: "codex", state: .idle,
                                 completionSequence: 3, title: "Explicit title", location: nativeLocation)
        let eventCopies = SessionMerger.merge(system: [native, backend], events: [explicit],
                                             herdr: [HerdrSnapshot(socketPath: "/tmp/a.sock", agents: [nativePane])])
        precondition(eventCopies.count == 1 && eventCopies[0].title == "Explicit title",
                     "Explicit events override matching native and pane copies")
        var otherLocation = nativeLocation
        otherLocation.sessionID = "different-conversation"
        let other = AgentInfo(id: "other", name: "codex", kind: "codex", state: .working, location: otherLocation)
        let independent = SessionMerger.merge(system: [native, other], events: [],
                                             herdr: [HerdrSnapshot(socketPath: "/tmp/a.sock", agents: [pane])])
        precondition(independent.count == 2, "Ambiguous pane status must not add a third agent or collapse separate conversations")

        let location = AgentLocation(workingDirectory: "/work/project")
        precondition(SessionNavigator.matchingWindow(titles: ["other — Code", "file.swift — project — Code"], location: location) == 1)
        precondition(SessionNavigator.matchingWindow(titles: ["project — Code", "project — Code"], location: location) == nil)
        precondition(SessionNavigator.matchingWindow(titles: ["myproject — Code", "project-copy — Code"], location: location) == nil)
        precondition(SessionNavigator.matchingWindow(titles: ["one", "two"], location: AgentLocation(windowTitle: "two")) == 1)
        precondition(SessionNavigator.matchingWindow(titles: ["one"], location: AgentLocation(tty: "/dev/ttys003")) == nil)
        precondition(LocalCommand.appleScriptLiteral("a\"\\b\nc") == "\"a\\\"\\\\b\\nc\"")

        precondition(TerminalState.detect("context left\nWorking (esc to interrupt)", kind: "codex") == .working)
        precondition(TerminalState.detect("Would you like to run the following command?\nEnter to confirm · esc to cancel", kind: "codex") == .blocked)
        precondition(TerminalState.detect("Response complete\n92% context left", kind: "codex") == .idle)
        precondition(TerminalState.detect("arbitrary output", kind: "claude") == .unknown)
        precondition(TerminalState.detect("❯ quoted text in output", kind: "claude") == .unknown)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload: [String: Any] = ["pid": 41, "kind": "copilot", "state": "blocked", "session": "conversation-1",
                                      "updatedAt": 150, "windowTitle": "project — Code", "sequence": 3]
        try JSONSerialization.data(withJSONObject: payload).write(to: directory.appendingPathComponent("event.json"))
        let events = AgentEventStore.read(processes: extensionProcesses, applications: [editor], now: Date(timeIntervalSince1970: 151), directory: directory)
        precondition(events.count == 1 && events[0].state == .blocked && events[0].location?.applicationPID == 40)
        precondition(events[0].location?.windowTitle == "project — Code")
        editorActivity.update(SessionMerger.merge(system: extensionAgents, events: events, herdr: []))
        precondition(editorActivity.active.map { $0.location?.sessionID } == events.map { $0.location?.sessionID },
                     "Only the conversation with a lifecycle signal is active, never its unknown backend")
        editorActivity.update(SessionMerger.merge(system: extensionAgents, events: [], herdr: []))
        precondition(editorActivity.active.isEmpty && editorActivity.results.isEmpty,
                     "An expired or missing lifecycle signal must not leave a phantom active agent")
        let event = try JSONDecoder().decode(AgentEvent.self, from: JSONSerialization.data(withJSONObject: payload))
        precondition(!event.applies(to: ProcessIdentity(pid: 41, startedAt: "160.0"), now: Date(timeIntervalSince1970: 161)))
        precondition(!event.applies(to: ProcessIdentity(pid: 41, startedAt: "100.0"), now: Date(timeIntervalSince1970: 86_550)))
        precondition(!event.applies(to: ProcessIdentity(pid: 41, startedAt: "100.0"), now: Date(timeIntervalSince1970: 120)))
        let result = LocalCommand.run("/bin/echo", ["literal $(not-a-command) `no-shell`"])
        precondition(result.succeeded && result.output == "literal $(not-a-command) `no-shell`")
        let start = Date()
        precondition(!LocalCommand.run("/bin/sleep", ["5"], timeout: 0.1).succeeded)
        precondition(Date().timeIntervalSince(start) < 2)
        print("PASS: process discovery, wrappers, PID reuse, host ancestry, VS Code extensions, provider merging, exact window matching, status markers, lifecycle events and command timeout")
    }
}
