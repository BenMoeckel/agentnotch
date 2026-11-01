import Foundation

@main
struct OpenCodeIntegrationTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phase = root.appendingPathComponent("phase")
        try "working".write(to: phase, atomically: true, encoding: .utf8)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-u", "-c", """
        import base64, json, sys
        from pathlib import Path
        from http.server import HTTPServer, BaseHTTPRequestHandler
        root=Path(sys.argv[1])
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                if self.headers.get('Authorization') != 'Basic '+base64.b64encode(b'opencode:fixture-password').decode():
                    self.send_error(401); return
                phase=(root/'phase').read_text()
                if self.path == '/forbidden':
                    (root/'redirect-followed').write_text('unexpected')
                if phase == 'redirect' and self.path == '/api/session/active':
                    self.send_response(302)
                    self.send_header('Location', 'http://127.0.0.1:'+str(self.server.server_port)+'/forbidden')
                    self.end_headers(); return
                if self.path == '/api/session/active':
                    data={'data':{'ses_test':{'type':'running'}} if phase=='working' else {}}
                elif self.path == '/api/session/ses_test':
                    data={'data':{'id':'ses_test','location':{'directory':'/work/project'},'time':{} if phase=='working' else {'idle':123456}}}
                else:
                    self.send_error(404); return
                body=json.dumps(data).encode()
                self.send_response(200); self.send_header('Content-Type','application/json')
                self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
        server=HTTPServer(('127.0.0.1',0), Handler)
        print(server.server_port,flush=True)
        server.serve_forever()
        """, root.path]
        let output = Pipe()
        server.standardOutput = output
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        guard let port = Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            preconditionFailure("The isolated API server did not start")
        }
        let directory = root.appendingPathComponent(".local/state/opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config: [String: Any] = ["pid": server.processIdentifier, "url": "http://127.0.0.1:\(port)", "password": "fixture-password"]
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("service.json"))
        let ui = SystemProcess(identity: ProcessIdentity(pid: 42, startedAt: "100.0"), parentPID: 1,
                               executable: "opencode", arguments: ["opencode"], environment: [:], tty: "/dev/ttys001", workingDirectory: "/work/project")
        let backend = SystemProcess(identity: ProcessIdentity(pid: server.processIdentifier, startedAt: "101.0"), parentPID: 42,
                                    executable: "opencode", arguments: ["opencode", "serve", "--service"], environment: [:], tty: nil, workingDirectory: "/")
        let processes = [ui, backend]
        let agents = ProcessDiscovery.agents(in: processes, applications: [])
        let native = NativeSessionIntegration(home: root)
        let working = native.enrich(agents, processes: processes)
        var activity = AgentActivity()
        activity.update(working)
        precondition(activity.active.count == 1 && activity.active[0].location?.process == ui.identity,
                     "The service's active session must belong to its real TUI, without a duplicate backend icon")
        precondition(activity.active[0].location?.sessionID == "ses_test")
        let secondUI = SystemProcess(identity: ProcessIdentity(pid: 43, startedAt: "102.0"), parentPID: 1,
                                     executable: "opencode", arguments: ["opencode"],
                                     environment: ["HERDR_PANE_ID": "w15:p1", "HERDR_SOCKET_PATH": "/tmp/fixture.sock"],
                                     tty: "/dev/ttys002", workingDirectory: "/work/project")
        let inheritedService = SystemProcess(identity: backend.identity, parentPID: 42,
                                            executable: "opencode", arguments: ["opencode", "serve", "--service"],
                                            environment: secondUI.environment, tty: ui.tty, workingDirectory: "/")
        let sharedProcesses = [ui, secondUI, inheritedService]
        let sharedAgents = ProcessDiscovery.agents(in: sharedProcesses, applications: [])
        let serviceAgent = sharedAgents.first { $0.location?.process == backend.identity }!
        precondition(serviceAgent.location?.tty == nil && serviceAgent.location?.herdr == nil &&
                     serviceAgent.location?.tmux == nil && serviceAgent.location?.ghosttySurfaceID == nil,
                     "A shared OpenCode service must not inherit its launcher's interactive terminal or pane")
        let pane = AgentInfo(id: "w15:p1", name: "opencode", kind: "opencode", state: .working,
                             title: "OC | same conversation")
        let snapshots = [HerdrSnapshot(socketPath: "/tmp/fixture.sock", agents: [pane])]
        let sharedNative = native.enrich(sharedAgents, processes: sharedProcesses)
        let shared = SessionMerger.merge(system: sharedNative, events: [], herdr: snapshots)
        var sharedActivity = AgentActivity()
        sharedActivity.update(shared)
        precondition(sharedActivity.active.count == 1 && sharedActivity.active[0].location?.process == secondUI.identity,
                     "Two TUIs in the same project plus their active shared service and Herdr must show only the owning pane")
        precondition(!sharedNative.contains { $0.location?.process == backend.identity && $0.state == .working },
                     "Ambiguous frontend ownership must never create an active service copy")
        let separatePanes = [pane, AgentInfo(id: "w15:p2", name: "opencode", kind: "opencode", state: .working,
                                            location: AgentLocation(sessionID: "independent-session"))]
        sharedActivity.update(SessionMerger.merge(system: sharedNative, events: [],
            herdr: [HerdrSnapshot(socketPath: "/tmp/fixture.sock", agents: separatePanes)]))
        precondition(sharedActivity.active.count == 2,
                     "Independent pane sessions in the same project must remain separate")
        let headless = native.enrich([serviceAgent], processes: [inheritedService])
        precondition(headless.count == 1 && headless[0].state == .working && headless[0].location?.sessionID == "ses_test",
                     "An active service without a matching TUI must still expose its headless session")
        try "idle".write(to: phase, atomically: true, encoding: .utf8)
        activity.update(native.enrich(agents, processes: processes))
        precondition(activity.active.isEmpty && activity.results.count == 1,
                     "An API completion must move the exact session to results")
        try "redirect".write(to: phase, atomically: true, encoding: .utf8)
        let unknown = native.enrich(agents, processes: processes)
        precondition(!unknown.contains { $0.state == .working })
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("redirect-followed").path),
                     "Credentials must never be sent through an API redirect")
        precondition(native.enrich([], processes: []).isEmpty, "Exited processes must not retain native sessions")
        print("PASS: authenticated local OpenCode service discovery, TUI ownership, completion, redirect rejection and exited-process removal")
    }
}
