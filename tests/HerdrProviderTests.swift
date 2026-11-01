import Foundation
import Darwin

private final class TestServer {
    let fd: Int32
    let path: String
    private let lock = NSLock()
    private var target: String?
    private var listRequests = 0
    private var state = "working"
    var pollCount: Int { lock.lock(); defer { lock.unlock() }; return listRequests }
    func setState(_ value: String) { lock.lock(); state = value; lock.unlock() }
    var focusedTarget: String? { lock.lock(); defer { lock.unlock() }; return target }

    init() throws {
        path = "/private/tmp/agentnotch-test-\(UUID().uuidString).sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8CString.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        precondition(result == 0 && listen(fd, 4) == 0)
        DispatchQueue.global().async { [self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                DispatchQueue.global().async { self.serve(client) }
            }
        }
    }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd); unlink(path) }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var line = Data()
        var byte: UInt8 = 0
        while read(client, &byte, 1) == 1 {
            if byte != 10 { line.append(byte); continue }
            guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            line.removeAll()
            let result: [String: Any]
            if request["method"] as? String == "agent.focus" {
                lock.lock()
                target = (request["params"] as? [String: Any])?["target"] as? String
                lock.unlock()
                result = [:]
            } else {
                lock.lock()
                listRequests += 1
                let currentState = state
                lock.unlock()
                result = ["agents": [["pane_id": "w1:p3", "agent": "claude", "agent_status": currentState, "terminal_id": "t1"]]]
            }
            var response = try! JSONSerialization.data(withJSONObject: ["id": request["id"]!, "result": result])
            response.append(10)
            response.withUnsafeBytes { buffer in
                var sent = 0
                while sent < buffer.count {
                    let count = write(client, buffer.baseAddress!.advanced(by: sent), min(7, buffer.count - sent))
                    if count <= 0 { return }
                    sent += count
                }
            }
        }
    }
}

@main
struct HerdrProviderTests {
    static func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(condition(), "Timed out waiting for the local test server")
    }

    static func main() throws {
        let server = try TestServer()

        let request: [String: Any] = ["id": "peer", "method": "agent.list", "params": [:]]
        precondition(LocalRPC.request(socketPath: server.path, peerPID: getpid(), message: request)?["result"] != nil)
        precondition(LocalRPC.request(socketPath: server.path, peerPID: getpid() + 1, message: request) == nil,
                     "A different socket peer must be rejected")
        let provider = HerdrProvider(socketPath: server.path)
        var snapshots = 0
        provider.onSnapshot = { _ in snapshots += 1 }
        provider.connect()
        let initialPolls = server.pollCount
        wait { provider.agents.count == 1 && server.pollCount >= initialPolls + 2 }
        precondition(snapshots == 1, "Unchanged polls must not cause redundant UI publication")
        precondition(provider.diagnosticState == "connected")
        precondition(provider.agents[0].state == .working)
        var finished = false
        provider.focus(provider.agents[0]) { error in
            precondition(error == nil)
            finished = true
        }
        wait { finished }
        precondition(server.focusedTarget == "w1:p3", "Focus must address the exact pane, never its shared agent name")
        server.setState("idle")
        wait { provider.agents.first?.state == .idle && snapshots == 2 }
        server.stop()
        wait { provider.agents.isEmpty && snapshots == 3 }
        provider.stop()
        precondition(provider.agents.isEmpty)
        print("PASS: direct Herdr socket polling, repeated connections, peer identity, fragmented replies, exact-pane focus and shutdown")
    }
}
