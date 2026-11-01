import Foundation

@main
struct LiveDiscoveryTests {
    static func main() throws {
        // A harmless local process fixture exercises real sysctl/argv/identity discovery.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        let child = Process()
        child.executableURL = executable
        child.arguments = ["30"]
        child.environment = ["PATH": "/usr/bin:/bin"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let identity = ProcessDiscovery.identity(pid: child.processIdentifier)
        precondition(identity != nil)
        let processes = ProcessDiscovery.snapshot()
        let agents = ProcessDiscovery.agents(in: processes, applications: [])
        if !agents.contains(where: { $0.location?.process == identity }) {
            let fixture = processes.first { $0.identity.pid == child.processIdentifier }
            let diagnostic = "Fixture discovery failed: total=\(processes.count), fixture=\(String(describing: fixture)), identity=\(String(describing: identity))\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
        }
        precondition(agents.contains { $0.location?.process == identity && $0.kind == "codex" },
                     "The real process scanner must detect a running agent without any Herdr RPC")
        child.terminate()
        child.waitUntilExit()
        precondition(ProcessDiscovery.identity(pid: child.processIdentifier) == nil, "Exited process must not remain navigable")
        let error = SessionNavigator.focus(AgentLocation(process: identity), applications: [], frontmostPID: nil)
        precondition(error == "This session is no longer available.")
        print("PASS: real macOS process discovery and stale-session rejection without Herdr")
    }
}
