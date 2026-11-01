import Foundation

@main
struct ActivityTests {
    static func agent(_ state: String, seq: Int? = nil, id: String = "a", terminal: String = "t", focused: Bool? = nil) throws -> AgentInfo {
        var payload: [String: Any] = ["pane_id": id, "agent": "claude", "agent_status": state, "terminal_id": terminal]
        if let seq { payload["completion_seq"] = seq }
        if let focused { payload["focused"] = focused }
        return try JSONDecoder().decode(AgentInfo.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    static func main() throws {
        var discovered = AgentActivity()
        discovered.update([try agent("unknown", id: "backend"), try agent("idle", id: "idle"),
                           try agent("done", id: "old-result")])
        precondition(discovered.agents.count == 3 && discovered.active.isEmpty && discovered.results.isEmpty,
                     "Running processes and historical idle/done states must not populate the notch")
        discovered.update([try agent("working", id: "backend"), try agent("blocked", id: "approval"),
                           try agent("unknown", id: "other-backend"), try agent("idle", id: "idle")])
        precondition(discovered.active.map(\.id) == ["approval", "backend"],
                     "Only confirmed work and approval requests count as active")
        discovered.update([try agent("unknown", id: "backend"), try agent("unknown", id: "approval")])
        precondition(discovered.active.isEmpty && discovered.results.isEmpty,
                     "Losing status must hide activity without inventing a completion")
        discovered.update([try agent("working", id: "backend")])
        discovered.update([try agent("idle", id: "backend")])
        let completed = discovered.completions
        discovered.update([try agent("unknown", id: "backend")])
        precondition(discovered.active.isEmpty && discovered.completions == completed && discovered.results.count == 1,
                     "Hiding unknown sessions must preserve real unread results")

        var lateMetadata = AgentActivity()
        lateMetadata.update([try agent("unknown")])
        lateMetadata.update([try agent("done", seq: 40)])
        precondition(lateMetadata.results.isEmpty, "First counter observation is a baseline, even after unknown state")
        lateMetadata.update([try agent("unknown")])
        lateMetadata.update([try agent("done", seq: 40)])
        precondition(lateMetadata.results.isEmpty, "A temporary metadata gap must not replay historical completions")
        lateMetadata.update([try agent("done", seq: 39)])
        lateMetadata.update([try agent("done", seq: 40)])
        precondition(lateMetadata.results.isEmpty, "A stale counter snapshot must not lower the baseline")
        lateMetadata.update([try agent("done", seq: 41)])
        precondition(lateMetadata.results.count == 1, "Real counter advances still detect work between polls")
        var lateDone = AgentActivity()
        lateDone.update([try agent("unknown")])
        lateDone.update([try agent("done")])
        lateDone.update([try agent("idle")])
        lateDone.update([try agent("done")])
        precondition(lateDone.results.isEmpty, "Idle and unknown sessions becoming done are not new work")
        var lateCounter = AgentActivity()
        lateCounter.update([try agent("working")])
        lateCounter.update([try agent("idle", seq: 40)])
        precondition(lateCounter.results.count == 1, "Observed work can complete while its first counter arrives")
        var sourceChange = AgentActivity()
        func sourced(_ source: String, _ sequence: Int, _ state: AgentState = .idle) -> AgentInfo {
            AgentInfo(id: "same", name: "codex", kind: "codex", state: state,
                      completionSequence: sequence, completionSource: source)
        }
        sourceChange.update([sourced("native", 2)])
        sourceChange.update([sourced("herdr", 50)])
        sourceChange.update([sourced("native", 2)])
        precondition(sourceChange.results.isEmpty, "Counters from different providers are independent baselines")
        sourceChange.update([sourced("native", 3)])
        precondition(sourceChange.results.count == 1)

        var enrichedResult = AgentActivity()
        let process = ProcessIdentity(pid: 42, startedAt: "100.0")
        func enriching(_ id: String, _ state: AgentState, session: String? = nil) -> AgentInfo {
            AgentInfo(id: id, name: "codex", kind: "codex", state: state, terminalID: process.id,
                      location: AgentLocation(process: process, sessionID: session))
        }
        enrichedResult.update([enriching("bare-process", .working)])
        enrichedResult.update([enriching("bare-process", .idle)])
        enrichedResult.update([enriching("session:codex:one", .idle, session: "one")])
        precondition(enrichedResult.results.map(\.id) == ["session:codex:one"],
                     "Late session identity migrates the result to its navigable conversation")
        enrichedResult.update([enriching("session:codex:one", .working, session: "one")])
        precondition(enrichedResult.results.isEmpty && enrichedResult.active.count == 1,
                     "Late identity must not leave an old result beside the active conversation")

        var activity = AgentActivity()
        activity.update([try agent("idle", seq: 40)])
        precondition(activity.results.isEmpty && activity.active.isEmpty, "No historical results on startup")
        activity.update([try agent("working", seq: 40)])
        precondition(activity.active.count == 1)
        activity.update([try agent("blocked", seq: 40)])
        precondition(activity.active.first?.state == .blocked && activity.results.isEmpty)
        activity.update([try agent("working", seq: 40)])
        activity.update([try agent("idle", seq: 41)])
        precondition(activity.results.count == 1 && activity.active.isEmpty)
        let seen = activity.completions
        activity.update([try agent("idle", seq: 41)])
        precondition(activity.completions == seen, "Polling must not recreate completions")
        activity.acknowledge(seen)
        activity.update([try agent("idle", seq: 41)])
        precondition(activity.results.isEmpty, "Viewed result must not return")
        activity.update([try agent("idle", seq: 42)])
        precondition(activity.results.count == 1, "Sequence catches work completed between polls")
        activity.acknowledge(seen)
        precondition(activity.results.count == 1, "Old acknowledgement must not clear newer result")
        activity.update([try agent("working", seq: 42)])
        precondition(activity.results.isEmpty && activity.completions.count == 1, "Restarting work retains the result token without displaying the session twice")
        activity.update([try agent("idle", seq: 43)])
        activity.update([try agent("idle", seq: 90, terminal: "replacement")])
        precondition(activity.results.first?.terminalID == "t", "Keep the original result when a pane is reused")
        activity.update([])
        precondition(activity.active.isEmpty && activity.results.count == 1, "Removing a pane must retain unread results")

        var fallback = AgentActivity()
        fallback.update([try agent("done")])
        precondition(fallback.results.isEmpty)
        fallback.update([try agent("working")])
        fallback.update([try agent("idle")])
        precondition(fallback.results.count == 1)
        fallback.update([try agent("blocked")])
        precondition(fallback.results.isEmpty && fallback.completions.count == 1)
        fallback.update([try agent("idle")])
        precondition(fallback.results.count == 1, "Attention resolving keeps the existing result")
        fallback.acknowledge(fallback.completions)

        var dismissed = AgentActivity()
        dismissed.update([try agent("working", seq: 0)])
        dismissed.update([try agent("idle", seq: 1)])
        precondition(dismissed.results.count == 1)
        let staleToken = dismissed.completions["a"]!
        dismissed.dismiss("a", token: staleToken)
        precondition(dismissed.results.isEmpty, "Dismissing a result removes it from the notch")
        dismissed.update([try agent("idle", seq: 1)])
        precondition(dismissed.results.isEmpty, "Polling must not restore a dismissed result")
        dismissed.update([try agent("working", seq: 1)])
        dismissed.update([try agent("idle", seq: 2)])
        precondition(dismissed.results.count == 1, "New work after dismissal produces a new result")
        let newestToken = dismissed.completions["a"]!
        dismissed.dismiss("a", token: staleToken)
        precondition(dismissed.results.count == 1 && dismissed.completions["a"] == newestToken,
                     "A stale dismissal must not clear a newer result")
        dismissed.dismiss("a", token: newestToken)
        precondition(dismissed.results.isEmpty)

        fallback.update([try agent("working", id: "b"), try agent("blocked", id: "c")])
        precondition(fallback.active.map(\.id) == ["c", "b"], "Attention comes first")
        fallback.update([try agent("idle", id: "b"), try agent("done", id: "c")])
        let onlyB = fallback.completions.filter { $0.key == "b" }
        fallback.acknowledge(onlyB)
        precondition(fallback.results.map(\.id) == ["c"], "Unseen rows stay pending")
        fallback.update([])
        precondition(fallback.results.map(\.id) == ["c"], "Disconnected results stay pending")
        let start = Date(timeIntervalSince1970: 1_000_000)
        var timed = AgentActivity()
        timed.update([try agent("working", seq: 0)], now: start)
        timed.update([try agent("idle", seq: 1)], now: start)
        let first = timed.completions
        timed.update([try agent("idle", seq: 1)], now: start.addingTimeInterval(86_399))
        precondition(timed.completions == first, "Polling does not refresh the expiry time")
        timed.expire(now: start.addingTimeInterval(86_400))
        precondition(timed.results.isEmpty, "Results expire at exactly 24 hours even without polling")
        timed.update([try agent("idle", seq: 1)], now: start.addingTimeInterval(86_401))
        precondition(timed.results.isEmpty, "Expired results must not reappear")
        timed.update([try agent("idle", seq: 2)], now: start.addingTimeInterval(86_402))
        timed.acknowledge(first)
        precondition(timed.results.count == 1, "A new result gets its own lifetime and click token")
        timed.expire(now: start.addingTimeInterval(172_801))
        precondition(timed.results.count == 1)
        timed.expire(now: start.addingTimeInterval(172_802))
        precondition(timed.results.isEmpty)
        let missingFocus = try agent("idle")
        precondition(!missingFocus.isFocused, "Missing focus information must not mark a result read")
        var viewed = AgentActivity()
        viewed.update([try agent("working", seq: 0), try agent("working", seq: 0, id: "b")])
        let finished = [try agent("idle", seq: 1, focused: true), try agent("done", seq: 1, id: "b", focused: false)]
        viewed.update(finished)
        precondition(viewed.results.count == 2, "A background terminal must retain even its focused result")
        viewed.update(finished, sessionVisible: true)
        precondition(viewed.results.map(\.id) == ["b"], "Viewing a result in Herdr clears only the focused pane")
        viewed.update(finished)
        precondition(viewed.results.map(\.id) == ["b"], "Read results must not reappear after leaving Herdr")
        viewed.update([try agent("done", seq: 1, id: "b", focused: true)], sessionVisible: true)
        precondition(viewed.results.isEmpty, "Switching panes within Herdr marks the newly focused result read")
        viewed.update([try agent("done", seq: 2, id: "b", focused: true)], sessionVisible: true)
        precondition(viewed.results.isEmpty, "Completion while already viewing the session is read immediately")
        viewed.update([try agent("done", seq: 3, id: "b", focused: true)])
        precondition(viewed.results.count == 1, "A later completion in the background is unread")
        viewed.update([try agent("working", seq: 3, id: "b", focused: true)], sessionVisible: true)
        precondition(viewed.results.isEmpty && viewed.completions.count == 1, "Working sessions retain old results without appearing in both columns")
        viewed.update([try agent("idle", seq: 3, id: "b", terminal: "replacement", focused: true)], sessionVisible: true)
        precondition(viewed.results.count == 1, "Focusing a reused pane must not acknowledge a different terminal")
        print("PASS: activity, retention, expiry, click acknowledgements, foreground/background focus and terminal identity")
    }
}
