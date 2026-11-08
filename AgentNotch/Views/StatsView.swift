import AppKit
import SwiftUI

/// The statistics dashboard shown inside the notch panel. The visual language
/// follows the reference design: black surface, rounded graphite cards, a
/// GitHub-style activity heatmap and stacked usage bars.
struct StatsView: View {
    @ObservedObject var tracker: UsageTracker
    let range: StatsRange

    private var now: Date { Date() }

    private var agentUsage: [AgentUsage] {
        tracker.agentTotals(in: range, now: now)
            .filter { $0.value > 0.5 }
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .enumerated()
            .map { index, item in
                AgentUsage(kind: item.key, seconds: item.value, color: StatsPalette.color(at: index))
            }
    }

    private var projectUsage: [ProjectUsage] {
        tracker.projectTotals(in: range, now: now)
            .filter { $0.value > 0.5 }
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .map { ProjectUsage(path: $0.key, seconds: $0.value) }
    }

    private var trendBuckets: [TrendBucket] {
        tracker.trendBuckets(in: range,
                             topKinds: Set(agentUsage.map(\.kind)),
                             now: now)
    }

    private var trendTotal: Double {
        trendBuckets.reduce(0) { $0 + $1.total }
    }

    private var agentColors: [String: Color] {
        var colors: [String: Color] = [:]
        for usage in agentUsage { colors[usage.kind] = usage.color }
        colors["other"] = StatsPalette.other
        return colors
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 12) {
                if tracker.importingHistory {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Importing local agent history…")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                }
                SummaryCard(tracker: tracker, range: range, now: now)
                ActivityCard(tracker: tracker, now: now)
                TrendCard(range: range, buckets: trendBuckets, total: trendTotal,
                          colors: agentColors, agents: agentUsage)
                HStack(alignment: .top, spacing: 12) {
                    AgentsCard(usage: agentUsage)
                    ProjectsCard(usage: projectUsage)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlayPreferenceValue(StatsHoverPreference.self) { info in
            GeometryReader { geometry in
                if let info {
                    let rect = geometry[info.anchor]
                    let width = min(280, geometry.size.width - 16)
                    Text(info.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineSpacing(4)
                        .padding(12)
                        .frame(width: width, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.14)))
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                        .offset(x: max(8, min(rect.midX - width / 2, geometry.size.width - width - 8)),
                                y: max(8, min(rect.maxY + 8, geometry.size.height - 180)))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct SummaryCard: View {
    @ObservedObject var tracker: UsageTracker
    let range: StatsRange
    let now: Date

    var body: some View {
        let total = tracker.totalSeconds(in: range, now: now)
        let activeDays = tracker.activeDayCount(in: range, now: now)
        HStack(spacing: 18) {
            metric("Working time", value: StatsFormat.duration(total))
            metric("Active days", value: "\(activeDays)")
            metric("Per active day", value: StatsFormat.duration(activeDays > 0 ? total / Double(activeDays) : 0))
        }
        .padding(18)
        .background(CardBackground())
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Activity

private struct ActivityCard: View {
    @ObservedObject var tracker: UsageTracker
    let now: Date

    private let weeks = 13
    private let cell: CGFloat = 14
    private let spacing: CGFloat = 4

    private var columns: [[HeatmapDay]] {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let firstWeek = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: currentWeek) ?? today
        return (0..<weeks).map { column in
            (0..<7).compactMap { row -> HeatmapDay? in
                guard let date = calendar.date(byAdding: .day, value: column * 7 + row, to: firstWeek) else {
                    return nil
                }
                guard date <= today else {
                    return HeatmapDay(date: date, value: nil)
                }
                let usage = tracker.day(for: date) ?? UsageDay()
                return HeatmapDay(date: date, value: usage.totalSeconds,
                                  details: StatsFormat.dayDetails(date, usage: usage))
            }
        }
    }

    private var days: [HeatmapDay] {
        columns.flatMap { $0 }
    }

    private var total: Double {
        days.compactMap(\.value).reduce(0, +)
    }

    private var activeDays: Int {
        days.compactMap(\.value).filter { $0 > 0.5 }.count
    }

    private var busiest: HeatmapDay? {
        days.filter { ($0.value ?? 0) > 0.5 }.max { ($0.value ?? 0) < ($1.value ?? 0) }
    }

    private var streak: Int {
        tracker.currentStreak(now: now)
    }

    private var trackingLabel: String? {
        guard let start = tracker.trackingStart,
              let firstDay = columns.first?.first?.date,
              start > firstDay else { return nil }
        return "since \(StatsFormat.shortDate(start))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                CardTitle(title: "Activity", systemImage: "square.grid.3x3.fill")
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("\(streak)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(streak > 0 ? Color.orange : Color.white.opacity(0.3))
                .accessibilityLabel("Aktuelle Streak: \(streak) Tage")
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .trailing, spacing: 10) {
                    Heatmap(columns: columns, cell: cell, spacing: spacing)
                    HStack(spacing: 5) {
                        ForEach(StatsPalette.heatmap.indices, id: \.self) { index in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(StatsPalette.heatmap[index])
                                    .frame(height: 8)
                                Text(StatsHeatmapScale.labels[index])
                                    .fixedSize()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                }
                .frame(width: CGFloat(weeks) * cell + CGFloat(weeks - 1) * spacing,
                       alignment: .topLeading)

                VStack(alignment: .leading, spacing: 4) {
                    Text(StatsFormat.duration(total))
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(trackingLabel.map { "\(weeks) weeks · \($0)" } ?? "\(weeks) weeks")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)

                    if total <= 0 {
                        Text("Local history is imported where available. Live usage is recorded while AgentNotch runs.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    StatRow(label: "Active days", value: "\(activeDays)")
                    StatRow(label: "Busiest day",
                            value: busiest.map {
                                "\(StatsFormat.shortDate($0.date)) · \(StatsFormat.duration($0.value ?? 0))"
                            } ?? "—")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .background(CardBackground())
    }
}

private struct HeatmapDay: Identifiable {
    let date: Date
    let value: Double?
    var details: String = ""
    var id: Date { date }
}

private struct Heatmap: View {
    let columns: [[HeatmapDay]]
    let cell: CGFloat
    let spacing: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(columns.indices, id: \.self) { index in
                VStack(spacing: spacing) {
                    ForEach(columns[index]) { day in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(for: day.value))
                            .frame(width: cell, height: cell)
                            .opacity(day.value == nil ? 0.3 : 1)
                            .statsHover(day.details)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aktivität der letzten 13 Wochen")
    }

    private func color(for value: Double?) -> Color {
        StatsPalette.heatmap[StatsHeatmapScale.level(for: value ?? 0)]
    }
}

// MARK: - Trend

private struct TrendCard: View {
    let range: StatsRange
    let buckets: [TrendBucket]
    let total: Double
    let colors: [String: Color]
    let agents: [AgentUsage]

    private var maxTotal: Double {
        buckets.map(\.total).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                CardTitle(title: "Trend", systemImage: "chart.bar.fill")
                Spacer(minLength: 0)
                Text("\(range.rawValue) · \(StatsFormat.duration(total))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            ZStack {
                if maxTotal <= 0 {
                    Text("No activity yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TrendChart(buckets: buckets, maxTotal: maxTotal, colors: colors,
                               granularity: range.granularity)
                }
            }
            .frame(height: 150)

            HStack(spacing: 0) {
                Text(label(at: 0))
                Spacer(minLength: 0)
                Text(label(at: buckets.count / 2))
                Spacer(minLength: 0)
                Text(label(at: max(0, buckets.count - 1)))
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.4))
            .monospacedDigit()

            if !agents.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(agents) { agent in
                        HStack(spacing: 5) {
                            Circle().fill(agent.color).frame(width: 6, height: 6)
                            Text(AgentLabel.name(for: agent.kind))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(CardBackground())
    }

    private func label(at index: Int) -> String {
        guard buckets.indices.contains(index) else { return "" }
        return StatsFormat.shortDate(buckets[index].date)
    }
}

private struct TrendChart: View {
    let buckets: [TrendBucket]
    let maxTotal: Double
    let colors: [String: Color]
    let granularity: StatsGranularity

    var body: some View {
        Canvas { context, size in
            let count = max(buckets.count, 1)
            let slot = size.width / CGFloat(count)
            let barWidth = max(2, slot * 0.62)
            let baselineY = size.height - 1

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: baselineY))
            baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
            context.stroke(baseline,
                           with: .color(.white.opacity(0.12)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            for (index, bucket) in buckets.enumerated() where bucket.total > 0 {
                let x = CGFloat(index) * slot + (slot - barWidth) / 2
                let keys = bucket.values.keys.sorted { lhs, rhs in
                    if lhs == "other" { return false }
                    if rhs == "other" { return true }
                    return lhs < rhs
                }
                var y = baselineY
                for key in keys {
                    guard let seconds = bucket.values[key], seconds > 0 else { continue }
                    let height = max(1, size.height * CGFloat(seconds / maxTotal))
                    let rect = CGRect(x: x, y: max(0, y - height), width: barWidth, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(2, barWidth / 2)),
                                 with: .color(colors[key] ?? StatsPalette.other))
                    y -= height
                }
            }
        }
        .overlay {
            HStack(spacing: 0) {
                ForEach(buckets) { bucket in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .statsHover(StatsFormat.bucketDetails(bucket, granularity: granularity))
                }
            }
        }
    }
}

// MARK: - Agents and projects

private struct AgentsCard: View {
    let usage: [AgentUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                CardTitle(title: "Agents", systemImage: "cpu")
                Spacer(minLength: 0)
                Text("\(usage.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
            }

            if usage.isEmpty {
                EmptyCardText("No agent activity yet")
            } else {
                VStack(spacing: 10) {
                    ForEach(usage) { item in
                        UsageRow(icon: .agent(item.kind), name: AgentLabel.name(for: item.kind),
                                 seconds: item.seconds, total: usageTotal, color: item.color)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(CardBackground())
    }

    private var usageTotal: Double {
        usage.reduce(0) { $0 + $1.seconds }
    }
}

private struct ProjectsCard: View {
    let usage: [ProjectUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                CardTitle(title: "Projects", systemImage: "folder.fill")
                Spacer(minLength: 0)
                Text("\(usage.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
            }

            if usage.isEmpty {
                EmptyCardText("No projects yet")
            } else {
                VStack(spacing: 10) {
                    ForEach(usage) { item in
                        UsageRow(icon: .project, name: item.name,
                                 seconds: item.seconds, total: usageTotal,
                                 color: .white.opacity(0.62))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(CardBackground())
    }

    private var usageTotal: Double {
        usage.reduce(0) { $0 + $1.seconds }
    }
}

private struct AgentUsage: Identifiable {
    let kind: String
    let seconds: Double
    let color: Color
    var id: String { kind }
}

private struct ProjectUsage: Identifiable {
    let path: String
    let seconds: Double
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

private enum UsageRowIcon {
    case agent(String)
    case project
}

private struct UsageRow: View {
    let icon: UsageRowIcon
    let name: String
    let seconds: Double
    let total: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 14, height: 14)

            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 76, alignment: .leading)

            UsageBar(progress: total > 0 ? seconds / total : 0, color: color)
                .frame(height: 4)

            Text(StatsFormat.duration(seconds))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .agent(let kind):
            AgentIcon(kind: kind, color: color, size: 14)
        case .project:
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

private struct UsageBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: CGFloat(max(0, min(1, progress))) * geometry.size.width)
            }
        }
    }
}

// MARK: - Shared pieces

private struct StatsHoverInfo {
    let anchor: Anchor<CGRect>
    let text: String
}

private struct StatsHoverPreference: PreferenceKey {
    static let defaultValue: StatsHoverInfo? = nil

    static func reduce(value: inout StatsHoverInfo?, nextValue: () -> StatsHoverInfo?) {
        if let next = nextValue() { value = next }
    }
}

private enum StatsHaptics {
    private static var lastPulse = Date.distantPast

    static func selection() {
        let now = Date()
        guard now.timeIntervalSince(lastPulse) >= 0.06 else { return }
        lastPulse = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

private struct StatsHover: ViewModifier {
    let text: String
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background {
                if hovering && !text.isEmpty {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white.opacity(0.06))
                }
            }
            .overlay {
                if hovering && !text.isEmpty {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.white.opacity(0.3), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .anchorPreference(key: StatsHoverPreference.self, value: .bounds) { anchor in
                hovering && !text.isEmpty ? StatsHoverInfo(anchor: anchor, text: text) : nil
            }
            .onHover { entered in
                if entered && !hovering && !text.isEmpty { StatsHaptics.selection() }
                hovering = entered
            }
            .onDisappear { hovering = false }
            .accessibilityHint(text)
    }
}

private extension View {
    func statsHover(_ text: String) -> some View {
        modifier(StatsHover(text: text))
    }
}

private struct CardTitle: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
    }
}

private struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.white.opacity(0.07))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.04), lineWidth: 1)
            }
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

private struct EmptyCardText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.35))
    }
}

private enum StatsPalette {
    static let heatmap: [Color] = [
        Color(white: 0.13),
        Color(red: 0.38, green: 0.16, blue: 0.05),
        Color(red: 0.65, green: 0.27, blue: 0.06),
        Color(red: 0.91, green: 0.43, blue: 0.10),
        Color(red: 1.00, green: 0.65, blue: 0.25)
    ]
    static let colors: [Color] = [
        Color(red: 0.49, green: 0.49, blue: 1.00),
        Color(red: 0.85, green: 0.47, blue: 0.30),
        Color(red: 0.37, green: 0.65, blue: 0.92),
        Color(red: 0.42, green: 0.76, blue: 0.58),
        Color(red: 0.78, green: 0.57, blue: 0.90),
        Color(red: 0.91, green: 0.73, blue: 0.35),
        Color(red: 0.35, green: 0.75, blue: 0.77),
        Color(red: 0.88, green: 0.48, blue: 0.63)
    ]
    static let other = Color.white.opacity(0.25)

    static func color(at index: Int) -> Color {
        colors[index % colors.count]
    }
}

private enum AgentLabel {
    private static let names: [String: String] = [
        "claude": "Claude", "claude-code": "Claude",
        "codex": "Codex", "opencode": "OpenCode",
        "gemini": "Gemini", "cursor": "Cursor",
        "copilot": "Copilot", "devin": "Devin",
        "grok": "Grok", "qwen": "Qwen", "kimi": "Kimi",
        "amp": "Amp", "cline": "Cline", "kilo": "Kilo",
        "maki": "Maki", "pi": "Pi", "glm": "GLM",
        "hermes": "Hermes", "omp": "OMP", "agy": "Agy",
        "kiro": "Kiro", "qodercli": "Qoder", "mastracode": "Mastra"
    ]

    static func name(for kind: String) -> String {
        let key = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let name = names[key] { return name }
        return key.isEmpty ? "Unknown" : key.capitalized
    }
}

private enum StatsFormat {
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        return formatter
    }()

    static func preciseDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 3600)h \((total % 3600) / 60)m \(total % 60)s"
    }

    private static func agentDetails(_ agents: [String: Double]) -> String {
        let sorted = agents.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        var rows = sorted.prefix(5).map { "\(AgentLabel.name(for: $0.key)): \(preciseDuration($0.value))" }
        if sorted.count > 5 { rows.append("+\(sorted.count - 5) more agents") }
        return rows.joined(separator: "\n")
    }

    static func dayDetails(_ date: Date, usage: UsageDay) -> String {
        var rows = [fullDateFormatter.string(from: date), "Working time: \(preciseDuration(usage.totalSeconds))"]
        if !usage.agents.isEmpty { rows.append(agentDetails(usage.agents)) }
        if !usage.projects.isEmpty { rows.append("\(usage.projects.count) projects") }
        return rows.joined(separator: "\n")
    }

    static func bucketDetails(_ bucket: TrendBucket, granularity: StatsGranularity) -> String {
        let prefix: String
        switch granularity {
        case .day: prefix = ""
        case .week: prefix = "Week of "
        case .month: prefix = "Month of "
        }
        var rows = [prefix + fullDateFormatter.string(from: bucket.date),
                    "Agent time: \(preciseDuration(bucket.total))"]
        if !bucket.values.isEmpty { rows.append(agentDetails(bucket.values)) }
        return rows.joined(separator: "\n")
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d. MMM"
        return formatter
    }()

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total > 0 else { return "0m" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            if hours >= 100 || minutes == 0 { return "\(hours)h" }
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    static func shortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }
}
