import Foundation

enum TmuxIntegration {
    static var executable: String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/tmux" }
        return (["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] + paths)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ target: TmuxLocation, _ arguments: [String]) -> CommandResult {
        guard let executable else { return CommandResult(output: "", succeeded: false) }
        return LocalCommand.run(executable, ["-S", target.socketPath] + arguments)
    }

    static func observe(_ target: TmuxLocation, kind: String) -> TerminalObservation {
        let result = run(target, ["capture-pane", "-p", "-t", target.paneID, "-S", "-30"])
        return TerminalObservation(state: result.succeeded ? TerminalState.detect(result.output, kind: kind) : .unknown)
    }

    static func isSelected(_ target: TmuxLocation) -> Bool {
        // tmux can replace control characters with underscores in GUI-launched
        // processes without a UTF-8 locale. Use printable separators for its fields.
        let result = run(target, ["display-message", "-p", "-t", target.paneID, "#{pane_active}|#{window_active}"])
        return result.succeeded && result.output == "1|1"
    }

    /// Resolve the attached client, not the daemon's (usually launchd) parent.
    static func host(for target: TmuxLocation, processes: [SystemProcess], applications: [HostApplication],
                     preferredPID: Int32?, requireCurrentSession: Bool = false) -> (AgentLocation, String)? {
        let pane = run(target, ["display-message", "-p", "-t", target.paneID, "#{session_id}"])
        guard pane.succeeded, !pane.output.isEmpty else { return nil }
        let clients = run(target, ["list-clients", "-F", "#{client_pid}|#{client_tty}|#{session_id}"])
        guard clients.succeeded else { return nil }
        let byPID = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { _, last in last })
        let hosts = Dictionary(applications.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
        let options = clients.output.components(separatedBy: .newlines).compactMap { line -> (AgentLocation, Bool)? in
            let fields = line.components(separatedBy: "|")
            guard fields.count == 3, let pid = Int32(fields[0]), let process = byPID[pid] else { return nil }
            let chain = ProcessDiscovery.ancestry(of: pid, in: byPID)
            guard let app = chain.compactMap({ hosts[$0.identity.pid] }).first else { return nil }
            var location = ProcessDiscovery.location(for: process, chain: chain, applications: applications)
            location.applicationPID = app.pid
            location.bundleID = app.bundleID
            location.tty = fields[1]
            return (location, fields[2] == pane.output)
        }
        let sameSession = options.filter { $0.1 }
        if requireCurrentSession && sameSession.isEmpty { return nil }
        let candidates = sameSession.isEmpty ? options : sameSession
        let preferred = candidates.filter { $0.0.applicationPID == preferredPID }
        if preferred.count == 1, let host = preferred.first { return (host.0, pane.output) }
        guard candidates.count == 1, let host = candidates.first else { return nil }
        return (host.0, pane.output)
    }

    static func select(_ target: TmuxLocation, clientTTY: String, sessionID: String) -> String? {
        for arguments in [["switch-client", "-c", clientTTY, "-t", sessionID],
                          ["select-window", "-t", target.paneID], ["select-pane", "-t", target.paneID]] {
            guard run(target, arguments).succeeded else { return "The tmux pane is no longer available." }
        }
        return nil
    }
}
