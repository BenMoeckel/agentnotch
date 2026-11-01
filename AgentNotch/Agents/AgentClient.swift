import AppKit

struct HerdrSnapshot {
    let socketPath: String
    let agents: [AgentInfo]
    var host: AgentInfo? = nil
}

/// Follow the visible frontend through multiplexers before testing its exact tab.
/// Each layer must be selected; an active pane in a hidden terminal is not read.
struct SessionVisibility {
    var herdrHost: (HerdrLocation) -> AgentLocation?
    var tmuxHost: (TmuxLocation) -> AgentLocation?
    var tmuxSelected: (TmuxLocation) -> Bool
    var observeHost: (AgentInfo) -> Bool

    private func host(_ location: AgentLocation, depth: Int = 0) -> AgentLocation? {
        guard depth < 8 else { return nil }
        var tmuxParent: AgentLocation?
        if let pane = location.tmux {
            guard tmuxSelected(pane), let parent = tmuxHost(pane) else { return nil }
            tmuxParent = parent
        }
        if let pane = location.herdr {
            // tmux inside Herdr inherits both targets. Its attached client tells
            // us whether tmux or Herdr is the inner layer.
            if let parent = tmuxParent, parent.herdr == pane {
                return host(parent, depth: depth + 1)
            }
            guard let parent = herdrHost(pane) else { return nil }
            return host(parent, depth: depth + 1)
        }
        if let parent = tmuxParent {
            return host(parent, depth: depth + 1)
        }
        return location
    }

    func apply(_ agent: AgentInfo) -> AgentInfo {
        var location = agent.location
        var focused = false
        if let original = location, let host = host(original) {
            let frontend = AgentInfo(id: agent.id, name: agent.name, kind: agent.kind, state: agent.state,
                                     location: host)
            focused = observeHost(frontend)
            // Keep the agent's identity and multiplexer target for navigation.
            location?.applicationPID = host.applicationPID
            location?.bundleID = host.bundleID
            location?.tty = host.tty
            location?.ghosttySurfaceID = host.ghosttySurfaceID
        }
        return AgentInfo(id: agent.id, name: agent.name, kind: agent.kind, state: agent.state,
                         completionSequence: agent.completionSequence, completionSource: agent.completionSource,
                         terminalID: agent.terminalID, title: agent.title, isFocused: focused, location: location)
    }
}

enum SessionMerger {
    private static func matchesCodexTitle(_ agent: AgentInfo, pane: AgentInfo) -> Bool {
        guard agent.kind == "codex" else { return false }
        return CodexTitle.matches(name: agent.location?.sessionName,
                                  workingDirectory: agent.location?.workingDirectory,
                                  title: pane.title)
    }

    static func merge(system: [AgentInfo], events: [AgentInfo], herdr: [HerdrSnapshot]) -> [AgentInfo] {
        func key(_ agent: AgentInfo) -> String {
            guard let session = agent.location?.sessionID, !session.isEmpty else { return agent.id }
            return "session:\(agent.kind):\(session)"
        }
        func identified(_ agent: AgentInfo, focused: Bool? = nil) -> AgentInfo {
            AgentInfo(id: key(agent), name: agent.name, kind: agent.kind, state: agent.state,
                      completionSequence: agent.completionSequence, completionSource: agent.completionSource,
                      terminalID: agent.terminalID, title: agent.title,
                      isFocused: focused ?? agent.isFocused, location: agent.location)
        }
        var terminalSessions: [String: Set<String>] = [:]
        for agent in system + events {
            if let location = agent.location, location.tty != nil,
               let process = location.process, let session = location.sessionID {
                terminalSessions["\(agent.kind):\(process.id)", default: []].insert(session)
            }
        }
        func ambiguousTerminal(_ agent: AgentInfo) -> Bool {
            guard let location = agent.location, location.tty != nil,
                  let process = location.process else { return false }
            return (terminalSessions["\(agent.kind):\(process.id)"]?.count ?? 0) > 1
        }
        // Prefer a concrete frontend over a shared backend for the same conversation.
        let ordered = system.sorted { left, right in
            let lhs = left.location?.tty != nil
            let rhs = right.location?.tty != nil
            if lhs != rhs { return !lhs }
            // Without a terminal, an editor-owned backend is more specific than
            // a shared daemon that inherited an old terminal environment.
            if !lhs && !rhs {
                let lhsEditor = left.location?.editor != nil || VSCodeIntegration.supports(left.location?.bundleID)
                let rhsEditor = right.location?.editor != nil || VSCodeIntegration.supports(right.location?.bundleID)
                if lhsEditor != rhsEditor { return !lhsEditor }
            }
            return left.id < right.id
        }
        var merged: [String: AgentInfo] = [:]
        for agent in ordered {
            // Herdr itself must confirm which conversation its visible pane owns.
            let focused = agent.isFocused && agent.location?.herdr == nil && !ambiguousTerminal(agent)
            merged[key(agent)] = identified(agent, focused: focused)
        }
        for snapshot in herdr {
            for pane in snapshot.agents {
                let target = HerdrLocation(socketPath: snapshot.socketPath, paneID: pane.id)
                let exact = ordered.filter {
                    pane.location?.sessionID != nil && $0.kind == pane.kind &&
                    $0.location?.sessionID == pane.location?.sessionID
                }
                var matches = exact.isEmpty ? ordered.filter {
                    $0.location?.herdr == target &&
                    (pane.location?.sessionID == nil || $0.location?.sessionID == nil)
                } : exact
                // A TUI can retain several rollout files after /resume. Its exact
                // explicit name in the live terminal title identifies the selected
                // conversation when Herdr has not supplied a session ID yet.
                if exact.isEmpty && Set(matches.map { key($0) }).count > 1 {
                    let named = matches.filter { matchesCodexTitle($0, pane: pane) }
                    if Set(named.map { key($0) }).count == 1 { matches = named }
                }
                // A pane may hold several conversations; only an exact session match
                // may choose between them. Never match by agent name or project.
                let matchKeys = Set(matches.map { key($0) })
                if matchKeys.count > 1 { continue }
                let process = matchKeys.count == 1 ? matches.last : nil
                var location = process?.location ?? pane.location ?? AgentLocation()
                if let host = snapshot.host?.location {
                    location.applicationPID = host.applicationPID
                    location.bundleID = host.bundleID
                    location.tty = host.tty
                    location.ghosttySurfaceID = host.ghosttySurfaceID
                    location.editor = host.editor
                    location.tmux = host.tmux
                }
                location.herdr = target
                location.sessionID = location.sessionID ?? pane.location?.sessionID
                let id = process.map { key($0) } ?? target.id
                let nativeState = process?.location?.sessionID != nil && process?.state != .unknown
                // Herdr's live pane state is more specific than a native turn
                // record that remains in progress while Codex waits for input.
                let state = nativeState ? process!.state.merged(with: pane.state) : pane.state
                let innerVisible = process?.location?.tmux == nil || process?.isFocused == true
                let info = AgentInfo(id: id, name: pane.name, kind: process?.kind ?? pane.kind,
                                     state: state,
                                     completionSequence: nativeState ? process?.completionSequence : pane.completionSequence,
                                     completionSource: nativeState ? process?.completionSource : "herdr:\(snapshot.socketPath)",
                                     terminalID: process?.terminalID ?? pane.terminalID,
                                     title: pane.title ?? process?.title,
                                     isFocused: pane.isFocused && innerVisible &&
                                        (snapshot.host?.isFocused ?? process?.isFocused ?? false), location: location)
                if id != key(info) { merged.removeValue(forKey: id) }
                merged[key(info)] = identified(info)
            }
        }
        for event in events {
            // Explicit conversation records replace an otherwise undifferentiated extension host.
            if let process = event.location?.process, event.id != process.id { merged.removeValue(forKey: process.id) }
            let existing = merged[key(event)]
            if let existing, existing.location?.herdr != nil {
                // Lifecycle events supply state, never bypass pane selection.
                merged[key(event)] = AgentInfo(id: key(event), name: event.name, kind: event.kind, state: event.state,
                    completionSequence: event.completionSequence, completionSource: event.completionSource,
                    terminalID: event.terminalID, title: event.title,
                    isFocused: existing.isFocused, location: existing.location)
            } else {
                merged[key(event)] = identified(event, focused: event.isFocused &&
                    event.location?.herdr == nil && !ambiguousTerminal(event))
            }
        }
        return merged.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}

/// Owns UI state independently of whichever hosts happen to be running.
final class AgentClient: ObservableObject {
    static let shared = AgentClient()
    @Published private(set) var activity = AgentActivity()
    var agents: [AgentInfo] { activity.agents }

    private let worker = DispatchQueue(label: "com.benmoeckel.agentnotch.discovery", qos: .utility)
    private let navigation = DispatchQueue(label: "com.benmoeckel.agentnotch.navigation", qos: .userInitiated)
    private var timer: Timer?
    private var scanning = false
    private var opening = false
    private var generation = 0
    private var systemAgents: [AgentInfo] = []
    private var eventAgents: [AgentInfo] = []
    private var herdrHosts: [String: AgentInfo] = [:]
    private var providers: [String: HerdrProvider] = [:]
    private let editors = VSCodeIntegration()
    private let nativeSessions = NativeSessionIntegration()

    func connect() {
        guard timer == nil else { return }
        generation += 1
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            var next = self.activity
            next.expire()
            if next != self.activity { self.activity = next }
            self.refresh()
        }
        timer?.tolerance = 0.1
        refresh()
    }

    func disconnect() {
        timer?.invalidate()
        timer = nil
        generation += 1
        scanning = false
        providers.values.forEach { $0.stop() }
        providers.removeAll()
    }

    func acknowledge(_ seen: [String: UUID]) {
        var next = activity
        next.acknowledge(seen)
        if next != activity { activity = next }
    }

    func dismiss(_ agent: AgentInfo) {
        guard let token = activity.completions[agent.id] else { return }
        var next = activity
        next.dismiss(agent.id, token: token)
        if next != activity { activity = next }
    }

    #if DEBUG
    var sourceDiagnostics: [[String: Any]] {
        providers.values.map { provider -> [String: Any] in
            let host = herdrHosts[provider.socketPath]
            let surface: String = host?.location?.ghosttySurfaceID ?? ""
            return [
                "socket": provider.socketPath,
                "state": provider.diagnosticState,
                "agents": provider.agents.count,
                "hostFocused": host?.isFocused ?? false,
                "hostPID": host?.location?.applicationPID ?? 0,
                "hostSurface": surface
            ]
        }
    }
    #endif

    private func refresh() {
        guard !scanning else { return }
        scanning = true
        let generation = generation
        let apps = SessionNavigator.applications()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let editors = editors
        let nativeSessions = nativeSessions
        let providerSockets = Set(providers.keys)
        let providerPanes = providers.values.map { HerdrSnapshot(socketPath: $0.socketPath, agents: $0.agents) }
        worker.async { [weak self] in
            let processes = ProcessDiscovery.snapshot()
            let discovered = editors.enrich(ProcessDiscovery.agents(in: processes, applications: apps),
                                            processes: processes, applications: apps)
            let events = AgentEventStore.read(processes: processes, applications: apps)
            var terminalCache: [String: TerminalObservation] = [:]
            func observeTerminal(_ location: AgentLocation, kind: String) -> TerminalObservation {
                let key = "\(location.applicationPID ?? 0):\(location.tty ?? ""):\(location.ghosttySurfaceID ?? ""):\(kind)"
                if let cached = terminalCache[key] { return cached }
                let result = TerminalIntegration.observe(location, kind: kind, frontmostPID: frontmostPID)
                terminalCache[key] = result
                return result
            }
            let bridges = EditorBridge.snapshots(processes: processes, applications: apps)
            let sockets = providerSockets.union((discovered + events).compactMap { $0.location?.herdr?.socketPath })
                .union([ProcessDiscovery.defaultHerdrSocket])
            var hostLocations: [String: AgentLocation] = [:]
            for socket in sockets {
                if let host = HerdrProvider.clientLocation(socketPath: socket, processes: processes, applications: apps) {
                    hostLocations[socket] = host
                }
            }
            let visibility = SessionVisibility(
                herdrHost: { hostLocations[$0.socketPath] },
                tmuxHost: { target in
                    TmuxIntegration.host(for: target, processes: processes, applications: apps,
                                         preferredPID: frontmostPID, requireCurrentSession: true)?.0
                },
                tmuxSelected: { TmuxIntegration.isSelected($0) },
                observeHost: { agent in
                    guard let location = agent.location else { return false }
                    let editor = EditorBridge.route(agent, snapshots: bridges, processes: processes)
                    if editor.location?.editor != nil { return editor.isFocused }
                    return observeTerminal(location, kind: agent.kind).isVisible
                })
            let observed = discovered.map { agent -> AgentInfo in
                guard let location = agent.location else { return agent }
                // Multiplexer status comes from its own panes, never the outer terminal's screen.
                let state: AgentState
                if location.herdr != nil { state = .unknown }
                else if let tmux = location.tmux { state = TmuxIntegration.observe(tmux, kind: agent.kind).state }
                else { state = observeTerminal(location, kind: agent.kind).state }
                return AgentInfo(id: agent.id, name: agent.name, kind: agent.kind, state: state,
                                 terminalID: agent.terminalID, title: agent.title, location: location)
            }
            let native = nativeSessions.enrich(observed, processes: processes, herdr: providerPanes)
            func route(_ agent: AgentInfo) -> AgentInfo {
                visibility.apply(EditorBridge.route(agent, snapshots: bridges, processes: processes))
            }
            let routed = native.map(route)
            let routedEvents = events.map(route)
            let hosts = hostLocations.mapValues { location in
                route(AgentInfo(id: "host", name: "host", kind: "", state: .unknown, location: location))
            }
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.scanning = false
                self.systemAgents = routed
                self.eventAgents = routedEvents
                self.herdrHosts = hosts
                self.updateProviders()
                self.publish()
            }
        }
    }

    private func updateProviders() {
        var sockets = Set(systemAgents.compactMap { $0.location?.herdr?.socketPath })
        // Discovery works from Finder too, where HERDR_* variables are absent.
        if FileManager.default.fileExists(atPath: ProcessDiscovery.defaultHerdrSocket) {
            sockets.insert(ProcessDiscovery.defaultHerdrSocket)
        }
        for path in Array(providers.keys) where !sockets.contains(path) {
            providers.removeValue(forKey: path)?.stop()
        }
        for path in sockets where providers[path] == nil {
            let provider = HerdrProvider(socketPath: path)
            provider.onSnapshot = { [weak self] _ in self?.publish() }
            providers[path] = provider
            provider.connect()
        }
    }

    private func publish() {
        let snapshots = providers.values.map { HerdrSnapshot(socketPath: $0.socketPath, agents: $0.agents, host: herdrHosts[$0.socketPath]) }
        let merged = SessionMerger.merge(system: systemAgents, events: eventAgents, herdr: snapshots)
        // Recheck the foreground app when a provider publishes between process scans.
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let visible = merged.map { agent in
            AgentInfo(id: agent.id, name: agent.name, kind: agent.kind, state: agent.state,
                      completionSequence: agent.completionSequence, completionSource: agent.completionSource, terminalID: agent.terminalID,
                      title: agent.title, isFocused: agent.isFocused && frontmost != nil &&
                        agent.location?.applicationPID == frontmost, location: agent.location)
        }
        var next = activity
        next.update(visible, sessionVisible: true)
        if next != activity { activity = next }
    }

    func focus(_ agent: AgentInfo, completion: @escaping (String?) -> Void) {
        guard !opening else { completion("A session is already being opened."); return }
        let candidates = agents + activity.results
        guard let current = candidates.first(where: { $0.id == agent.id && $0.terminalID == agent.terminalID }),
              let location = current.location else {
            completion("This session is no longer available.")
            return
        }
        opening = true
        let finish: (String?) -> Void = { [weak self] error in
            self?.opening = false
            completion(error)
        }
        let navigate: (AgentLocation, Bool) -> Void = { [weak self] target, terminalAlreadySelected in
            guard let self else { return }
            let apps = SessionNavigator.applications()
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            self.navigation.async {
                let error = SessionNavigator.focus(target, applications: apps, frontmostPID: frontmostPID,
                                                    kind: agent.kind, terminalAlreadySelected: terminalAlreadySelected)
                DispatchQueue.main.async { finish(error) }
            }
        }
        if let process = location.process, ProcessDiscovery.identity(pid: process.pid) != process {
            finish("This session is no longer available.")
            return
        }
        if let herdr = location.herdr {
            guard let provider = providers[herdr.socketPath],
                  let pane = provider.agents.first(where: { $0.id == herdr.paneID }) else {
                finish("The Herdr session is currently unavailable.")
                return
            }
            provider.focus(pane) { error in
                if let error { finish(error); return }
                if location.applicationPID != nil || location.tmux != nil { navigate(location, true) }
                else {
                    self.navigation.async {
                        let host = provider.hostLocation()
                        DispatchQueue.main.async {
                            guard let host else { finish("Could not find the terminal hosting this session."); return }
                            navigate(host, true)
                        }
                    }
                }
            }
        } else { navigate(location, false) }
    }
}
