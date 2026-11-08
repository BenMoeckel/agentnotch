import Foundation
import SQLite3

/// Reconstructs approximate working time from the session logs that local
/// coding agents already keep on disk. This is deliberately conservative: it
/// only bridges gaps of up to ten minutes, so a session left open overnight
/// does not turn into a full day of work.
enum UsageBackfill {
    /// Bump when the parsing rules change; the import is then repeated once.
    static let version = 2
    static let maxGap: TimeInterval = 10 * 60

    static func load(calendar: Calendar = .autoupdatingCurrent,
                     before endDate: Date = Date(),
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: UsageDay] {
        let end = calendar.startOfDay(for: endDate)
        let cutoff = Date.distantPast

        var all: [DateInterval] = []
        var byAgent: [String: [DateInterval]] = [:]
        var byProject: [String: [DateInterval]] = [:]

        func add(_ interval: DateInterval, agent: String, project: String?) {
            guard interval.duration > 0 else { return }
            all.append(interval)
            byAgent[agent, default: []].append(interval)
            if let project { byProject[project, default: []].append(interval) }
        }

        loadClaude(home: home, cutoff: cutoff, end: end, add: add)
        loadCodex(home: home, cutoff: cutoff, end: end, add: add)
        loadOpenCode(home: home, cutoff: cutoff, end: end, add: add)

        var result: [String: UsageDay] = [:]
        for (key, seconds) in bucket(union(all), calendar: calendar, before: end) {
            result[key, default: UsageDay()].totalSeconds += seconds
        }
        for (agent, intervals) in byAgent {
            for (key, seconds) in bucket(union(intervals), calendar: calendar, before: end) {
                result[key, default: UsageDay()].agents[agent, default: 0] += seconds
            }
        }
        for (project, intervals) in byProject {
            for (key, seconds) in bucket(union(intervals), calendar: calendar, before: end) {
                result[key, default: UsageDay()].projects[project, default: 0] += seconds
            }
        }
        return result.filter { $0.value.totalSeconds > 0.5 }
    }

    // MARK: - Claude Code

    private static func loadClaude(home: URL,
                                   cutoff: Date,
                                   end: Date,
                                   add: (DateInterval, String, String?) -> Void) {
        let root = home.appendingPathComponent(".claude/projects")
        for url in files(in: root) {
            var dates: [Date] = []
            var project: String?
            for line in lines(in: url) {
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let value = entry["timestamp"] as? String,
                      let date = parseISO(value),
                      date >= cutoff, date < end else { continue }
                dates.append(date)
                if project == nil,
                   let cwd = entry["cwd"] as? String,
                   let key = UsageTracker.projectKey(cwd) {
                    project = key
                }
            }
            for interval in intervals(from: dates) {
                add(interval, "claude", project)
            }
        }
    }

    // MARK: - Codex

    private static func loadCodex(home: URL,
                                  cutoff: Date,
                                  end: Date,
                                  add: (DateInterval, String, String?) -> Void) {
        for relative in [".codex/sessions", ".codex/archived_sessions"] {
            for url in files(in: home.appendingPathComponent(relative)) {
                var project: String?
                var started: Date?
                var sawTask = false
                var fallback: [Date] = []

                for line in lines(in: url) {
                    guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                        continue
                    }
                    let payload = entry["payload"] as? [String: Any] ?? [:]
                    if project == nil,
                       let cwd = (payload["cwd"] ?? entry["cwd"]) as? String,
                       let key = UsageTracker.projectKey(cwd) {
                        project = key
                    }
                    guard let value = entry["timestamp"] as? String,
                          let date = parseISO(value),
                          date >= cutoff, date < end else { continue }

                    let type = payload["type"] as? String ?? entry["type"] as? String
                    if type == "task_started" {
                        sawTask = true
                        if let epoch = payload["started_at"] as? Double {
                            started = max(cutoff, Date(timeIntervalSince1970: epoch))
                        } else {
                            started = date
                        }
                    } else if type == "task_complete" {
                        sawTask = true
                        if let started, date > started {
                            add(DateInterval(start: started, end: date), "codex", project)
                        }
                        started = nil
                    }
                    fallback.append(date)
                }

                // Older rollouts have no task_started/task_complete events.
                if !sawTask {
                    for interval in intervals(from: fallback) {
                        add(interval, "codex", project)
                    }
                }
            }
        }
    }

    // MARK: - OpenCode

    private static func loadOpenCode(home: URL,
                                     cutoff: Date,
                                     end: Date,
                                     add: (DateInterval, String, String?) -> Void) {
        let database = home.appendingPathComponent(".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: database.path) else { return }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle else { return }
        defer { sqlite3_close(handle) }

        let sql = """
        SELECT s.directory, m.time_created, m.session_id
        FROM message m JOIN session s ON s.id = m.session_id
        WHERE m.time_created >= ?
        ORDER BY m.session_id, m.time_created
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(cutoff.timeIntervalSince1970 * 1000))

        var sessions: [String: (project: String?, dates: [Date])] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionText = sqlite3_column_text(statement, 2) else { continue }
            let sessionID = String(cString: sessionText)
            let directory = sqlite3_column_text(statement, 0).map { String(cString: $0) }
            let milliseconds = sqlite3_column_int64(statement, 1)
            let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            guard date < end else { continue }
            if sessions[sessionID] == nil {
                sessions[sessionID] = (UsageTracker.projectKey(directory), [])
            }
            sessions[sessionID]?.dates.append(date)
        }

        for session in sessions.values {
            for interval in intervals(from: session.dates) {
                add(interval, "opencode", session.project)
            }
        }
    }

    // MARK: - Interval maths

    private static func intervals(from dates: [Date]) -> [DateInterval] {
        let sorted = dates.sorted()
        guard sorted.count > 1 else { return [] }
        var result: [DateInterval] = []
        for index in 1..<sorted.count {
            let gap = sorted[index].timeIntervalSince(sorted[index - 1])
            if gap > 0 && gap <= maxGap {
                result.append(DateInterval(start: sorted[index - 1], end: sorted[index]))
            }
        }
        return result
    }

    private static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var result: [DateInterval] = []
        for interval in sorted {
            if let last = result.last, interval.start <= last.end {
                if interval.end > last.end {
                    result[result.count - 1] = DateInterval(start: last.start, end: interval.end)
                }
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private static func bucket(_ intervals: [DateInterval],
                               calendar: Calendar,
                               before end: Date) -> [String: Double] {
        var result: [String: Double] = [:]
        for interval in intervals {
            var cursor = interval.start
            let limit = min(interval.end, end)
            guard cursor < limit else { continue }
            while cursor < limit {
                let dayStart = calendar.startOfDay(for: cursor)
                let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? limit
                let sliceEnd = min(limit, nextDay)
                let seconds = sliceEnd.timeIntervalSince(cursor)
                if seconds > 0 {
                    result[dayKey(dayStart, calendar: calendar), default: 0] += seconds
                }
                cursor = sliceEnd
            }
        }
        return result
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    // MARK: - File parsing

    private static func files(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            result.append(url)
        }
        return result
    }

    private static func lines(in url: URL) -> [Data.SubSequence] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return [] }
        return data.split(separator: 0x0A)
    }

    private static func parseISO(_ value: String) -> Date? {
        if let date = fractionalFormatter.date(from: value) { return date }
        return formatter.date(from: value)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let formatter = ISO8601DateFormatter()
}
