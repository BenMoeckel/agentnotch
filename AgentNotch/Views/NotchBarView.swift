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

    private var panelSize: CGSize {
        guard isExpanded else { return layout.compactSize }
        return CGSize(width: max(layout.compactSize.width, 600),
                      height: 6 + 40 + 40 + CGFloat(rows) * rowHeight + 12 + (focusError == nil ? 0 : 40))
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
        }
        .onChange(of: panelSize, initial: true) { _, size in onSizeChange(size) }
        .onChange(of: layout.isEmpty) { _, empty in
            if empty {
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
            guard isExpanded else { return }
            isExpanded = false
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
            HStack(spacing: 8) {
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
                Spacer(minLength: 0)
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
            .padding(.horizontal, 16)
            .frame(height: 40)
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
        .padding(.top, 6)
        .padding(.bottom, 12)
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
                                    AgentRowView(agent: agent, completed: completed)
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
