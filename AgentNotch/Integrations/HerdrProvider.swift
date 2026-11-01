import Foundation
import AppKit
import Darwin

/// Optional source of exact pane state; uses the daemon's local Unix socket.
final class HerdrProvider {
    private(set) var agents: [AgentInfo] = []
    var onSnapshot: (([AgentInfo]) -> Void)?
    let socketPath: String
    private(set) var diagnosticState = "disconnected"
    private let worker = DispatchQueue(label: "com.benmoeckel.agentnotch.herdr.poll", qos: .utility)
    private let navigation = DispatchQueue(label: "com.benmoeckel.agentnotch.herdr.focus", qos: .userInitiated)
    private var pollTimer: Timer?
    private var running = false
    private var scanning = false
    private var generation = 0
    private var requestID = 0
    private var focusRequest: (token: UUID, completion: (String?) -> Void)?

    init(socketPath: String) { self.socketPath = socketPath }

    func focus(_ agent: AgentInfo, completion: @escaping (String?) -> Void) {
        guard focusRequest == nil else { completion("A session is already being opened."); return }
        guard running, agents.contains(where: { $0.id == agent.id && $0.terminalID == agent.terminalID }) else {
            completion("This session is no longer available."); return
        }
        requestID += 1
        let id = String(requestID)
        let token = UUID()
        focusRequest = (token, completion)
        let path = socketPath
        navigation.async { [weak self] in
            let response = LocalRPC.request(socketPath: path,
                message: ["id": id, "method": "agent.focus", "params": ["target": agent.id]], timeout: 3)
            let error: String?
            if let response, response["id"] as? String == id, response["result"] != nil { error = nil }
            else if let message = (response?["error"] as? [String: Any])?["message"] as? String { error = message }
            else { error = "The session did not respond. Please try again." }
            DispatchQueue.main.async {
                guard let self, self.focusRequest?.token == token else { return }
                self.finishFocus(error: error)
            }
        }
    }

    private func finishFocus(error: String?) {
        let completion = focusRequest?.completion
        focusRequest = nil
        completion?(error)
    }

    /// Used only when a pane has no discoverable agent process yet.
    func hostLocation() -> AgentLocation? {
        let processes = ProcessDiscovery.snapshot()
        if let client = Self.clientLocation(socketPath: socketPath, processes: processes,
                                            applications: SessionNavigator.applications()) { return client }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { return nil }
        let byPID = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { _, last in last })
        let chain = ProcessDiscovery.ancestry(of: pid, in: byPID)
        for process in chain {
            if let app = NSRunningApplication(processIdentifier: process.identity.pid), app.activationPolicy == .regular {
                let environment = chain.reversed().reduce(into: [String: String]()) { $0.merge($1.environment) { _, child in child } }
                return AgentLocation(applicationPID: app.processIdentifier, bundleID: app.bundleIdentifier,
                                     tty: chain.reversed().compactMap(\.tty).first,
                                     ghosttySurfaceID: environment["GHOSTTY_SURFACE_ID"])
            }
        }
        return nil
    }

    /// A detached server is owned by launchd. Its attached UI client owns the
    /// terminal surface that needs to be raised after agent.focus.
    static func clientLocation(socketPath: String, processes: [SystemProcess], applications: [HostApplication]) -> AgentLocation? {
        let byPID = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { _, last in last })
        let clients = processes.compactMap { process -> AgentLocation? in
            guard URL(fileURLWithPath: process.executable).lastPathComponent == "herdr",
                  !process.arguments.dropFirst().contains("server"), process.tty != nil else { return nil }
            let args = process.arguments
            var socket = process.environment["HERDR_SOCKET_PATH"] ?? ProcessDiscovery.defaultHerdrSocket
            if let index = args.firstIndex(of: "--socket"), args.indices.contains(index + 1) { socket = args[index + 1] }
            guard socket == socketPath else { return nil }
            let location = ProcessDiscovery.location(for: process, chain: ProcessDiscovery.ancestry(of: process.identity.pid, in: byPID),
                                                     applications: applications)
            return location.applicationPID == nil ? nil : location
        }
        return clients.count == 1 ? clients[0] : nil
    }

    func connect() {
        guard !running else { return }
        running = true
        generation += 1
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        pollTimer?.tolerance = 0.1
        refresh()
    }

    func stop() {
        running = false
        generation += 1
        pollTimer?.invalidate()
        pollTimer = nil
        scanning = false
        diagnosticState = "disconnected"
        finishFocus(error: "The session source disconnected.")
        agents = []
    }

    private func refresh() {
        guard running, !scanning else { return }
        scanning = true
        requestID += 1
        let id = String(requestID)
        let generation = generation
        let path = socketPath
        worker.async { [weak self] in
            let response = LocalRPC.request(socketPath: path,
                message: ["id": id, "method": "agent.list", "params": [:]])
            var snapshot: [AgentInfo]?
            if response?["id"] as? String == id,
               let array = (response?["result"] as? [String: Any])?["agents"],
               let data = try? JSONSerialization.data(withJSONObject: array) {
                snapshot = try? JSONDecoder().decode([AgentInfo].self, from: data)
            }
            DispatchQueue.main.async {
                guard let self, self.running, self.generation == generation else { return }
                self.scanning = false
                self.diagnosticState = snapshot == nil ? "unavailable" : "connected"
                let next = snapshot ?? []
                if self.agents != next {
                    self.agents = next
                    self.onSnapshot?(next)
                }
            }
        }
    }
}
