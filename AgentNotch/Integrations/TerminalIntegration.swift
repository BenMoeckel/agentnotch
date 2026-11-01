import AppKit
import Carbon

struct TerminalObservation {
    var state: AgentState = .unknown
    var isVisible = false
}

enum TerminalState {
    /// Only explicit UI markers count. Silence, CPU usage and process exit never imply completion.
    static func detect(_ text: String, kind: String) -> AgentState {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let footer = lines.suffix(12).joined(separator: "\n").lowercased()
        let approvals = ["do you want to proceed?", "would you like to run the following command?",
                         "allow this action?", "allow once", "approve once", "waiting for your approval",
                         "do you trust the files in this folder?", "yes, allow", "enter to confirm · esc to cancel"]
        if approvals.contains(where: footer.contains) { return .blocked }
        if ["esc to interrupt", "esc to cancel", "escape to interrupt", "ctrl+c to interrupt"].contains(where: footer.contains) {
            return .working
        }
        switch kind {
        case "claude":
            if footer.contains("? for shortcuts") { return .idle }
        case "codex":
            if footer.contains("context left") || footer.contains("? for shortcuts") { return .idle }
        case "gemini":
            if footer.contains("type your message") { return .idle }
        default: break
        }
        return .unknown
    }
}

enum TerminalIntegration {
    static let terminal = "com.apple.Terminal"
    static let iterm = "com.googlecode.iterm2"
    static let ghostty = "com.mitchellh.ghostty"
    static let automationError = "Could not select the terminal session. Check Automation access for AgentNotch in System Settings."

    static func ghosttyVisible(_ output: String, surfaceID: String?, tty: String?) -> Bool {
        let fields = output.components(separatedBy: "\u{1e}")
        guard fields.count == 3, !fields[0].isEmpty, let count = Int(fields[2]), count > 0 else { return false }
        // Ghostty 1.4 exposes a terminal UUID through AppleScript while the
        // process environment carries a hex surface ID. Match the exact TTY as
        // well so an open session is still recognised across both formats.
        if let surfaceID, fields[0] == surfaceID { return true }
        if let tty, !tty.isEmpty, fields[1] == tty { return true }
        // Older installations may not export either identifier. A single
        // existing surface is unambiguous; multiple surfaces require an exact match.
        return surfaceID == nil && tty == nil && count == 1
    }

    static func mayRead(_ bundleID: String) -> Bool {
        // Polling must never trigger an Automation permission prompt.
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr
    }

    static func observe(_ location: AgentLocation, kind: String, frontmostPID: Int32?) -> TerminalObservation {
        if location.bundleID == ghostty,
           location.applicationPID == frontmostPID, mayRead(ghostty) {
            let result = LocalCommand.appleScript("""
                tell application id "com.mitchellh.ghostty"
                    set focusedTerminal to focused terminal of selected tab of front window
                    return (id of focusedTerminal) & (ASCII character 30) & (tty of focusedTerminal) & (ASCII character 30) & ((count of terminals) as text)
                end tell
                """)
            return TerminalObservation(isVisible: result.succeeded && ghosttyVisible(
                result.output, surfaceID: location.ghosttySurfaceID, tty: location.tty))
        }
        guard let bundle = location.bundleID, let tty = location.tty,
              [terminal, iterm].contains(bundle), mayRead(bundle) else { return TerminalObservation() }
        let result = LocalCommand.appleScript(script(bundleID: bundle, tty: tty, focus: false))
        guard result.succeeded else { return TerminalObservation() }
        let fields = result.output.components(separatedBy: "\u{1e}")
        guard fields.count == 2 else { return TerminalObservation() }
        return TerminalObservation(state: TerminalState.detect(fields[0], kind: kind),
                                   isVisible: fields[1] == "true" && location.applicationPID == frontmostPID)
    }

    /// The terminal surface is already selected by Herdr or tmux. Only bring
    /// its host application forward; selecting by working directory would fail
    /// for Ghostty 1.3, which reports the same initial directory for every tab.
    static func activate(_ location: AgentLocation) -> String? {
        guard let pid = location.applicationPID,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return "The session's terminal application is no longer available."
        }
        return app.activate(options: [.activateAllWindows]) ? nil : "Could not activate the session's terminal."
    }

    static func focus(_ location: AgentLocation) -> String? {
        guard let bundle = location.bundleID else { return "The session's application is no longer available." }
        let source: String
        if [terminal, iterm].contains(bundle), let tty = location.tty {
            source = script(bundleID: bundle, tty: tty, focus: true)
        } else if bundle == ghostty {
            let selection: String
            if let surface = location.ghosttySurfaceID {
                selection = "set matches to every terminal whose id is \(LocalCommand.appleScriptLiteral(surface))"
            } else if let cwd = location.workingDirectory {
                selection = """
                    set matches to every terminal whose working directory is \(LocalCommand.appleScriptLiteral(cwd))
                    if (count of matches) is not 1 and (count of terminals) is 1 then set matches to terminals
                    """
            } else {
                selection = "set matches to terminals"
            }
            source = """
            tell application id "com.mitchellh.ghostty"
                \(selection)
                if (count of matches) is not 1 then error "Session not uniquely identifiable"
                focus (item 1 of matches)
                activate
                return "ok"
            end tell
            """
        } else { return "This terminal does not expose an exact session target." }
        let result = LocalCommand.appleScript(source, timeout: 30)
        if result.succeeded && result.output == "ok" { return nil }
        // Ghostty 1.3 exposes neither a surface ID nor the live TTY to
        // AppleScript; its working-directory property stays at the launch
        // directory. Once permission is granted, at least bring Ghostty forward.
        if bundle == ghostty, mayRead(bundle) { return activate(location) }
        return automationError
    }

    static func script(bundleID: String, tty: String, focus: Bool) -> String {
        let target = LocalCommand.appleScriptLiteral(tty)
        if bundleID == terminal {
            let action = focus ? """
                set selected of t to true
                set miniaturized of w to false
                set index of w to 1
                activate
                return "ok"
                """ : "return (contents of t) & (ASCII character 30) & ((selected of t and index of w is 1 and not miniaturized of w) as text)"
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(target) then
                            \(action)
                        end if
                    end repeat
                end repeat
                error "Session not found"
            end tell
            """
        }
        let action = focus ? """
            select t
            select s
            set miniaturized of w to false
            select w
            activate
            return "ok"
            """ : "return (contents of s) & (ASCII character 30) & (((id of current window is id of w) and (id of current session of w is id of s) and not miniaturized of w) as text)"
        return """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is \(target) then
                            \(action)
                        end if
                    end repeat
                end repeat
            end repeat
            error "Session not found"
        end tell
        """
    }
}
