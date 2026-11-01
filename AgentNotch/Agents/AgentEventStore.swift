import Foundation

/// Optional lifecycle events for agents/extensions whose UI cannot be inspected.
/// A timestamp predating process creation is rejected, including after PID reuse.
struct AgentEvent: Decodable {
    let pid: Int32
    let session: String?
    let kind: String
    let state: AgentState
    let sequence: Int?
    let updatedAt: TimeInterval
    let title: String?
    let windowTitle: String?

    func applies(to process: ProcessIdentity, now: Date) -> Bool {
        let parts = process.startedAt.split(separator: ".")
        guard let seconds = parts.first.flatMap({ Double($0) }) else { return false }
        let micros = parts.count == 2 ? Double(parts[1]) ?? 0 : 0
        let created = seconds + micros / 1_000_000
        return pid == process.pid && updatedAt >= created && updatedAt <= now.timeIntervalSince1970 + 5 &&
            now.timeIntervalSince1970 - updatedAt < 86_400
    }
}

enum AgentEventStore {
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTNOTCH_EVENT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentNotch/events", isDirectory: true)
    }

    static func read(processes: [SystemProcess], applications: [HostApplication], now: Date = Date(),
                     directory: URL = directory) -> [AgentInfo] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return [] }
        let byPID = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { _, last in last })
        return files.prefix(2048).compactMap { file in
            guard file.pathExtension == "json",
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 16_384,
                  let data = try? Data(contentsOf: file), let event = try? JSONDecoder().decode(AgentEvent.self, from: data),
                  let process = byPID[event.pid], event.applies(to: process.identity, now: now) else { return nil }
            let chain = ProcessDiscovery.ancestry(of: process.identity.pid, in: byPID)
            var location = ProcessDiscovery.location(for: process, chain: chain, applications: applications)
            location.windowTitle = event.windowTitle
            location.sessionID = event.session
            let id = event.session.map { "\(process.identity.id):session:\($0)" } ?? process.identity.id
            return AgentInfo(id: id, name: event.kind, kind: event.kind, state: event.state,
                             completionSequence: event.sequence, completionSource: "event:\(event.kind)", terminalID: process.identity.id,
                             title: event.title, location: location)
        }
    }
}
