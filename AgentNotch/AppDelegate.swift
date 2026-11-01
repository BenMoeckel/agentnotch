import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchPanel: NotchPanel?
    private let placement = NotchPlacement()
    private var placementObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var placementRefresh: DispatchWorkItem?
    private let client = AgentClient.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        if CommandLine.arguments.contains("--check-agent-sessions") || CommandLine.arguments.contains("--focus-agent") {
            client.connect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
                func finish(_ error: String? = nil) {
                    let active = Set(client.activity.active.map(\.id))
                    let rows: [[String: Any]] = client.agents.map { agent -> [String: Any] in
                        let location = agent.location
                        let row: [String: Any] = [
                            "id": agent.id,
                            "kind": agent.kind,
                            "state": agent.state.rawValue,
                            "pid": location?.process?.pid ?? 0,
                            "active": active.contains(agent.id),
                            "session": location?.sessionID ?? "",
                            "editor": location?.editor != nil,
                            "terminalPID": location?.editor?.terminalPID ?? 0,
                            "focused": agent.isFocused,
                            "applicationPID": location?.applicationPID ?? 0,
                            "tty": location?.tty ?? "",
                            "surface": location?.ghosttySurfaceID ?? "",
                            "pane": location?.herdr?.paneID ?? ""
                        ]
                        return row
                    }
                    var report: [String: Any] = ["agents": rows, "sources": client.sourceDiagnostics,
                        "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                        "ghosttyAutomation": TerminalIntegration.mayRead(TerminalIntegration.ghostty)]
                    if let error { report["focusError"] = error }
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                        FileHandle.standardOutput.write(data)
                        FileHandle.standardOutput.write(Data("\n".utf8))
                    }
                    NSApp.terminate(nil)
                }
                if let index = CommandLine.arguments.firstIndex(of: "--focus-agent"),
                   CommandLine.arguments.indices.contains(index + 1) {
                    let target = CommandLine.arguments[index + 1]
                    guard let agent = client.agents.first(where: { $0.id == target || String($0.location?.process?.pid ?? 0) == target }) else {
                        finish("No matching live session."); return
                    }
                    client.focus(agent, completion: finish)
                } else { finish() }
            }
            return
        }
        if CommandLine.arguments.contains("--check-agent-windows") {
            DispatchQueue.global(qos: .userInitiated).async {
                let report = SessionNavigator.checkAgentWindows()
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        #endif
        setupNotchPanel()
        client.connect()
    }

    func applicationWillTerminate(_ notification: Notification) {
        placementRefresh?.cancel()
        placementObservers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        client.disconnect()
    }

    private func setupNotchPanel() {
        placement.geometry = NotchDetector.geometry()
        let panel = NotchPanel(frame: placement.geometry.frame)
        panel.setContent {
            NotchBarView(placement: placement) { [weak panel] size in
                // Resolve the current anchor when this queued layout runs.
                DispatchQueue.main.async { [weak panel] in
                    panel?.resize(to: size)
                }
            }
                .environmentObject(client)
        }
        panel.orderFrontRegardless()
        notchPanel = panel

        placementObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.schedulePlacementRefresh() })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.schedulePlacementRefresh() })
        }
    }

    private func refreshPlacement() {
        let geometry = NotchDetector.geometry()
        if placement.geometry != geometry { placement.geometry = geometry }
        notchPanel?.updateAnchor(geometry.frame)
    }

    private func schedulePlacementRefresh() {
        refreshPlacement()
        // macOS can finish restoring window positions after the notification.
        // Recheck once after that transition without continuously polling.
        placementRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPlacement() }
        placementRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
