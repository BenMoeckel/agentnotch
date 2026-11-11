import Combine
import Foundation

struct AgentLimitWindow: Equatable, Identifiable {
    let id: String
    let minutes: Int
    let usedPercent: Double
    let resetsAt: Date

    var label: String {
        if minutes == 10080 { return "Weekly" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

struct AgentLimitSnapshot: Equatable {
    let observedAt: Date
    let windows: [AgentLimitWindow]
}

/// Reads provider-reported quotas only; working time cannot estimate an account limit.
enum LocalAgentLimits {
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func parse(_ data: Data) -> AgentLimitSnapshot? {
        guard let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              entry["type"] as? String == "event_msg",
              let payload = entry["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              (limits["limit_id"] as? String ?? "codex") == "codex",
              let timestamp = entry["timestamp"] as? String,
              let observed = parseDate(timestamp) else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> AgentLimitWindow? in
            guard let window = limits[key] as? [String: Any],
                  let used = window["used_percent"] as? Double, used.isFinite, (0...100).contains(used),
                  let minutes = window["window_minutes"] as? Int, minutes > 0,
                  let reset = window["resets_at"] as? Double, reset.isFinite, reset > 0 else { return nil }
            return AgentLimitWindow(id: key, minutes: minutes, usedPercent: used,
                                    resetsAt: Date(timeIntervalSince1970: reset))
        }
        guard !windows.isEmpty else { return nil }
        return AgentLimitSnapshot(observedAt: observed, windows: windows)
    }

    static func loadCodex(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentLimitSnapshot? {
        let root = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        var files: [(URL, Date)] = []
        for directory in ["sessions", "archived_sessions"] {
            guard let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent(directory),
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                files.append((url, values.contentModificationDate ?? .distantPast))
            }
        }
        var newest: AgentLimitSnapshot?
        // Bound both file count and bytes read; logs can contain very large conversations.
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(20) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { continue }
            let offset = size > 524288 ? size - 524288 : 0
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.readToEnd() else { continue }
            var lines = data.split(separator: 10)
            if offset > 0, !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() {
                guard let snapshot = parse(Data(line)) else { continue }
                if snapshot.observedAt > (newest?.observedAt ?? .distantPast) { newest = snapshot }
            }
        }
        return newest
    }
}

@MainActor
final class AgentLimitsTracker: ObservableObject {
    @Published private(set) var codex: AgentLimitSnapshot?
    @Published private(set) var loading = true

    func refresh() async {
        let snapshot = await Task.detached(priority: .utility) { LocalAgentLimits.loadCodex() }.value
        guard !Task.isCancelled else { return }
        codex = snapshot
        loading = false
    }
}
