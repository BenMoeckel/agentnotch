import Foundation

@main
struct VSCodeIntegrationTests {
    static func process(_ pid: Int32, parent: Int32 = 1, start: String = "100.0", cwd: String = "/") -> SystemProcess {
        SystemProcess(identity: ProcessIdentity(pid: pid, startedAt: start), parentPID: parent,
                      executable: "codex", arguments: [], environment: [:], tty: nil, workingDirectory: cwd)
    }

    static func main() {
        let application = HostApplication(pid: 1662, bundleID: "com.microsoft.VSCode")
        let processes = [process(1662), process(2025, parent: 1662), process(2118, parent: 2025),
                         process(95917, parent: 1662), process(95925, parent: 95917, cwd: "/work/agentnotch")]
        let agents = ProcessDiscovery.agents(in: processes, applications: [application]).filter {
            [2118, 95925].contains($0.location!.process!.pid)
        }
        let root = agents.first { $0.location?.process?.pid == 2118 }!
        let project = agents.first { $0.location?.process?.pid == 95925 }!
        var titles = ["page.tsx — Bergidyll", "app.swift — agentnotch (Workspace)"]
        var reads = 0
        let editor = VSCodeIntegration(readWindowTitles: { pid in
            precondition(pid == application.pid)
            reads += 1
            return titles
        })
        let resolved = editor.enrich([root, project], processes: processes, applications: [application])
        precondition(reads == 1, "Polling reads existing windows once per editor without running its CLI")
        precondition(resolved[0] == root, "A backend with cwd '/' cannot be assigned to an arbitrary editor window")
        precondition(resolved[1].location?.windowTitle == titles[1])
        precondition(resolved[1].state == .unknown, "A visible editor window does not prove the backend is working")

        var explicit = root.location!
        explicit.windowTitle = titles[0]
        precondition(editor.resolve(explicit, processes: processes, applications: [application])?.windowTitle == titles[0],
                     "Lifecycle events can identify the exact window even when cwd is '/'")
        titles[1] = "README.md — agentnotch"
        precondition(editor.enrich([project], processes: processes, applications: [application])[0].location?.windowTitle == titles[1],
                     "Tab changes are read afresh without launching diagnostics")
        titles = ["project — Code", "project — Code"]
        explicit.windowTitle = titles[0]
        precondition(editor.resolve(explicit, processes: processes, applications: [application]) == nil,
                     "Duplicate native titles stay ambiguous")
        titles = ["project — Code"]
        precondition(editor.resolve(root.location!, processes: processes, applications: [application])?.windowTitle == titles[0],
                     "A single existing editor window is unambiguous")
        explicit.windowTitle = "closed — Code"
        precondition(editor.resolve(explicit, processes: processes, applications: [application]) == nil,
                     "An explicit missing target must not fall back to an unrelated window")
        titles = []
        precondition(editor.resolve(root.location!, processes: processes, applications: [application]) == nil,
                     "No windows or Accessibility access must never cause an editor launch")
        titles = [""]
        precondition(editor.resolve(root.location!, processes: processes, applications: [application]) == nil)

        let readsBeforeInvalidTargets = reads
        var stale = root.location!
        stale.process = ProcessIdentity(pid: 2118, startedAt: "101.0")
        precondition(editor.resolve(stale, processes: processes, applications: [application]) == nil)
        precondition(editor.resolve(root.location!, processes: [process(2118, parent: 77), process(77)], applications: [application]) == nil,
                     "A process owned by a different host must never select this editor")
        precondition(editor.resolve(root.location!, processes: processes, applications: []) == nil)
        var terminal = root.location!
        terminal.tty = "/dev/ttys001"
        precondition(editor.resolve(terminal, processes: processes, applications: [application]) == nil)
        precondition(reads == readsBeforeInvalidTargets, "Reject invalid targets before touching any application")
        print("PASS: passive VS Code window discovery, shared reads, title changes, explicit targets, ambiguity and stale-process rejection")
        if CommandLine.arguments.contains("--live") { checkLiveWindows() }
    }

    static func checkLiveWindows() {
        let apps = SessionNavigator.applications()
        let processes = ProcessDiscovery.snapshot()
        let agents = ProcessDiscovery.agents(in: processes, applications: apps).filter {
            VSCodeIntegration.supports($0.location?.bundleID) && $0.location?.tty == nil
        }
        let resolved = VSCodeIntegration().enrich(agents, processes: processes, applications: apps)
        for agent in resolved {
            print("LIVE: \(agent.location!.process!.pid) → \(agent.location?.windowTitle ?? "no unambiguous window")")
        }
    }
}
