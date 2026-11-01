import Foundation
import SQLite3

@main
struct NativeSessionTests {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rolloutDirectory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let rollout = rolloutDirectory.appendingPathComponent("rollout.jsonl")
        let metadata = Data("{\"type\":\"session_meta\"}\n".utf8)
        try (metadata + Data(repeating: 120, count: 2_097_152)).write(to: rollout)
        let handle = try FileHandle(forReadingFrom: rollout)
        defer { try? handle.close() }
        precondition(NativeSessionIntegration.rolloutPaths(pid: ProcessInfo.processInfo.processIdentifier).contains(rollout.path),
                     "Direct descriptor discovery must find an open rollout")
        precondition(NativeSessionIntegration.firstLine(handle) == metadata.dropLast())
        let offset = try handle.offset()
        precondition(offset == 4096, "A large rollout must not be read just to obtain its header")
        try handle.close()
        precondition(!NativeSessionIntegration.rolloutPaths(pid: ProcessInfo.processInfo.processIdentifier).contains(rollout.path),
                     "Closed rollouts must disappear from descriptor discovery")
        let longHeader = Data(repeating: 120, count: 9000)
        try (longHeader + Data([10]) + Data("tail".utf8)).write(to: rollout)
        let longFile = try FileHandle(forReadingFrom: rollout)
        defer { try? longFile.close() }
        precondition(NativeSessionIntegration.firstLine(longFile) == longHeader,
                     "Headers spanning multiple read blocks must remain supported")
        // The same TUI rollout can be open through several backend records.
        // Both records route to one frontend and must append only one session.
        let sharedRollout = rolloutDirectory.appendingPathComponent("shared.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"shared-thread","cwd":"/work/project","originator":"codex-tui"}}
        {"type":"event_msg","payload":{"type":"task_started"}}

        """.utf8).write(to: sharedRollout)
        let sharedHandle = try FileHandle(forReadingFrom: sharedRollout)
        defer { try? sharedHandle.close() }
        let serverIdentity = ProcessDiscovery.identity(pid: ProcessInfo.processInfo.processIdentifier)!
        let frontendIdentity = ProcessIdentity(pid: 999_999, startedAt: "100.0")
        let frontend = AgentInfo(id: frontendIdentity.id, name: "codex", kind: "codex", state: .unknown,
                                 location: AgentLocation(process: frontendIdentity, tty: "/dev/ttys002", workingDirectory: "/work/project"))
        let servers = ["server-one", "server-two"].map {
            AgentInfo(id: $0, name: "codex", kind: "codex", state: .unknown,
                      location: AgentLocation(process: serverIdentity))
        }
        let frontendProcess = SystemProcess(identity: frontendIdentity, parentPID: 1, executable: "codex",
                                            arguments: ["codex"], environment: [:], tty: "/dev/ttys002", workingDirectory: "/work/project")
        let shared = NativeSessionIntegration(home: root).enrich(servers + [frontend], processes: [frontendProcess])
        precondition(shared.filter { $0.location?.sessionID == "shared-thread" }.count == 1,
                     "Repeated backend descriptors must not duplicate the routed frontend conversation")
        try sharedHandle.close()

        // Two Codex TUIs in one project share a managed app server. Their pane
        // titles must select the exact frontend instead of leaving a daemon row.
        let codexHome = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        var threadDB: OpaquePointer?
        precondition(sqlite3_open(codexHome.appendingPathComponent("thread_history_1.sqlite").path, &threadDB) == SQLITE_OK)
        func threadExec(_ sql: String) { precondition(sqlite3_exec(threadDB, sql, nil, nil, nil) == SQLITE_OK) }
        threadExec("CREATE TABLE thread_turns (thread_id TEXT, status TEXT, rollout_ordinal INTEGER)")
        threadExec("INSERT INTO thread_turns VALUES ('thread-a', 'inProgress', 1), ('thread-b', 'completed', 1)")
        sqlite3_close(threadDB)
        var stateDB: OpaquePointer?
        precondition(sqlite3_open(codexHome.appendingPathComponent("state_5.sqlite").path, &stateDB) == SQLITE_OK)
        func stateExec(_ sql: String) { precondition(sqlite3_exec(stateDB, sql, nil, nil, nil) == SQLITE_OK) }
        stateExec("CREATE TABLE threads (id TEXT, name TEXT)")
        stateExec("INSERT INTO threads VALUES ('thread-a', 'Thread A'), ('thread-b', 'Thread B')")
        sqlite3_close(stateDB)
        let rolloutA = rolloutDirectory.appendingPathComponent("thread-a.jsonl")
        let rolloutB = rolloutDirectory.appendingPathComponent("thread-b.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"thread-a","cwd":"/work/project","originator":"codex-tui"}}
        {"type":"event_msg","payload":{"type":"task_started"}}

        """.utf8).write(to: rolloutA)
        try Data("""
        {"type":"session_meta","payload":{"id":"thread-b","cwd":"/work/project","originator":"codex-tui"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}

        """.utf8).write(to: rolloutB)
        let handleA = try FileHandle(forReadingFrom: rolloutA)
        let handleB = try FileHandle(forReadingFrom: rolloutB)
        defer { try? handleA.close(); try? handleB.close() }
        let frontendAIdentity = ProcessIdentity(pid: 999_998, startedAt: "100.0")
        let frontendBIdentity = ProcessIdentity(pid: 999_997, startedAt: "100.0")
        let herdrTargetA = HerdrLocation(socketPath: "/tmp/native.sock", paneID: "pane-a")
        let herdrTargetB = HerdrLocation(socketPath: "/tmp/native.sock", paneID: "pane-b")
        let frontendA = AgentInfo(id: frontendAIdentity.id, name: "codex", kind: "codex", state: .unknown,
                                  location: AgentLocation(process: frontendAIdentity, tty: "/dev/ttys010",
                                                          workingDirectory: "/work/project", herdr: herdrTargetA))
        let frontendB = AgentInfo(id: frontendBIdentity.id, name: "codex", kind: "codex", state: .unknown,
                                  location: AgentLocation(process: frontendBIdentity, tty: "/dev/ttys011",
                                                          workingDirectory: "/work/project", herdr: herdrTargetB))
        let sharedServer = AgentInfo(id: "shared-server", name: "codex", kind: "codex", state: .unknown,
                                     location: AgentLocation(process: serverIdentity))
        let frontendAProcess = SystemProcess(identity: frontendAIdentity, parentPID: 1, executable: "codex",
                                             arguments: ["codex"], environment: [:], tty: "/dev/ttys010",
                                             workingDirectory: "/work/project")
        let frontendBProcess = SystemProcess(identity: frontendBIdentity, parentPID: 1, executable: "codex",
                                             arguments: ["codex"], environment: [:], tty: "/dev/ttys011",
                                             workingDirectory: "/work/project")
        let paneA = AgentInfo(id: "pane-a", name: "codex", kind: "codex", state: .idle,
                              title: "⠹ Thread A | project")
        let paneB = AgentInfo(id: "pane-b", name: "codex", kind: "codex", state: .idle,
                              title: "Thread B | project")
        let routed = NativeSessionIntegration(home: root).enrich(
            [sharedServer, frontendA, frontendB],
            processes: [frontendAProcess, frontendBProcess],
            herdr: [HerdrSnapshot(socketPath: "/tmp/native.sock", agents: [paneA, paneB])])
        precondition(routed.first { $0.location?.sessionID == "thread-a" }?.location?.herdr == herdrTargetA,
                     "The first Codex conversation must route to its matching pane")
        precondition(routed.first { $0.location?.sessionID == "thread-b" }?.location?.herdr == herdrTargetB,
                     "The second Codex conversation must route to its matching pane")
        precondition(!routed.contains { $0.id.hasPrefix("shared-server:session") },
                     "A shared app server must not keep duplicate conversation rows")

        let identity = ProcessIdentity(pid: 42, startedAt: "100.123")
        var descriptor: [String: Any] = ["pid": 42, "sessionId": "conversation", "startedAt": 100_500,
                                         "status": "busy", "cwd": "/work/project"]
        precondition(SessionMetadata.claude(descriptor, process: identity)?.state == .working)
        descriptor["status"] = "idle"
        precondition(SessionMetadata.claude(descriptor, process: identity)?.state == .idle)
        descriptor["status"] = "waiting_for_permission"
        precondition(SessionMetadata.claude(descriptor, process: identity)?.state == .blocked)
        precondition(SessionMetadata.claude(descriptor, process: ProcessIdentity(pid: 42, startedAt: "200.0")) == nil,
                     "A reused PID must reject the previous conversation")
        descriptor["status"] = "new-unsupported-state"
        precondition(SessionMetadata.claude(descriptor, process: identity)?.state == .unknown)
        descriptor["status"] = "busy"
        let records = root.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: descriptor).write(to: records.appendingPathComponent("42.json"))
        let nativeProcess = SystemProcess(identity: identity, parentPID: 1,
                                          executable: "/Users/user/.local/share/claude/versions/2.1.278", arguments: [],
                                          environment: [:], tty: "/dev/ttys001", workingDirectory: "/work/project")
        let discovered = ProcessDiscovery.agents(in: [nativeProcess], applications: [])
        let enriched = NativeSessionIntegration(home: root).enrich(discovered, processes: [nativeProcess])
        precondition(enriched.count == 1 && enriched[0].state == .working && enriched[0].location?.sessionID == "conversation",
                     "Native installations must move from process discovery to a confirmed active session")
        let blockedObservation = AgentInfo(id: discovered[0].id, name: "claude", kind: "claude", state: .blocked,
                                           terminalID: discovered[0].terminalID, location: discovered[0].location)
        let blockedEnriched = NativeSessionIntegration(home: root).enrich([blockedObservation], processes: [nativeProcess])
        precondition(blockedEnriched.count == 1 && blockedEnriched[0].state == .blocked,
                     "A visible approval prompt must override a native status that still reports work")
        precondition(AgentCatalog.kind(executable: "/Users/user/.local/share/claude/versions/2.1.278", arguments: []) == "claude")
        precondition(AgentCatalog.needsArguments("/Users/user/.local/share/claude/versions/2.1.278"))
        precondition(AgentCatalog.kind(executable: "/tmp/versions/2.1.278", arguments: []) == nil)

        let dbFile = root.appendingPathComponent("history.sqlite")
        var db: OpaquePointer?
        precondition(sqlite3_open(dbFile.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) { precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        exec("CREATE TABLE thread_turns (thread_id TEXT, status TEXT, rollout_ordinal INTEGER)")
        exec("INSERT INTO thread_turns VALUES ('one', 'completed', 1), ('one', 'inProgress', 2), ('two', 'completed', 3)")
        let working = SessionMetadata.codexTurn(database: dbFile, threadID: "one")!
        precondition(working.state == .working && working.sequence == 1)
        precondition(SessionMetadata.codexTurn(database: dbFile, threadID: "two")?.state == .idle,
                     "A shared server must track each conversation separately")
        exec("UPDATE thread_turns SET status = 'completed' WHERE thread_id = 'one' AND rollout_ordinal = 2")
        let done = SessionMetadata.codexTurn(database: dbFile, threadID: "one")!
        precondition(done.state == .idle && done.sequence == 2)
        precondition(SessionMetadata.codexTurn(database: dbFile, threadID: "missing") == nil)
        precondition(SessionMetadata.codexTurn(database: dbFile, threadID: "one' OR 1=1 --") == nil,
                     "Thread IDs must be bound as values")
        exec("CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
        exec("INSERT INTO threads VALUES ('one', 'Current conversation', 'prompt-derived title'), ('two', NULL, 'historical prompt')")
        precondition(SessionMetadata.codexName(database: dbFile, threadID: "one") == "Current conversation")
        precondition(SessionMetadata.codexName(database: dbFile, threadID: "two") == nil,
                     "Prompt-derived titles must not be used to guess the visible conversation")
        precondition(SessionMetadata.codexName(database: dbFile, threadID: "one' OR 1=1 --") == nil)
        let events = Data("""
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"response_item","payload":{"type":"message"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """.utf8)
        precondition(SessionMetadata.codexEvents(events, id: "one")?.state == .idle)

        let session: [String: Any] = ["id": "ses_one", "location": ["directory": "/work/project"]]
        precondition(SessionMetadata.openCode(session, active: ["type": "running"])?.state == .working)
        precondition(SessionMetadata.openCode(session, active: ["type": "blocked"])?.state == .blocked)
        precondition(SessionMetadata.openCode(session, active: nil)?.state == .unknown,
                     "A stored conversation alone is not proof of work")
        var idle = session; idle["time"] = ["idle": 123_456]
        let idleState = SessionMetadata.openCode(idle, active: nil)!
        precondition(idleState.state == .idle && idleState.sequence == 123_456)
        var activity = AgentActivity()
        func agent(_ state: AgentState, _ seq: Int?) -> AgentInfo {
            AgentInfo(id: "ses_one", name: "opencode", kind: "opencode", state: state, completionSequence: seq)
        }
        activity.update([agent(.working, nil)])
        activity.update([agent(idleState.state, idleState.sequence)])
        precondition(activity.results.count == 1 && activity.active.isEmpty)
        print("PASS: native Claude identity/status, versioned binaries, per-thread Codex state, readonly queries and OpenCode lifecycle")
    }
}
