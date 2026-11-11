import Combine
import Foundation

/// Selectable window for trend, agents and projects. Activity has its own year selection.
enum StatsRange: String, CaseIterable, Identifiable {
    case daily = "Daily"
    case month = "30 days"
    case quarter = "90 days"
    case year = "1 year"
    case allTime = "All time"

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .daily: 1
        case .month: 30
        case .quarter: 90
        case .year: 365
        case .allTime: nil
        }
    }

    var shortLabel: String {
        switch self {
        case .daily: "Daily"
        case .month: "30d"
        case .quarter: "90d"
        case .year: "1y"
        case .allTime: "All time"
        }
    }

    var granularity: StatsGranularity {
        switch self {
        case .daily, .month: .day
        case .quarter: .week
        case .year, .allTime: .month
        }
    }
}

enum StatsGranularity {
    case day, week, month

    func start(for date: Date, calendar: Calendar) -> Date {
        switch self {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start
                ?? calendar.startOfDay(for: date)
        }
    }
}

/// Fixed time thresholds keep heatmap colors comparable across days and
/// match the numeric legend in the dashboard.
enum StatsHeatmapScale {
    static let labels = ["0m", "<15m", "15–60m", "1–4h", "≥4h"]

    static func level(for seconds: Double) -> Int {
        switch seconds {
        case ...0: 0
        case ..<900: 1
        case ..<3600: 2
        case ..<14400: 3
        default: 4
        }
    }
}

/// Complete calendar weeks covering a year, including padding at both ends.
enum StatsActivityYear {
    static func columns(for year: Int, calendar: Calendar = .autoupdatingCurrent) -> [[Date]] {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(byAdding: .year, value: 1, to: start),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: start)?.start else { return [] }
        var columns: [[Date]] = []
        var week = firstWeek
        while week < end {
            columns.append((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week) })
            guard let next = calendar.date(byAdding: .day, value: 7, to: week) else { break }
            week = next
        }
        return columns
    }
}

struct UsageDay: Codable, Equatable {
    var totalSeconds: Double
    var agents: [String: Double]
    var projects: [String: Double]

    init(totalSeconds: Double = 0, agents: [String: Double] = [:], projects: [String: Double] = [:]) {
        self.totalSeconds = totalSeconds
        self.agents = agents
        self.projects = projects
    }

    enum CodingKeys: String, CodingKey {
        case totalSeconds, agents, projects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalSeconds = (try? container.decode(Double.self, forKey: .totalSeconds)) ?? 0
        agents = (try? container.decode([String: Double].self, forKey: .agents)) ?? [:]
        projects = (try? container.decode([String: Double].self, forKey: .projects)) ?? [:]
    }
}

struct UsageHistory: Codable, Equatable {
    var version: Int
    var days: [String: UsageDay]
    /// Marks how far local session logs have been imported. Zero means the
    /// historical import has not run yet.
    var backfillVersion: Int

    init(version: Int = 1, days: [String: UsageDay] = [:], backfillVersion: Int = 0) {
        self.version = version
        self.days = days
        self.backfillVersion = backfillVersion
    }

    enum CodingKeys: String, CodingKey {
        case version, days, backfillVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        days = (try? container.decode([String: UsageDay].self, forKey: .days)) ?? [:]
        backfillVersion = (try? container.decode(Int.self, forKey: .backfillVersion)) ?? 0
    }
}

struct TrendBucket: Identifiable, Equatable {
    let date: Date
    var values: [String: Double]

    var id: Date { date }
    var total: Double { values.values.reduce(0, +) }
}

/// Accumulates wall-clock time for active agent sessions and persists it as
/// one bucket per local calendar day. The tracker is intentionally independent
/// of SwiftUI so it can be covered by the command-line regression suite.
final class UsageTracker: ObservableObject {
    @Published private(set) var history: UsageHistory
    @Published private(set) var importingHistory = false

    private let fileURL: URL?
    private let calendar: Calendar
    private let now: () -> Date
    private let saveInterval: TimeInterval = 30
    private let backfillQueue = DispatchQueue(
        label: "com.benmoeckel.agentnotch.usage-backfill", qos: .utility
    )

    private var lastTick: Date?
    private var previousActive: [String: AgentInfo] = [:]
    private var dirty = false
    private var lastSave = Date.distantPast

    static var defaultFileURL: URL? {
        if let override = ProcessInfo.processInfo.environment["AGENTNOTCH_STATS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentNotch/usage.json")
    }

    init(fileURL: URL? = UsageTracker.defaultFileURL,
         calendar: Calendar = .autoupdatingCurrent,
         now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.calendar = calendar
        self.now = now
        self.history = Self.load(from: fileURL)
    }

    /// Feed the merged agent snapshot from every discovery poll. Time is only
    /// credited when the same session was already active on the previous poll,
    /// so newly appearing sessions do not invent a whole interval.
    func record(_ agents: [AgentInfo], at date: Date? = nil) {
        let timestamp = date ?? now()
        let current = Dictionary(
            agents.filter(Self.isActive).map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )

        defer {
            previousActive = current
            lastTick = timestamp
            if dirty && timestamp.timeIntervalSince(lastSave) >= saveInterval {
                flush()
            }
        }

        guard let lastTick else { return }
        // A laptop wake or a stalled poll must not create a multi-hour block.
        let delta = min(max(timestamp.timeIntervalSince(lastTick), 0), 15)
        guard delta > 0 else { return }

        let continuing = current.values.filter { previousActive[$0.id] != nil }
        guard !continuing.isEmpty else { return }

        let key = dayKey(for: timestamp)
        var day = history.days[key] ?? UsageDay()
        // Wall-clock work is counted once even when several sessions overlap.
        day.totalSeconds += delta

        // Per-agent and per-project time is also de-duplicated within that
        // dimension, so two Claude sessions still count as one hour of Claude.
        var kinds: Set<String> = []
        var projects: Set<String> = []
        for agent in continuing {
            kinds.insert(Self.agentKey(agent))
            if let project = Self.projectKey(agent.location?.workingDirectory) {
                projects.insert(project)
            }
        }
        for kind in kinds { day.agents[kind, default: 0] += delta }
        for project in projects { day.projects[project, default: 0] += delta }

        history.days[key] = day
        dirty = true
    }

    func flush() {
        guard dirty, let fileURL else {
            dirty = false
            return
        }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(history).write(to: fileURL, options: .atomic)
            dirty = false
            lastSave = now()
        } catch {
            // Keep the dirty flag and retry on the next interval.
        }
    }

    // MARK: - Queries

    /// Import off the discovery/UI queue. Only completed days are imported;
    /// live tracking remains the source of truth for today.
    func importLocalHistory() {
        guard !importingHistory, history.backfillVersion < UsageBackfill.version else { return }
        importingHistory = true
        let calendar = calendar
        let end = now()
        backfillQueue.async { [weak self] in
            let days = UsageBackfill.load(calendar: calendar, before: end)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mergeImportedHistory(days)
                self.importingHistory = false
            }
        }
    }

    /// Taking maxima preserves existing observations without counting the
    /// same work twice when an import overlaps previously tracked days.
    func mergeImportedHistory(_ days: [String: UsageDay]) {
        for (key, imported) in days {
            var day = history.days[key] ?? UsageDay()
            day.totalSeconds = max(day.totalSeconds, imported.totalSeconds)
            for (kind, seconds) in imported.agents {
                day.agents[kind] = max(day.agents[kind] ?? 0, seconds)
            }
            for (project, seconds) in imported.projects {
                day.projects[project] = max(day.projects[project] ?? 0, seconds)
            }
            history.days[key] = day
        }
        history.backfillVersion = UsageBackfill.version
        dirty = true
        flush()
    }

    func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func day(for date: Date) -> UsageDay? {
        history.days[dayKey(for: date)]
    }

    /// First day with recorded usage. Lets the dashboard explain that history
    /// only covers the time since this version started tracking.
    var trackingStart: Date? {
        history.days.keys.min().flatMap { key in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
    }

    /// Every day in the selected window, including empty days, so charts keep
    /// their correct time axis and gaps.
    func dayValues(in range: StatsRange, now: Date? = nil) -> [(date: Date, day: UsageDay)] {
        let end = calendar.startOfDay(for: now ?? self.now())
        let count = range.days ?? max(1, (calendar.dateComponents(
            [.day], from: trackingStart ?? end, to: end).day ?? 0) + 1)
        var result: [(date: Date, day: UsageDay)] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            guard let date = calendar.date(byAdding: .day, value: offset - (count - 1), to: end) else {
                continue
            }
            result.append((date, history.days[dayKey(for: date)] ?? UsageDay()))
        }
        return result
    }

    func totalSeconds(in range: StatsRange, now: Date? = nil) -> Double {
        dayValues(in: range, now: now).reduce(0) { $0 + $1.day.totalSeconds }
    }

    func agentTotals(in range: StatsRange, now: Date? = nil) -> [String: Double] {
        var totals: [String: Double] = [:]
        for (_, day) in dayValues(in: range, now: now) {
            for (kind, seconds) in day.agents where seconds > 0 {
                totals[kind, default: 0] += seconds
            }
        }
        return totals
    }

    func projectTotals(in range: StatsRange, now: Date? = nil) -> [String: Double] {
        var totals: [String: Double] = [:]
        for (_, day) in dayValues(in: range, now: now) {
            for (project, seconds) in day.projects where seconds > 0 {
                totals[project, default: 0] += seconds
            }
        }
        return totals
    }

    func activeDayCount(in range: StatsRange, now: Date? = nil) -> Int {
        dayValues(in: range, now: now).filter { $0.day.totalSeconds > 0.5 }.count
    }

    func busiestDay(in range: StatsRange, now: Date? = nil) -> (date: Date, day: UsageDay)? {
        dayValues(in: range, now: now)
            .filter { $0.day.totalSeconds > 0.5 }
            .max { $0.day.totalSeconds < $1.day.totalSeconds }
    }

    /// Consecutive active days ending today (or yesterday while today is still
    /// empty), matching the usual streak semantics.
    func currentStreak(now: Date? = nil) -> Int {
        let today = calendar.startOfDay(for: now ?? self.now())
        var cursor = today
        if (day(for: cursor)?.totalSeconds ?? 0) <= 0 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while (day(for: cursor)?.totalSeconds ?? 0) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    func trendBuckets(in range: StatsRange, topKinds: Set<String>, now: Date? = nil) -> [TrendBucket] {
        var grouped: [Date: [String: Double]] = [:]
        for (date, day) in dayValues(in: range, now: now) {
            let bucket = range.granularity.start(for: date, calendar: calendar)
            var values = grouped[bucket] ?? [:]
            for (kind, seconds) in day.agents where seconds > 0 {
                let key = topKinds.contains(kind) ? kind : "other"
                values[key, default: 0] += seconds
            }
            grouped[bucket] = values
        }
        return grouped.keys.sorted().map { TrendBucket(date: $0, values: grouped[$0] ?? [:]) }
    }

    // MARK: - Normalization

    static func isActive(_ agent: AgentInfo) -> Bool {
        // Blocked sessions are waiting for the user, not doing work. They stay
        // visible in the live "Now" card, but must not inflate work time.
        agent.state == .working
    }

    static func agentKey(_ agent: AgentInfo) -> String {
        let kind = agent.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !kind.isEmpty { return kind }
        let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.isEmpty ? "unknown" : name
    }

    /// The home directory and filesystem root are not projects. Storing the
    /// full path keeps two repositories with the same folder name apart.
    static func projectKey(_ directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        let path = URL(fileURLWithPath: directory).standardizedFileURL.path
        guard path != "/" else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard path != home else { return nil }
        return path
    }

    private static func load(from url: URL?) -> UsageHistory {
        guard let url,
              let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(UsageHistory.self, from: data) else {
            return UsageHistory()
        }
        return history
    }
}
