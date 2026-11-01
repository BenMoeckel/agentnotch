import Foundation

@main
struct TmuxIntegrationTests {
    static func main() throws {
        // Finder-launched apps need not inherit a UTF-8 terminal locale.
        let previousLocale = ProcessInfo.processInfo.environment["LC_ALL"]
        setenv("LC_ALL", "C", 1)
        defer {
            if let previousLocale { setenv("LC_ALL", previousLocale, 1) }
            else { unsetenv("LC_ALL") }
        }
        guard let executable = TmuxIntegration.executable else {
            print("SKIP: tmux integration (tmux is not installed)")
            return
        }
        let path = "/private/tmp/agentnotch-tmux-\(UUID().uuidString).sock"
        let created = LocalCommand.run(executable, ["-S", path, "-f", "/dev/null", "new-session", "-d", "-s", "fixture",
                                                    "-P", "-F", "#{pane_id}", "/bin/sh", "-c", "printf '92%% context left\\n'; sleep 30"])
        precondition(created.succeeded && created.output.hasPrefix("%"))
        let target = TmuxLocation(socketPath: path, paneID: created.output)
        defer { _ = TmuxIntegration.run(target, ["kill-server"]) }
        let deadline = Date().addingTimeInterval(3)
        var observation = TmuxIntegration.observe(target, kind: "codex")
        while observation.state == .unknown && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            observation = TmuxIntegration.observe(target, kind: "codex")
        }
        precondition(observation.state == .idle, "Read the actual pane's status without a GUI terminal")
        precondition(!observation.isVisible, "Detached panes cannot mark results read")
        precondition(TmuxIntegration.host(for: target, processes: [], applications: [], preferredPID: nil) == nil)
        precondition(TmuxIntegration.isSelected(target), "Pane selection must also work without a UTF-8 locale")
        let split = TmuxIntegration.run(target, ["split-window", "-t", target.paneID, "-P", "-F", "#{pane_id}", "/bin/sleep", "30"])
        precondition(split.succeeded && split.output != target.paneID)
        precondition(!TmuxIntegration.isSelected(target), "A different selected pane must not mark this session read")
        precondition(TmuxIntegration.run(target, ["select-pane", "-t", target.paneID]).succeeded)
        precondition(TmuxIntegration.isSelected(target))
        let missing = TmuxIntegration.observe(TmuxLocation(socketPath: path, paneID: "%999999"), kind: "codex")
        precondition(missing.state == .unknown, "A missing pane must not report completion")
        print("PASS: real isolated tmux pane capture, detached-session handling and stale-pane rejection")
    }
}
