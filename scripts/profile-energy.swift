import AppKit
import Combine
import Darwin

@main
struct Profile {
    static func main() {
        // Compile with Agents/*.swift and Integrations/*.swift (see README).
        let duration = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 20
        _ = NSApplication.shared
        let client = AgentClient.shared
        var publications = 0
        let subscription = client.objectWillChange.sink { publications += 1 }
        var start = rusage(), end = rusage(), children = rusage()
        getrusage(RUSAGE_SELF, &start)
        let began = Date()
        client.connect()
        RunLoop.main.run(until: began.addingTimeInterval(max(1, duration)))
        client.disconnect()
        getrusage(RUSAGE_SELF, &end)
        getrusage(RUSAGE_CHILDREN, &children)
        func cpu(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        print("wall_seconds=\(Date().timeIntervalSince(began)) cpu_seconds=\(cpu(end) - cpu(start)) child_cpu_seconds=\(cpu(children)) ui_publications=\(publications) agents=\(client.agents.count)")
        withExtendedLifetime(subscription) {}
    }
}
