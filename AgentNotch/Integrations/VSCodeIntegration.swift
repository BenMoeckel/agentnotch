import AppKit

/// Read existing native windows only. The bundled `code --status` CLI launches
/// another Electron application on macOS, so it must never be used for discovery.
final class VSCodeIntegration {
    private let readWindowTitles: (Int32) -> [String]

    init(readWindowTitles: @escaping (Int32) -> [String] = SessionNavigator.windowTitles) {
        self.readWindowTitles = readWindowTitles
    }

    static func supports(_ bundleID: String?) -> Bool {
        ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss", "com.vscodium"].contains(bundleID ?? "")
    }

    func resolve(_ location: AgentLocation, processes: [SystemProcess], applications: [HostApplication]) -> AgentLocation? {
        resolve(location, processes: processes, applications: applications, readWindowTitles: readWindowTitles)
    }

    private func resolve(_ location: AgentLocation, processes: [SystemProcess], applications: [HostApplication],
                         readWindowTitles: (Int32) -> [String]) -> AgentLocation? {
        guard Self.supports(location.bundleID), location.tty == nil,
              let process = location.process,
              let application = applications.first(where: { $0.pid == location.applicationPID }),
              application.bundleID == location.bundleID else { return nil }
        let byPID = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { _, last in last })
        guard byPID[process.pid]?.identity == process,
              ProcessDiscovery.ancestry(of: process.pid, in: byPID).contains(where: { $0.identity.pid == application.pid }) else {
            return nil
        }
        let titles = readWindowTitles(application.pid)
        guard let index = SessionNavigator.matchingWindow(titles: titles, location: location),
              !titles[index].isEmpty else { return nil }
        var resolved = location
        resolved.windowTitle = titles[index]
        return resolved
    }

    func enrich(_ agents: [AgentInfo], processes: [SystemProcess], applications: [HostApplication]) -> [AgentInfo] {
        // Share one passive read per application within a scan; do not retain
        // titles between scans, since switching editor tabs changes them.
        var titlesByPID: [Int32: [String]] = [:]
        func titles(for pid: Int32) -> [String] {
            if let cached = titlesByPID[pid] { return cached }
            let titles = readWindowTitles(pid)
            titlesByPID[pid] = titles
            return titles
        }
        return agents.map { agent in
            guard let location = agent.location,
                  let resolved = resolve(location, processes: processes, applications: applications, readWindowTitles: titles),
                  let title = resolved.windowTitle else { return agent }
            return AgentInfo(id: agent.id, name: agent.name, kind: agent.kind, state: agent.state,
                             completionSequence: agent.completionSequence, completionSource: agent.completionSource, terminalID: agent.terminalID,
                             title: "\(agent.kind) · \(title)", isFocused: agent.isFocused, location: resolved)
        }
    }
}
