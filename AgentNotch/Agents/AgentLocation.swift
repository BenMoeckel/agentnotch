import Foundation

/// A process incarnation, not just a PID: macOS can reuse PIDs after exit.
struct ProcessIdentity: Equatable, Hashable, Codable {
    let pid: Int32
    let startedAt: String

    var id: String { "process:\(pid):\(startedAt)" }
}

struct HerdrLocation: Equatable, Hashable {
    let socketPath: String
    let paneID: String
    var id: String { "herdr:\(socketPath):\(paneID)" }
}

struct TmuxLocation: Equatable {
    let socketPath: String
    let paneID: String
}

struct AgentLocation: Equatable {
    var process: ProcessIdentity?
    var applicationPID: Int32?
    var bundleID: String?
    var tty: String?
    var workingDirectory: String?
    var windowTitle: String?
    var ghosttySurfaceID: String?
    var herdr: HerdrLocation?
    var tmux: TmuxLocation?
    var sessionID: String?
    var sessionName: String?
    var editor: EditorTarget?
}

struct EditorTarget: Equatable {
    var socketPath: String
    var host: ProcessIdentity
    var terminalPID: Int32?
}
