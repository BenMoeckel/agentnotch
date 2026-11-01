import Foundation
import Darwin

enum LocalRPC {
    /// Small JSON-line requests to a known local process; no shell or application launch.
    static func request(socketPath: String, peerPID: Int32? = nil, message: [String: Any], timeout: Double = 1) -> [String: Any]? {
        guard var payload = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        payload.append(10)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var deadline = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout.size(ofValue: deadline)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout.size(ofValue: deadline)))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        if let peerPID {
            var actual: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &actual, &size) == 0, actual == peerPID else { return nil }
        }
        let sent = payload.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard sent else { return nil }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while data.count < 1_048_576 {
            let count = recv(fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            data.append(contentsOf: bytes.prefix(count))
            if let newline = data.firstIndex(of: 10) {
                return (try? JSONSerialization.jsonObject(with: data.prefix(upTo: newline))) as? [String: Any]
            }
        }
        return nil
    }
}
