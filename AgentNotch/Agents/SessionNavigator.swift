import AppKit
import ApplicationServices

enum SessionNavigator {
    static func applications() -> [HostApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
            HostApplication(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, bundlePath: $0.bundleURL?.path)
        }
    }

    /// Must run off the main queue; terminal automation has a bounded response timeout.
    static func focus(_ location: AgentLocation, applications: [HostApplication], frontmostPID: Int32?,
                      kind: String = "", terminalAlreadySelected: Bool = false) -> String? {
        if let process = location.process, ProcessDiscovery.identity(pid: process.pid) != process {
            return "This session is no longer available."
        }
        let host = location
        if host.editor != nil { return EditorBridge.focus(host, kind: kind) }
        if let tmux = location.tmux {
            guard let (resolved, session) = TmuxIntegration.host(for: tmux, processes: ProcessDiscovery.snapshot(),
                                                               applications: applications, preferredPID: frontmostPID),
                  let tty = resolved.tty else {
                return "This tmux session has no uniquely identifiable attached terminal."
            }
            if let error = TmuxIntegration.select(tmux, clientTTY: tty, sessionID: session) { return error }
            // tmux selected the exact pane; a terminal host only needs to come forward.
            if [TerminalIntegration.terminal, TerminalIntegration.iterm, TerminalIntegration.ghostty].contains(resolved.bundleID ?? "") {
                return TerminalIntegration.activate(resolved)
            }
            return focusWindow(resolved)
        }
        if [TerminalIntegration.terminal, TerminalIntegration.iterm, TerminalIntegration.ghostty].contains(host.bundleID ?? "") {
            return terminalAlreadySelected ? TerminalIntegration.activate(host) : TerminalIntegration.focus(host)
        }
        // Editor navigation uses existing windows and the latest location.
        // Never start an editor CLI to discover or select a window.
        return focusWindow(host)
    }

    static func matchingWindow(titles: [String], location: AgentLocation) -> Int? {
        if let title = location.windowTitle {
            let matches = titles.indices.filter { titles[$0] == title }
            return matches.count == 1 ? matches[0] : nil
        }
        if let cwd = location.workingDirectory, cwd != NSHomeDirectory(), cwd != "/" {
            let project = URL(fileURLWithPath: cwd).lastPathComponent.lowercased()
            let matches = titles.indices.filter {
                let title = titles[$0].lowercased()
                let pattern = "(?<![\\p{L}\\p{N}_-])" + NSRegularExpression.escapedPattern(for: project) + "(?![\\p{L}\\p{N}_-])"
                return title.contains(cwd.lowercased()) || title.range(of: pattern, options: .regularExpression) != nil
            }
            if matches.count == 1 { return matches[0] }
        }
        // A single application window is unambiguous only for non-terminal hosts.
        return location.tty == nil && titles.count == 1 ? 0 : nil
    }

    private static func focusWindow(_ location: AgentLocation) -> String? {
        guard let pid = location.applicationPID,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return "The session's application is no longer available."
        }
        guard AXIsProcessTrusted() else {
            app.activate(options: [])
            DispatchQueue.main.async {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return "Enable Accessibility access for AgentNotch to select the exact application window."
        }
        guard let (windows, titles) = applicationWindows(pid: pid) else { return "Could not find the session's window." }
        guard let index = matchingWindow(titles: titles, location: location) else {
            app.activate(options: [])
            return "The application was opened, but the exact session window could not be identified."
        }
        let window = windows[index]
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success,
              app.activate(options: []) else { return "Could not activate the session's window." }
        return nil
    }

    private static func applicationWindows(pid: Int32) -> ([AXUIElement], [String])? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        let titles = windows.map { window -> String in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return title as? String ?? ""
        }
        return (windows, titles)
    }

    /// Passive metadata lookup: never activate an application or prompt for access.
    static func windowTitles(pid: Int32) -> [String] {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return [] }
        return applicationWindows(pid: pid)?.1 ?? []
    }

    #if DEBUG
    /// Run from the installed bundle so this verifies the app's actual Accessibility grant.
    /// No windows are focused, moved or opened by this diagnostic.
    static func checkAgentWindows() -> [[String: Any]] {
        let applications = applications()
        let processes = ProcessDiscovery.snapshot()
        let agents = VSCodeIntegration().enrich(ProcessDiscovery.agents(in: processes, applications: applications),
                                               processes: processes, applications: applications)
        return agents.compactMap { agent in
            guard let location = agent.location, VSCodeIntegration.supports(location.bundleID),
                  let pid = location.applicationPID else { return nil }
            let titles = AXIsProcessTrusted() ? applicationWindows(pid: pid)?.1 ?? [] : []
            return ["agentPID": location.process?.pid ?? 0, "label": agent.title ?? agent.name,
                    "accessibilityTrusted": AXIsProcessTrusted(), "windowTitles": titles,
                    "matched": matchingWindow(titles: titles, location: location) != nil]
        }
    }
    #endif
}

/// The two macOS privacy permissions used while navigating to a session.
enum PermissionSettings {
    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case automation = "Privacy_Automation"

        var title: String {
            switch self {
            case .accessibility: return "Bedienungshilfen"
            case .automation: return "Automation"
            }
        }

        var url: URL {
            var bundle = "com.apple.preference.security"
            if #available(macOS 26.0, *) {
                bundle = "com.apple.settings.PrivacySecurity.extension"
            }
            return URL(string: "x-apple.systempreferences:\(bundle)?\(rawValue)")!
        }
    }

    static func open(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }
}
