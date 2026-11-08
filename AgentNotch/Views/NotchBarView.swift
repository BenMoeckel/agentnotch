import AppKit
import ServiceManagement
import SwiftUI

struct NotchBarView: View {
    @EnvironmentObject var client: AgentClient
    @ObservedObject var placement: NotchPlacement
    private var compactSize: CGSize { placement.geometry.frame.size }
    private var cameraWidth: CGFloat { placement.geometry.cameraWidth }
    let onSizeChange: (CGSize) -> Void
    @State private var isExpanded = false
    @State private var showStats = false
    @State private var statsRange: StatsRange = .month
    @State private var menuTracking = false
    @State private var rangeDropdownOpen = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var focusError: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let rowHeight: CGFloat = 52
    private let visibleRows = 6
    private var active: [AgentInfo] { client.activity.active }
    private var results: [AgentInfo] { client.activity.results }
    private var rows: Int { max(1, min(max(active.count, results.count), visibleRows)) }
    private var layout: NotchLayout {
        NotchLayout(activeCount: active.count, resultCount: results.count,
                    cameraWidth: cameraWidth, height: compactSize.height)
    }

    /// Statistics keep the session panel's width but extend down the display.
    private var expandedSize: CGSize {
        let screen = NSScreen.screens.first { $0.frame.contains(placement.geometry.frame.origin) }
        let availableHeight = screen.map { placement.geometry.frame.maxY - $0.visibleFrame.minY - 16 } ?? 740
        return CGSize(width: max(layout.compactSize.width, 600),
               height: showStats ? min(740, availableHeight)
                   : 6 + 40 + 40 + CGFloat(rows) * rowHeight + 12)
    }

    private var panelSize: CGSize {
        guard isExpanded else { return layout.compactSize }
        guard !showStats, focusError != nil else { return expandedSize }
        return CGSize(width: expandedSize.width, height: expandedSize.height + 40)
    }

    var body: some View {
        Group {
            if isExpanded { expandedContent }
            else { compactContent }
        }
        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
        .background(Color.black)
        .clipShape(NotchShape(cornerRadius: isExpanded ? 16 : 10))
        .contentShape(Rectangle())
        .onHover(perform: handleHover)
        .onDisappear {
            cancelHoverExpansion()
            isExpanded = false
            showStats = false
            rangeDropdownOpen = false
        }
        .onChange(of: panelSize, initial: true) { _, size in onSizeChange(size) }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            menuTracking = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuTracking = false
            let frame = NSRect(x: placement.geometry.frame.midX - panelSize.width / 2,
                               y: placement.geometry.frame.maxY - panelSize.height,
                               width: panelSize.width, height: panelSize.height)
            if !frame.contains(NSEvent.mouseLocation) { handleHover(false) }
        }
        .onChange(of: layout.isEmpty) { _, empty in
            if empty && !showStats {
                cancelHoverExpansion()
                isExpanded = false
            }
        }
        .contextMenu {
            Button("Quit AgentNotch") { NSApp.terminate(nil) }
        }
    }

    private func handleHover(_ hovering: Bool) {
        cancelHoverExpansion()
        guard hovering else {
            guard !menuTracking else { return }
            guard isExpanded else { return }
            // SwiftUI can emit an exit while rebuilding content under the
            // pointer. Only a real exit from the panel should collapse it.
            let frame = NSRect(x: placement.geometry.frame.midX - panelSize.width / 2,
                               y: placement.geometry.frame.maxY - panelSize.height,
                               width: panelSize.width, height: panelSize.height)
            guard !frame.contains(NSEvent.mouseLocation) else { return }
            isExpanded = false
            showStats = false
            rangeDropdownOpen = false
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            return
        }
        guard !isExpanded else { return }
        hoverTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            isExpanded = true
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            hoverTask = nil
        }
    }

    private func cancelHoverExpansion() {
        hoverTask?.cancel()
        hoverTask = nil
    }

    private var compactContent: some View {
        return HStack(spacing: 0) {
            compactGroup(active, completed: false)
                .frame(width: layout.sideWidth)
            // Leave the physical camera completely free of content.
            Color.clear.frame(width: layout.gap)
            compactGroup(results, completed: true)
                .frame(width: layout.sideWidth)
        }
        .frame(height: compactSize.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(active.count) active, \(active.filter { $0.state == .blocked }.count) need attention, \(results.count) new results")
    }

    private func compactGroup(_ agents: [AgentInfo], completed: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(agents.prefix(NotchLayout.iconLimit)) { agent in
                Button { openSession(agent, completed: completed) } label: {
                    AgentIcon(kind: agent.kind, color: agent.state.color, size: 14)
                        .overlay(alignment: .topTrailing) {
                            if completed || agent.state == .blocked {
                                Image(systemName: completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white, completed ? Color.green : Color.red)
                                    .background(Circle().fill(.black))
                                    .offset(x: 5, y: -5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open session: \(agent.title ?? agent.name)")
                .help("Open session: \(agent.title ?? agent.name)")
            }
            if agents.count > NotchLayout.iconLimit {
                Text("+\(agents.count - NotchLayout.iconLimit)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            expandedHeader
                .zIndex(1)
            if showStats {
                StatsView(tracker: client.usage, range: statsRange)
                    .overlay {
                        if rangeDropdownOpen {
                            Color.black.opacity(0.001)
                                .onTapGesture { rangeDropdownOpen = false }
                        }
                    }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    column(active, title: "Active · \(active.count)", completed: false)
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 1)
                    column(results, title: "New results · \(results.count)", completed: true)
                }
                // Keep errors below the camera/notch and all conversation rows.
                if let focusError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(focusError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .help(focusError)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            permissionButton(.accessibility)
                            permissionButton(.automation)
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private var expandedHeader: some View {
        HStack(spacing: 8) {
            if showStats {
                Button {
                    rangeDropdownOpen = false
                    showStats = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Zurück zu den Sessions")
                .accessibilityLabel("Zurück zu den Sessions")

                Text("Statistics")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                rangeSelector
            } else {
                autostartToggle
            }
            Spacer(minLength: 0)
            if !showStats {
                statsButton
            }
            powerButton
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private var autostartToggle: some View {
        Toggle(isOn: $launchAtLogin) {
            Text("Autostart")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
        }
        .toggleStyle(.switch)
        .tint(.accentColor)
        .controlSize(.mini)
        .fixedSize()
        .help("AgentNotch beim Login automatisch starten")
        .accessibilityLabel("Beim Login starten")
        .onChange(of: launchAtLogin) { _, newValue in
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private var statsButton: some View {
        Button { showStats = true } label: {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Statistik anzeigen")
        .accessibilityLabel("Statistik anzeigen")
    }

    private var rangeSelector: some View {
        Button { rangeDropdownOpen.toggle() } label: {
            HStack(spacing: 8) {
                Text(statsRange.rawValue)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Zeitraum: \(statsRange.rawValue)")
        .accessibilityValue(rangeDropdownOpen ? "Expanded" : "Collapsed")
        .overlay(alignment: .topLeading) {
            if rangeDropdownOpen {
                VStack(spacing: 2) {
                    ForEach(StatsRange.allCases) { range in
                        Button {
                            statsRange = range
                            rangeDropdownOpen = false
                        } label: {
                            HStack {
                                Text(range.rawValue)
                                Spacer()
                                if statsRange == range {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(statsRange == range ? Color.white.opacity(0.08) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(5)
                .frame(width: 150)
                .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                .offset(y: 30)
            }
        }
    }

    private var powerButton: some View {
        Button { NSApp.terminate(nil) } label: {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help("AgentNotch beenden")
        .accessibilityLabel("AgentNotch beenden")
    }

    private func column(_ agents: [AgentInfo], title: String, completed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            if agents.isEmpty {
                Text(completed ? "No new results" : "No active agents")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: CGFloat(rows) * rowHeight)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(agents) { agent in
                            ZStack(alignment: .topTrailing) {
                                Button { openSession(agent, completed: completed) } label: {
                                    AgentRowView(agent: agent, completed: completed,
                                                 workingSince: client.activity.workingSince[agent.id])
                                        .frame(height: rowHeight)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open session: \(agent.title ?? agent.name)")
                                .help("Open session: \(agent.title ?? agent.name)")

                                if completed {
                                    Button { dismiss(agent) } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.7))
                                            .frame(width: 18, height: 18)
                                            .background(.white.opacity(0.10), in: Circle())
                                            .frame(width: 26, height: 26)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 2)
                                    .padding(.trailing, 4)
                                    .help("Ergebnis ausblenden")
                                    .accessibilityLabel("Ergebnis ausblenden: \(agent.title ?? agent.name)")
                                }
                            }
                        }
                    }
                }
                .frame(height: CGFloat(rows) * rowHeight)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func openSession(_ agent: AgentInfo, completed: Bool) {
        cancelHoverExpansion()
        let token = completed ? client.activity.completions[agent.id] : nil
        focusError = nil
        client.focus(agent) { error in
            focusError = error
            guard error == nil else {
                isExpanded = true
                return
            }
            if let token { client.acknowledge([agent.id: token]) }
            isExpanded = false
        }
    }

    private func dismiss(_ agent: AgentInfo) {
        client.dismiss(agent)
    }

    private func permissionButton(_ pane: PermissionSettings.Pane) -> some View {
        Button { PermissionSettings.open(pane) } label: {
            Label(pane.title, systemImage: "gearshape")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("\(pane.title) in den Systemeinstellungen öffnen")
        .accessibilityLabel("\(pane.title) in den Systemeinstellungen öffnen")
    }
}
