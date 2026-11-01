import Foundation

@main
struct RoutingTests {
    static func process(_ pid: Int32, parent: Int32 = 1, executable: String = "zsh", tty: String? = nil,
                        environment: [String: String] = [:]) -> SystemProcess {
        SystemProcess(identity: ProcessIdentity(pid: pid, startedAt: "100.0"), parentPID: parent,
                      executable: executable, arguments: [executable], environment: environment, tty: tty, workingDirectory: "/same/project")
    }
    static func main() {
        let app = HostApplication(pid: 10, bundleID: "com.microsoft.VSCode")
        let processes = [process(10), process(11, parent: 10), process(12, parent: 10),
                         process(20, parent: 10), process(21, parent: 10), process(30, parent: 20, executable: "codex"),
                         process(31, parent: 21, executable: "opencode"), process(32, parent: 11, executable: "codex")]
        let first = EditorSnapshot(target: EditorTarget(socketPath: "/tmp/one.sock", host: processes[1].identity),
                                   application: app, terminals: [(20, "same project", true)])
        let second = EditorSnapshot(target: EditorTarget(socketPath: "/tmp/two.sock", host: processes[2].identity),
                                    application: app, terminals: [(21, "same project", false)])
        let agents = ProcessDiscovery.agents(in: processes, applications: [app])
        let routed = agents.map { EditorBridge.route($0, snapshots: [first, second], processes: processes) }
        precondition(routed.first { $0.location?.process?.pid == 30 }?.location?.editor?.terminalPID == 20)
        precondition(routed.first { $0.location?.process?.pid == 31 }?.location?.editor?.socketPath == "/tmp/two.sock")
        precondition(routed.first { $0.location?.process?.pid == 32 }?.location?.editor?.host == first.target.host,
                     "Extension conversations route through their owning extension host")
        precondition(routed.first { $0.location?.process?.pid == 30 }?.isFocused == true)
        precondition(routed.first { $0.location?.process?.pid == 31 }?.isFocused == false)

        var selected = first
        selected.focusedCodexSessionID = "visible-conversation"
        func conversation(_ id: String?, kind: String = "codex", state: AgentState) -> AgentInfo {
            AgentInfo(id: id ?? "backend", name: kind, kind: kind, state: state, terminalID: "backend",
                      location: AgentLocation(process: processes[7].identity, sessionID: id))
        }
        func routeConversation(_ agent: AgentInfo) -> AgentInfo {
            EditorBridge.route(agent, snapshots: [selected, second], processes: processes)
        }
        var activity = AgentActivity()
        activity.update(["visible-conversation", "other-conversation"].map {
            routeConversation(conversation($0, state: .working))
        }, sessionVisible: true)
        activity.update(["visible-conversation", "other-conversation"].map {
            routeConversation(conversation($0, state: .idle))
        }, sessionVisible: true)
        precondition(activity.results.map(\.id) == ["other-conversation"],
                     "Completing the already visible conversation clears only its own result")
        precondition(!routeConversation(conversation(nil, state: .idle)).isFocused,
                     "A shared backend without a conversation identity cannot be read")
        precondition(!routeConversation(conversation("visible-conversation", kind: "claude", state: .idle)).isFocused,
                     "Session IDs must match the agent kind as well")
        selected.focusedCodexSessionID = nil
        precondition(!routeConversation(conversation("visible-conversation", state: .idle)).isFocused,
                     "Older bridges and background windows do not acknowledge conversations")

        let socket = "/tmp/test-herdr.sock"
        let terminalApp = HostApplication(pid: 50, bundleID: TerminalIntegration.ghostty)
        let clients = [process(50, executable: "ghostty"), process(51, parent: 50, tty: "/dev/ttys001"),
                       process(52, parent: 51, executable: "herdr", tty: "/dev/ttys001", environment: ["HERDR_SOCKET_PATH": socket]),
                       process(53, executable: "herdr")]
        let host = HerdrProvider.clientLocation(socketPath: socket, processes: clients, applications: [terminalApp])
        precondition(host?.applicationPID == 50 && host?.process?.pid == 52,
                     "A detached daemon must route to its attached terminal client")
        precondition(HerdrProvider.clientLocation(socketPath: "/tmp/other.sock", processes: clients, applications: [terminalApp]) == nil)
        let duplicate = process(54, parent: 51, executable: "herdr", tty: "/dev/ttys002", environment: ["HERDR_SOCKET_PATH": socket])
        precondition(HerdrProvider.clientLocation(socketPath: socket, processes: clients + [duplicate], applications: [terminalApp]) == nil)

        let location = AgentLocation(process: processes[5].identity, herdr: HerdrLocation(socketPath: socket, paneID: "w1:p1"), sessionID: "conversation")
        let native = AgentInfo(id: "native", name: "codex", kind: "codex", state: .working, completionSequence: 4, location: location)
        let pane = AgentInfo(id: "w1:p1", name: "codex", kind: "codex", state: .idle)
        let merged = SessionMerger.merge(system: [native], events: [], herdr: [HerdrSnapshot(socketPath: socket, agents: [pane])])
        precondition(merged.count == 1 && merged[0].state == .working && merged[0].completionSequence == 4,
                     "Native lifecycle state must not be erased by a stale screen observation")

        precondition(PermissionSettings.Pane.accessibility.url.absoluteString.hasPrefix("x-apple.systempreferences:"))
        precondition(PermissionSettings.Pane.accessibility.url.absoluteString.hasSuffix("?Privacy_Accessibility"))
        precondition(PermissionSettings.Pane.automation.url.absoluteString.hasSuffix("?Privacy_Automation"))

        print("PASS: exact editor terminal/conversation routing, identical projects, detached Herdr client selection, native-state merging and permission settings links")
    }
}
