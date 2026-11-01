import Foundation
import SwiftUI

enum AgentState: String, Decodable {
    case working, blocked, idle, done, unknown

    var color: Color {
        switch self {
        case .working: .orange
        case .blocked: .red
        case .idle:    .white.opacity(0.55)
        case .done:    .green
        case .unknown: .white.opacity(0.4)
        }
    }

    var label: String {
        switch self {
        case .working: "Working"
        case .blocked: "Needs attention"
        case .idle: "Idle"
        case .done: "Done"
        case .unknown: "Unknown"
        }
    }

    var priority: Int {
        switch self {
        case .blocked: 0
        case .working: 1
        case .idle: 2
        case .done: 3
        case .unknown: 4
        }
    }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = AgentState(rawValue: s) ?? .unknown
    }

    /// A live approval request is more specific than a turn that is merely
    /// still in progress. Native Codex turn records stay `inProgress` while
    /// the TUI waits for input, so the visible blocker must win over `working`.
    func merged(with observed: AgentState) -> AgentState {
        if observed == .blocked && self != .blocked { return .blocked }
        if self == .unknown { return observed }
        return self
    }
}

struct AgentInfo: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
    let kind: String
    let state: AgentState
    let completionSequence: Int?
    let completionSource: String?
    let terminalID: String?
    let title: String?
    let isFocused: Bool
    var location: AgentLocation?

    init(id: String, name: String, kind: String, state: AgentState,
         completionSequence: Int? = nil, completionSource: String? = nil, terminalID: String? = nil,
         title: String? = nil, isFocused: Bool = false, location: AgentLocation? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.state = state
        self.completionSequence = completionSequence
        self.completionSource = completionSource
        self.terminalID = terminalID
        self.title = title
        self.isFocused = isFocused
        self.location = location
    }

    enum CodingKeys: String, CodingKey {
        case id = "pane_id"
        case name = "agent"
        case kind
        case harness
        case state
        case agentStatus = "agent_status"
        case completionSequence = "completion_seq"
        case terminalID = "terminal_id"
        case title = "terminal_title_stripped"
        case isFocused = "focused"
        case agentSession = "agent_session"
        case cwd = "cwd"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id    = try c.decode(String.self, forKey: .id)
        name  = (try? c.decode(String.self, forKey: .name)) ?? id
        // agent.list can identify the agent solely through `agent`.
        // Prefer explicit type fields when supplied by other server versions.
        kind = [CodingKeys.kind, .harness, .name]
            .compactMap { try? c.decode(String.self, forKey: $0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        state = (try? c.decode(AgentState.self, forKey: .agentStatus))
            ?? (try? c.decode(AgentState.self, forKey: .state)) ?? .unknown
        completionSequence = try? c.decode(Int.self, forKey: .completionSequence)
        completionSource = nil
        terminalID = try? c.decode(String.self, forKey: .terminalID)
        title = try? c.decode(String.self, forKey: .title)
        isFocused = (try? c.decode(Bool.self, forKey: .isFocused)) ?? false
        let session = try? c.decode([String: String].self, forKey: .agentSession)
        if let cwd = try? c.decode(String.self, forKey: .cwd) {
            location = AgentLocation(workingDirectory: cwd, sessionID: session?["value"])
        } else if let id = session?["value"] {
            location = AgentLocation(sessionID: id)
        }
    }
}

/// Matches an explicit Codex conversation name against the live terminal title.
/// Prompt-derived titles are never used.
enum CodexTitle {
    static func matches(name: String?, workingDirectory: String?, title: String?) -> Bool {
        guard let name, !name.isEmpty, let title else { return false }
        // Codex prefixes its terminal title with a braille activity spinner.
        var visible = String(title.unicodeScalars.drop(while: {
            CharacterSet.whitespacesAndNewlines.contains($0) || (0x2800...0x28ff).contains($0.value)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["[ ! ] Action Required | ", "[ . ] Action Required | "] where visible.hasPrefix(prefix) {
            visible.removeFirst(prefix.count)
            break
        }
        if visible == name { return true }
        guard let workingDirectory else { return false }
        return visible == "\(name) | \(URL(fileURLWithPath: workingDirectory).lastPathComponent)"
    }
}

/// Tracks unseen completions independently of the current idle/working state.
/// The initial snapshot is a baseline, not a batch of new results.
struct AgentActivity: Equatable {
    private(set) var agents: [AgentInfo] = []
    private(set) var completions: [String: UUID] = [:]
    private var completedAgents: [String: AgentInfo] = [:]
    private var completedAt: [String: Date] = [:]
    // Preserve counter baselines through temporary gaps in status data.
    private var sequenceBaselines: [String: AgentInfo] = [:]

    var active: [AgentInfo] {
        // A running backend is not evidence of an active turn. Keep unknown
        // sessions in `agents` so providers/events can still supply their state.
        agents.filter { $0.state == .working || $0.state == .blocked }.sorted {
            if $0.state.priority != $1.state.priority { return $0.state.priority < $1.state.priority }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    var results: [AgentInfo] {
        let activeIDs = Set(active.map(\.id))
        return completedAgents.values.filter { completions[$0.id] != nil && !activeIDs.contains($0.id) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    mutating func update(_ next: [AgentInfo], now: Date = Date(), sessionVisible: Bool = false) {
        expire(now: now)
        // A source may learn the conversation ID only after its first completion.
        // Move the pending result to that identity instead of leaving a second row.
        for (id, completed) in completedAgents where !next.contains(where: { $0.id == id }) {
            let matches = next.filter { candidate in
                guard candidate.kind == completed.kind,
                      let lhs = completed.location, let rhs = candidate.location else { return false }
                if let a = lhs.sessionID, let b = rhs.sessionID { return a == b }
                if let process = lhs.process, process == rhs.process { return true }
                return lhs.herdr != nil && lhs.herdr == rhs.herdr && completed.terminalID != nil &&
                    completed.terminalID == candidate.terminalID
            }
            guard matches.count == 1, let target = matches.first else { continue }
            if completions[target.id] == nil ||
                (completedAt[id] ?? .distantPast) > (completedAt[target.id] ?? .distantPast) {
                completions[target.id] = completions[id]
                completedAgents[target.id] = target
                completedAt[target.id] = completedAt[id]
            }
            completions.removeValue(forKey: id)
            completedAgents.removeValue(forKey: id)
            completedAt.removeValue(forKey: id)
        }
        let previous = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for agent in next {
            guard let old = previous[agent.id], old.terminalID == agent.terminalID else {
                continue
            }
            guard agent.state == .idle || agent.state == .done else { continue }
            let baseline = sequenceBaselines[agent.id]
            let comparable = baseline?.terminalID == agent.terminalID &&
                baseline?.completionSource == agent.completionSource
            let advanced = comparable && agent.completionSequence.map { value in
                baseline?.completionSequence.map { value > $0 } ?? false
            } == true
            // First-time metadata and unknown -> done are historical baselines.
            // A newly available counter only completes an observed active turn.
            let fallback = (agent.completionSequence == nil || !comparable || baseline?.completionSequence == nil) &&
                ((old.state == .working && (agent.state == .idle || agent.state == .done)) ||
                 (old.state == .blocked && agent.state == .done))
            if advanced || fallback {
                completions[agent.id] = UUID()
                completedAgents[agent.id] = agent
                completedAt[agent.id] = now
            }
        }
        sequenceBaselines = sequenceBaselines.filter { id, baseline in
            next.contains { $0.id == id && $0.terminalID == baseline.terminalID }
        }
        for agent in next where agent.completionSequence != nil {
            let baseline = sequenceBaselines[agent.id]
            if baseline?.terminalID != agent.terminalID || baseline?.completionSource != agent.completionSource ||
                (agent.completionSequence ?? 0) > (baseline?.completionSequence ?? -1) {
                sequenceBaselines[agent.id] = agent
            }
        }
        agents = next
        if sessionVisible {
            var seen: [String: UUID] = [:]
            for agent in next where agent.isFocused && (agent.state == .idle || agent.state == .done) {
                guard completedAgents[agent.id]?.terminalID == agent.terminalID,
                      let token = completions[agent.id] else { continue }
                seen[agent.id] = token
            }
            acknowledge(seen)
        }
    }

    mutating func expire(now: Date = Date()) {
        let expired = completions.filter { id, _ in
            guard let date = completedAt[id] else { return false }
            return now.timeIntervalSince(date) >= 24 * 60 * 60
        }
        acknowledge(expired)
    }

    mutating func acknowledge(_ seen: [String: UUID]) {
        // An acknowledgement must never clear a newer completion.
        for (id, token) in seen where completions[id] == token {
            completions.removeValue(forKey: id)
            completedAgents.removeValue(forKey: id)
            completedAt.removeValue(forKey: id)
        }
    }

    /// Removes one visible result without acknowledging a newer completion
    /// that may have arrived for the same session in the meantime.
    mutating func dismiss(_ id: String, token: UUID) {
        acknowledge([id: token])
    }
}
