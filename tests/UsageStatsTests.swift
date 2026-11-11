import Foundation
import SQLite3

@main
struct UsageStatsTests {
    static func agent(_ kind: String, state: AgentState = .working, id: String = "a",
                      cwd: String? = "/work/alpha", name: String? = nil) -> AgentInfo {
        AgentInfo(id: id, name: name ?? kind, kind: kind, state: state,
                  location: cwd.map { AgentLocation(workingDirectory: $0) })
    }

    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Calendar-year heatmaps cover every day once, including leap days and
        // years spanning 54 calendar weeks, regardless of the first weekday.
        for firstWeekday in [1, 2] {
            var heatmapCalendar = calendar
            heatmapCalendar.firstWeekday = firstWeekday
            for year in [2012, 2024, 2026] {
                let columns = StatsActivityYear.columns(for: year, calendar: heatmapCalendar)
                let days = columns.flatMap { $0 }.filter {
                    heatmapCalendar.component(.year, from: $0) == year
                }
                precondition(columns.allSatisfy { $0.count == 7 })
                precondition(days.count == (year == 2026 ? 365 : 366))
                precondition(Set(days).count == days.count)
                precondition(heatmapCalendar.component(.day, from: days.first!) == 1)
                precondition(heatmapCalendar.component(.month, from: days.last!) == 12)
                precondition(heatmapCalendar.component(.day, from: days.last!) == 31)
                precondition(heatmapCalendar.component(.weekday, from: columns[0][0]) == firstWeekday)
            }
        }

        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let tracker = UsageTracker(fileURL: url, calendar: calendar)
        let claude = agent("claude", cwd: "/work/alpha")
        let codex = agent("codex", id: "b", cwd: "/work/beta")

        // First observation is a baseline; the next poll credits the interval.
        tracker.record([claude], at: base)
        tracker.record([claude], at: base.addingTimeInterval(10))
        var day = tracker.day(for: base)
        precondition(abs((day?.totalSeconds ?? 0) - 10) < 0.01,
                     "Active wall-clock time must be tracked")
        precondition(abs((day?.agents["claude"] ?? 0) - 10) < 0.01,
                     "Agent time must be tracked")
        precondition(abs((day?.projects["/work/alpha"] ?? 0) - 10) < 0.01,
                     "Project time must be tracked")

        // Idle sessions do not add time.
        tracker.record([agent("claude", state: .idle, cwd: "/work/alpha")],
                       at: base.addingTimeInterval(20))
        day = tracker.day(for: base)
        precondition(abs((day?.totalSeconds ?? 0) - 10) < 0.01,
                     "Idle sessions must not count as work")

        // Two parallel sessions: wall clock once, each agent and project once.
        tracker.record([claude, codex], at: base.addingTimeInterval(30))
        tracker.record([claude, codex], at: base.addingTimeInterval(40))
        day = tracker.day(for: base)
        precondition(abs((day?.totalSeconds ?? 0) - 20) < 0.01,
                     "Overlapping sessions must not double-count wall-clock time")
        precondition(abs((day?.agents["claude"] ?? 0) - 20) < 0.01,
                     "Claude must accumulate its own interval")
        precondition(abs((day?.agents["codex"] ?? 0) - 10) < 0.01,
                     "Codex must accumulate its own interval")
        precondition(abs((day?.projects["/work/alpha"] ?? 0) - 20) < 0.01,
                     "Project alpha must accumulate its own interval")
        precondition(abs((day?.projects["/work/beta"] ?? 0) - 10) < 0.01,
                     "Project beta must accumulate its own interval")

        // A new local day is a separate bucket and continues the streak.
        let nextDay = calendar.date(byAdding: .day, value: 1, to: base)!
        tracker.record([], at: nextDay.addingTimeInterval(-1))
        tracker.record([claude], at: nextDay)
        tracker.record([claude], at: nextDay.addingTimeInterval(5))
        precondition(tracker.currentStreak(now: nextDay) == 2,
                     "Two consecutive active days must form a streak")
        precondition(tracker.activeDayCount(in: .month, now: nextDay) == 2,
                     "Active day count must include both buckets")

        // Trend buckets keep empty days so the time axis stays honest.
        let buckets = tracker.trendBuckets(in: .month, topKinds: ["claude"], now: nextDay)
        precondition(buckets.count == 30, "A 30-day range must yield 30 daily buckets")
        precondition(abs(buckets.reduce(0) { $0 + $1.total } - 35) < 0.01,
                     "Trend must sum agent usage across the window")
        precondition(buckets.contains { $0.values["claude"] != nil },
                     "Trend must attribute time to the agent")

        // Persistence round-trip.
        tracker.flush()
        let restored = UsageTracker(fileURL: url, calendar: calendar)
        precondition(abs(restored.totalSeconds(in: .month, now: nextDay) - 25) < 0.01,
                     "History must survive a restart")
        precondition(abs((restored.agentTotals(in: .month, now: nextDay)["claude"] ?? 0) - 25) < 0.01,
                     "Agent totals must survive a restart")
        precondition(abs((restored.projectTotals(in: .month, now: nextDay)["/work/alpha"] ?? 0) - 25) < 0.01,
                     "Project totals must survive a restart")

        // Normalization helpers.
        precondition(UsageTracker.projectKey("/") == nil, "Root is not a project")
        precondition(UsageTracker.projectKey(NSHomeDirectory()) == nil, "Home is not a project")
        precondition(UsageTracker.agentKey(agent("", name: "Claude")) == "claude",
                     "Agents without a kind fall back to their name")
        precondition(!UsageTracker.isActive(agent("claude", state: .blocked)),
                     "Blocked sessions are waiting, not working")

        try checkBackfill(calendar: calendar, now: base)
        checkAllTime(calendar: calendar, now: base)
        for (seconds, expected) in [(0.0, 0), (1, 1), (899, 1), (900, 2), (3599, 2),
                                    (3600, 3), (14399, 3), (14400, 4), (86400, 4)] {
            precondition(StatsHeatmapScale.level(for: seconds) == expected,
                         "Heatmap colors must match the numeric time thresholds")
        }
        print("PASS: usage tracking, parallel sessions, day buckets, streak, trend, persistence and historical import")
    }

    static func checkAllTime(calendar: Calendar, now: Date) {
        let tracker = UsageTracker(fileURL: nil, calendar: calendar)
        let old = calendar.date(byAdding: .day, value: -800, to: now)!
        let future = calendar.date(byAdding: .day, value: 1, to: now)!
        tracker.mergeImportedHistory([
            tracker.dayKey(for: old): UsageDay(totalSeconds: 10, agents: ["claude": 10], projects: ["/work/old": 10]),
            tracker.dayKey(for: now): UsageDay(totalSeconds: 20, agents: ["codex": 20]),
            tracker.dayKey(for: future): UsageDay(totalSeconds: 100, agents: ["gemini": 100])
        ])
        precondition(tracker.totalSeconds(in: .allTime, now: now) == 30,
                     "All time must include history older than a year and exclude future days")
        precondition(tracker.totalSeconds(in: .year, now: now) == 20,
                     "Fixed windows must still exclude older history")
        precondition(tracker.dayValues(in: .allTime, now: now).count == 801,
                     "All time must preserve empty days from the first record through today")
        precondition(tracker.activeDayCount(in: .allTime, now: now) == 2)
        precondition(tracker.projectTotals(in: .allTime, now: now)["/work/old"] == 10)
        let buckets = tracker.trendBuckets(in: .allTime, topKinds: ["claude", "codex"], now: now)
        precondition(buckets.count > 24 && buckets.reduce(0) { $0 + $1.total } == 30,
                     "All-time trends must span multiple years in monthly buckets")
        let empty = UsageTracker(fileURL: nil, calendar: calendar)
        precondition(empty.dayValues(in: .allTime, now: now).count == 1,
                     "An empty all-time range must remain bounded to today")
    }

    static func checkBackfill(calendar: Calendar, now: Date) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentnotch-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let day = calendar.date(byAdding: .day, value: -1, to: now)!
        let formatter = ISO8601DateFormatter()

        func writeLog(_ path: String, entries: [[String: Any]]) throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for entry in entries {
                // JSONSerialization inserts whitespace, unlike compact rollouts.
                data.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
                data.append(0x0A)
            }
            try data.write(to: url)
        }

        let project = "/work/über project"
        try writeLog(".claude/projects/example/session.jsonl", entries: [
            ["timestamp": formatter.string(from: day), "cwd": project],
            ["timestamp": formatter.string(from: day.addingTimeInterval(300)), "cwd": project],
            ["timestamp": formatter.string(from: now), "cwd": project],
            ["timestamp": formatter.string(from: now.addingTimeInterval(60)), "cwd": project]
        ])
        try writeLog(".codex/archived_sessions/session.jsonl", entries: [
            ["timestamp": formatter.string(from: day), "type": "session_meta", "payload": ["cwd": project]],
            ["timestamp": formatter.string(from: day.addingTimeInterval(120)), "type": "event_msg",
             "payload": ["type": "task_started"]],
            ["timestamp": formatter.string(from: day.addingTimeInterval(420)), "type": "event_msg",
             "payload": ["type": "task_complete"]]
        ])

        let database = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        precondition(sqlite3_open(database.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let epoch = Int64(day.timeIntervalSince1970 * 1000)
        let sql = """
        CREATE TABLE session (id TEXT, directory TEXT);
        CREATE TABLE message (session_id TEXT, time_created INTEGER);
        INSERT INTO session VALUES ('a', '/work/open'), ('b', '/work/open');
        INSERT INTO message VALUES ('a', \(epoch + 600000)), ('a', \(epoch + 660000)), ('b', \(epoch + 900000));
        """
        precondition(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)

        let days = UsageBackfill.load(calendar: calendar, before: now, home: home)
        let tracker = UsageTracker(fileURL: home.appendingPathComponent("usage.json"), calendar: calendar)
        let key = tracker.dayKey(for: day)
        precondition(days.count == 1, "Import must exclude today and long idle gaps")
        precondition(days[key]?.agents["claude"] == 300, "Claude history must parse whitespace and Unicode paths")
        precondition(days[key]?.agents["codex"] == 300, "Codex task boundaries must be imported")
        precondition(days[key]?.agents["opencode"] == 60, "Separate OpenCode sessions must not be bridged")
        precondition(days[key]?.totalSeconds == 480, "Overlapping historical agents must count wall-clock time once")
        precondition(days[key]?.projects[project] == 420, "Project intervals must be deduplicated")

        tracker.record([agent("gemini")], at: day)
        tracker.record([agent("gemini")], at: day.addingTimeInterval(10))
        tracker.mergeImportedHistory(days)
        tracker.mergeImportedHistory(days)
        precondition(tracker.day(for: day)?.agents["gemini"] == 10, "Import must preserve other agents' live history")
        precondition(tracker.day(for: day)?.totalSeconds == 480, "Repeated imports must not double-count history")
        let restored = UsageTracker(fileURL: home.appendingPathComponent("usage.json"), calendar: calendar)
        precondition(restored.history.backfillVersion == UsageBackfill.version, "Import completion must persist")
        precondition(restored.agentTotals(in: .month, now: now).count == 4, "All imported and live agent kinds must be available")

        let old = calendar.date(byAdding: .day, value: -800, to: now)!
        try writeLog(".claude/projects/example/old-session.jsonl", entries: [
            ["timestamp": formatter.string(from: old), "cwd": project],
            ["timestamp": formatter.string(from: old.addingTimeInterval(60)), "cwd": project]
        ])
        let extended = UsageBackfill.load(calendar: calendar, before: now, home: home)
        precondition(extended[tracker.dayKey(for: old)]?.agents["claude"] == 60,
                     "All-time import must include local logs older than a year")
    }
}
