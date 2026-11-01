import Foundation

struct EditorSnapshot {
    let target: EditorTarget
    let application: HostApplication
    let terminals: [(pid: Int32, name: String, focused: Bool)]
    var focusedCodexSessionID: String? = nil
}

enum EditorBridge {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentNotch/editors")
    }

    static func snapshots(processes: [SystemProcess], applications: [HostApplication]) -> [EditorSnapshot] {
        let byPID = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { _, last in last })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.prefix(64).compactMap { file in
            guard file.pathExtension == "json", let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 4096, let data = try? Data(contentsOf: file),
                  let descriptor = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = descriptor["pid"] as? Int32, let process = byPID[pid],
                  let path = descriptor["socketPath"] as? String else { return nil }
            let chain = ProcessDiscovery.ancestry(of: pid, in: byPID)
            guard let application = applications.first(where: { app in
                VSCodeIntegration.supports(app.bundleID) && chain.contains(where: { $0.identity.pid == app.pid })
            }), let response = LocalRPC.request(socketPath: path, peerPID: pid, message: ["method": "snapshot"]),
                  response["ok"] as? Bool == true, let result = response["result"] as? [String: Any],
                  result["pid"] as? Int32 == pid else { return nil }
            let terminals = (result["terminals"] as? [[String: Any]] ?? []).compactMap { row -> (Int32, String, Bool)? in
                guard let pid = row["pid"] as? Int32, byPID[pid] != nil else { return nil }
                return (pid, row["name"] as? String ?? "Terminal", row["focused"] as? Bool ?? false)
            }
            return EditorSnapshot(target: EditorTarget(socketPath: path, host: process.identity), application: application,
                                  terminals: terminals, focusedCodexSessionID: result["focusedCodexSessionID"] as? String)
        }
    }

    static func route(_ agent: AgentInfo, snapshots: [EditorSnapshot], processes: [SystemProcess]) -> AgentInfo {
        guard var location = agent.location, let process = location.process else { return agent }
        let byPID = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { _, last in last })
        let chain = ProcessDiscovery.ancestry(of: process.pid, in: byPID)
        let pids = Set(chain.map { $0.identity.pid })
        let matches = snapshots.compactMap { snapshot -> (EditorSnapshot, Int32?, Bool)? in
            if let terminal = snapshot.terminals.first(where: { pids.contains($0.pid) }) {
                return (snapshot, terminal.pid, terminal.focused)
            }
            if location.tty == nil && pids.contains(snapshot.target.host.pid) {
                let focused = agent.kind == "codex" && location.sessionID != nil &&
                    location.sessionID == snapshot.focusedCodexSessionID
                return (snapshot, nil, focused)
            }
            return nil
        }
        guard matches.count == 1, let (snapshot, terminalPID, focused) = matches.first else { return agent }
        var target = snapshot.target
        target.terminalPID = terminalPID
        location.editor = target
        location.applicationPID = snapshot.application.pid
        location.bundleID = snapshot.application.bundleID
        return AgentInfo(id: agent.id, name: agent.name, kind: agent.kind, state: agent.state,
                         completionSequence: agent.completionSequence, completionSource: agent.completionSource, terminalID: agent.terminalID,
                         title: agent.title, isFocused: focused, location: location)
    }

    static func focus(_ location: AgentLocation, kind: String) -> String? {
        guard let target = location.editor, ProcessDiscovery.identity(pid: target.host.pid) == target.host else {
            return "The editor connection has closed. Please try again."
        }
        var message: [String: Any] = ["method": "focus", "kind": kind]
        if let pid = target.terminalPID { message["terminalPID"] = pid }
        if let id = location.sessionID { message["sessionID"] = id }
        guard let response = LocalRPC.request(socketPath: target.socketPath, peerPID: target.host.pid, message: message, timeout: 3) else {
            return "The editor session did not respond."
        }
        guard response["ok"] as? Bool == true,
              (response["result"] as? [String: Any])?["selected"] as? Bool == true else {
            return response["error"] as? String ?? "The editor could not select this session."
        }
        return nil
    }
}
