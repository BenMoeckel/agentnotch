import Foundation

struct CommandResult {
    let output: String
    let succeeded: Bool
}

enum LocalCommand {
    /// Called on a worker queue. Drain output while running and bound both time and memory.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 3,
                    environment: [String: String]? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return CommandResult(output: "", succeeded: false) }
        let finished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var output = Data()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                lock.lock()
                if output.count < 1_048_576 { output.append(chunk.prefix(1_048_576 - output.count)) }
                lock.unlock()
            }
            finished.signal()
        }
        let timedOut = exited.wait(timeout: .now() + max(0, timeout)) == .timedOut
        if timedOut {
            process.terminate()
            // Only terminate the subprocess we own, never an agent or terminal.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        _ = finished.wait(timeout: .now() + 0.5)
        lock.lock()
        let text = String(decoding: output, as: UTF8.self)
        lock.unlock()
        return CommandResult(output: text.trimmingCharacters(in: .newlines),
                             succeeded: !timedOut && process.terminationStatus == 0)
    }

    static func appleScript(_ source: String, timeout: TimeInterval = 3) -> CommandResult {
        run("/usr/bin/osascript", ["-e", "with timeout of \(Int(timeout)) seconds\n\(source)\nend timeout"], timeout: timeout + 1)
    }

    static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
