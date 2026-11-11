import Foundation

@main
struct AgentLimitsTests {
    static func main() throws {
        func event(_ limits: String, timestamp: String = "2026-11-09T13:01:14.099Z") -> Data {
            Data("""
            {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","rate_limits":\(limits)}}
            """.utf8)
        }
        let valid = """
        {"limit_id":"codex","primary":{"used_percent":8.0,"window_minutes":300,"resets_at":1794230397},
         "secondary":{"used_percent":100,"window_minutes":10080,"resets_at":1794379837}}
        """
        let snapshot = LocalAgentLimits.parse(event(valid))!
        precondition(snapshot.windows.count == 2)
        precondition(snapshot.windows[0].label == "5h")
        precondition(snapshot.windows[0].usedPercent == 8)
        precondition(snapshot.windows[1].label == "Weekly")
        precondition(snapshot.windows[1].usedPercent == 100)
        precondition(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1794230397))
        precondition(LocalAgentLimits.parse(event(valid, timestamp: "2026-11-09T13:01:14Z")) != nil)
        precondition(LocalAgentLimits.parse(event("null")) == nil)
        precondition(LocalAgentLimits.parse(event(valid, timestamp: "bad")) == nil)
        precondition(LocalAgentLimits.parse(event(valid.replacingOccurrences(of: "\"codex\"", with: "\"codex_other\""))) == nil)
        // Invalid windows must never turn into plausible-looking quota values.
        let bad = valid.replacingOccurrences(of: "8.0", with: "-1")
            .replacingOccurrences(of: "10080", with: "0")
        precondition(LocalAgentLimits.parse(event(bad)) == nil)
        precondition(LocalAgentLimits.parse(Data("partial json".utf8)) == nil)
        print("AgentLimitsTests passed")
    }
}
