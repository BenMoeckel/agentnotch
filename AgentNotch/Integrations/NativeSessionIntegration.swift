import Foundation
import SQLite3
import Darwin

struct NativeSession {
    var id: String
    var state: AgentState
    var sequence: Int?
    var cwd: String?
    var title: String?
}

enum SessionMetadata {
    static func json(_ file: URL, limit: Int = 16_384) -> [String: Any]? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit,
              let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func claude(_ json: [String: Any], process: ProcessIdentity) -> NativeSession? {
        let seconds = Double(process.startedAt.split(separator: ".").first ?? "") ?? .infinity
        guard (json["pid"] as? NSNumber)?.int64Value == Int64(process.pid),
              let started = (json["startedAt"] as? NSNumber)?.doubleValue,
              started / 1000 >= seconds, started / 1000 < seconds + 120,
              let id = json["sessionId"] as? String, let status = json["status"] as? String else { return nil }
        let state: AgentState
        switch status {
        case "working", "running", "busy": state = .working
        case "waiting_for_permission", "waiting_for_input", "blocked", "waiting": state = .blocked
        case "idle": state = .idle
        default: state = .unknown
        }
        return NativeSession(id: id, state: state, cwd: json["cwd"] as? String, title: json["name"] as? String)
    }

    static func codexTurn(database: URL, threadID: String) -> NativeSession? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        let sql = """
        SELECT status, (SELECT count(*) FROM thread_turns WHERE thread_id = ?1 AND status = 'completed')
        FROM thread_turns WHERE thread_id = ?1 ORDER BY rollout_ordinal DESC LIMIT 1
        """
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(query) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(query, 1, threadID, -1, transient)
        guard sqlite3_step(query) == SQLITE_ROW, let raw = sqlite3_column_text(query, 0) else { return nil }
        let status = String(cString: raw)
        let state: AgentState
        switch status {
        case "inProgress": state = .working
        case "completed", "interrupted", "failed": state = .idle
        default: state = .unknown
        }
        return NativeSession(id: threadID, state: state, sequence: Int(sqlite3_column_int64(query, 1)))
    }

    /// Read the explicit conversation name, never the prompt-derived title.
    static func codexName(database: URL, threadID: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM threads WHERE id = ?1", -1, &query, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(query) == SQLITE_ROW, let raw = sqlite3_column_text(query, 0) else { return nil }
        let name = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func codexEvents(_ data: Data, id: String) -> NativeSession? {
        var session: NativeSession?
        for line in data.split(separator: 10) {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  json["type"] as? String == "event_msg", let payload = json["payload"] as? [String: Any] else { continue }
            switch payload["type"] as? String {
            case "task_started": session = NativeSession(id: id, state: .working)
            case "task_complete", "turn_aborted": session = NativeSession(id: id, state: .idle)
            default: break
            }
        }
        return session
    }

    static func openCode(_ json: [String: Any], active: [String: Any]?) -> NativeSession? {
        guard let id = json["id"] as? String else { return nil }
        let state: AgentState
        switch active?["type"] as? String {
        case "running", "busy", "retry": state = .working
        case "blocked", "waiting", "suspended": state = .blocked
        default:
            state = (json["time"] as? [String: Any])?["idle"] != nil ? .idle : .unknown
        }
        let time = json["time"] as? [String: Any]
        return NativeSession(id: id, state: state, sequence: (time?["idle"] as? NSNumber)?.intValue,
                             cwd: (json["location"] as? [String: Any])?["directory"] as? String ?? json["directory"] as? String,
                             title: json["title"] as? String)
    }
}

/// Uses already-running agents' own status records. Never starts an agent or reads prompts.
final class NativeSessionIntegration {
    private let home: URL
    private var openFiles: [Int32: [String]] = [:]
    private var lastFileScan = Date.distantPast
    private var lastProcesses: Set<ProcessIdentity> = []
    private var openCodeIDs: Set<String> = []

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    /// Read descriptors directly; spawning lsof also inspects unrelated file/socket metadata.
    static func rolloutPaths(pid: Int32) -> [String] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        // Allow descriptors opened between sizing and reading.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 64)
        let read = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard read > 0 else { return [] }
        return descriptors.prefix(Int(read) / stride).compactMap { descriptor in
            guard descriptor.proc_fdtype == PROX_FDTYPE_VNODE else { return nil }
            var info = vnode_fdinfowithpath()
            let size = MemoryLayout<vnode_fdinfowithpath>.size
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(size)) == size else { return nil }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            return path.contains("/sessions/") && path.hasSuffix(".jsonl") ? path : nil
        }
    }

    /// Metadata is the first line; most rollouts need just one small read.
    static func firstLine(_ file: FileHandle) -> Data? {
        var data = Data()
        while data.count < 1_048_576 {
            guard let chunk = try? file.read(upToCount: 4096), !chunk.isEmpty else {
                return data.isEmpty ? nil : data
            }
            if let end = chunk.firstIndex(of: 10) {
                data.append(chunk[..<end])
                return data
            }
            data.append(chunk)
        }
        return nil
    }

    func enrich(_ agents: [AgentInfo], processes: [SystemProcess], herdr: [HerdrSnapshot] = []) -> [AgentInfo] {
        var sessions: [String: [AgentInfo]] = [:]
        let paneTitles = Dictionary(herdr.flatMap { snapshot in
            snapshot.agents.compactMap { pane -> (HerdrLocation, String)? in
                guard let title = pane.title else { return nil }
                return (HerdrLocation(socketPath: snapshot.socketPath, paneID: pane.id), title)
            }
        }, uniquingKeysWith: { first, _ in first })
        func append(_ session: NativeSession, to agent: AgentInfo) {
            guard var location = agent.location else { return }
            location.sessionID = session.id
            location.sessionName = session.title
            if let cwd = session.cwd { location.workingDirectory = cwd }
            let project = location.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? agent.name
            // Codex keeps its turn record at `inProgress` while the TUI waits for
            // approval. Preserve a blocked screen observation instead of hiding it.
            let state = session.state.merged(with: agent.state)
            let info = AgentInfo(id: "\(agent.id):session:\(session.id)", name: agent.name, kind: agent.kind, state: state,
                                 completionSequence: session.sequence, completionSource: "native:\(agent.kind)", terminalID: agent.terminalID,
                                 title: session.title ?? "\(agent.kind) · \(project)", isFocused: agent.isFocused, location: location)
            // A frontend and shared server can hold the same rollout open.
            sessions[agent.id, default: []].removeAll { $0.location?.sessionID == session.id }
            sessions[agent.id, default: []].append(info)
        }
        for agent in agents where agent.kind == "claude" {
            guard let identity = agent.location?.process,
                  let json = SessionMetadata.json(home.appendingPathComponent(".claude/sessions/\(identity.pid).json")),
                  let session = SessionMetadata.claude(json, process: identity) else { continue }
            append(session, to: agent)
        }
        let codex = agents.filter { $0.kind == "codex" }
        let identities = Set(codex.compactMap { $0.location?.process })
        let pids = Set(identities.map(\.pid))
        if identities != lastProcesses || Date().timeIntervalSince(lastFileScan) > 2 {
            lastFileScan = Date(); lastProcesses = identities; openFiles = [:]
            for pid in pids {
                openFiles[pid] = Self.rolloutPaths(pid: pid)
            }
        }
        let byPID = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { _, last in last })
        for owner in codex {
            guard let pid = owner.location?.process?.pid else { continue }
            for path in Set(openFiles[pid] ?? []) {
                guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { continue }
                defer { try? file.close() }
                guard let line = Self.firstLine(file),
                      let meta = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      meta["type"] as? String == "session_meta", let payload = meta["payload"] as? [String: Any],
                      let id = payload["id"] as? String else { continue }
                var session = SessionMetadata.codexTurn(database: home.appendingPathComponent(".codex/thread_history_1.sqlite"), threadID: id)
                if session == nil, let size = try? file.seekToEnd() {
                    try? file.seek(toOffset: size > 2_097_152 ? size - 2_097_152 : 0)
                    if let tail = try? file.read(upToCount: 2_097_152) { session = SessionMetadata.codexEvents(tail, id: id) }
                }
                guard var session else { continue }
                session.cwd = payload["cwd"] as? String
                session.title = SessionMetadata.codexName(database: home.appendingPathComponent(".codex/state_5.sqlite"), threadID: id)
                var target = owner
                // Shared app servers inherit obsolete terminal environment. Route a
                // TUI conversation to its live frontend, not the daemon. A pane title
                // distinguishes several TUIs that share the same project.
                let backend = owner.location?.tty == nil ||
                    (byPID[pid]?.arguments.contains("app-server") ?? false)
                // An editor-hosted app server owns its conversation even when a
                // TUI happens to share the same project.
                let editorHosted = VSCodeIntegration.supports(owner.location?.bundleID)
                if payload["originator"] as? String == "codex-tui", backend, !editorHosted {
                    let frontends = codex.filter { agent in
                        guard let location = agent.location, let pid = location.process?.pid else { return false }
                        return location.tty != nil && location.workingDirectory == session.cwd &&
                            !(byPID[pid]?.arguments.contains("app-server") ?? true)
                    }
                    if frontends.count == 1 {
                        target = frontends[0]
                    } else if frontends.count > 1 {
                        let named = frontends.filter { frontend in
                            guard let pane = frontend.location?.herdr, let title = paneTitles[pane] else { return false }
                            return CodexTitle.matches(name: session.title, workingDirectory: session.cwd, title: title)
                        }
                        if named.count == 1 { target = named[0] }
                    }
                }
                append(session, to: target)
            }
        }
        if let service = SessionMetadata.json(home.appendingPathComponent(".local/state/opencode/service.json")),
           let pid = service["pid"] as? Int32, let process = byPID[pid],
           AgentCatalog.kind(executable: process.executable, arguments: process.arguments) == "opencode",
           let base = service["url"] as? String, let url = URL(string: base),
           url.scheme == "http", ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? ""),
           let password = service["password"] as? String,
           let activeResponse = LocalHTTP.json(url.appendingPathComponent("api/session/active"), password: password),
           let active = activeResponse["data"] as? [String: [String: Any]] {
            let ids = active.keys.sorted() + openCodeIDs.subtracting(active.keys).sorted()
            openCodeIDs = Set(active.keys)
            for id in ids.prefix(128) where id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
                guard let response = LocalHTTP.json(url.appendingPathComponent("api/session/\(id)"), password: password),
                      let session = SessionMetadata.openCode(response["data"] as? [String: Any] ?? response, active: active[id]) else { continue }
                let targets = agents.filter { agent in
                    guard agent.kind == "opencode", let location = agent.location, let pid = location.process?.pid else { return false }
                    return location.workingDirectory == session.cwd && location.tty != nil && !(byPID[pid]?.arguments.contains("serve") ?? true)
                }
                // The service owns every frontend's drains. A shared project does
                // not identify which frontend selected this conversation. In that
                // case let the pane/event provider report its exact owner rather
                // than inventing a second active agent on the service process.
                let target = targets.count == 1 ? targets[0] : targets.isEmpty
                    ? agents.first(where: { $0.location?.process?.pid == pid }) : nil
                if let target { append(session, to: target) }
                // Keep an idle record available for result navigation while its process exists.
                if target != nil { openCodeIDs.insert(id) }
            }
        }
        return agents.flatMap { sessions[$0.id] ?? [$0] }
    }
}

private final class LocalHTTP: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    static func json(_ url: URL, password: String) -> [String: Any]? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.8
        config.timeoutIntervalForResource = 1
        config.connectionProxyDictionary = [:]
        let delegate = LocalHTTP()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: [String: Any]?
        session.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count <= 1_048_576,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            lock.lock(); result = json; lock.unlock()
        }.resume()
        guard done.wait(timeout: .now() + 1.2) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return result
    }
}
