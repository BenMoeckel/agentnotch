import AppKit
import Darwin

struct SystemProcess {
    let identity: ProcessIdentity
    let parentPID: Int32
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let tty: String?
    let workingDirectory: String?
}

struct HostApplication {
    let pid: Int32
    let bundleID: String?
    var bundlePath: String? = nil
}

enum AgentCatalog {
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]
    private static let executables: [String: String] = [
        "claude": "claude", "claude-code": "claude", "codex": "codex", "codex-cli": "codex",
        "gemini": "gemini", "gemini-cli": "gemini", "copilot": "copilot",
        "opencode": "opencode", "amp": "amp", "kiro-cli": "kiro", "qwen": "qwen",
        "kimi": "kimi", "kimi-cli": "kimi", "qodercli": "qodercli", "qoder": "qodercli",
        "kilo": "kilo", "cline": "cline", "pi": "pi", "omp": "omp",
        "hermes": "hermes", "maki": "maki", "mastracode": "mastracode",
        "cursor-agent": "cursor", "droid": "droid", "auggie": "auggie"
    ]
    private static let packages: [String: String] = [
        "@anthropic-ai/claude-code": "claude", "@openai/codex": "codex",
        "@google/gemini-cli": "gemini", "@github/copilot": "copilot",
        "@qwen-code/qwen-code": "qwen", "@mariozechner/pi-coding-agent": "pi",
        "@sourcegraph/amp": "amp", "opencode-ai": "opencode", "@kilocode/cli": "kilo"
    ]

    static func kind(executable: String, arguments: [String]) -> String? {
        let binary = URL(fileURLWithPath: executable, isDirectory: false).lastPathComponent.lowercased()
        if let kind = executables[binary] { return kind }
        if executable.contains("/claude/versions/"),
           binary.range(of: #"^\d+\.\d+\.\d+[^/]*$"#, options: .regularExpression) != nil { return "claude" }
        // Inspect only the interpreter's script, never arbitrary prompt arguments.
        guard interpreters.contains(binary) else { return nil }
        var arguments = Array(arguments.dropFirst())
        while let flag = arguments.first, ["--no-warnings", "--enable-source-maps", "--experimental-strip-types"].contains(flag) {
            arguments.removeFirst()
        }
        guard let script = arguments.first, !script.hasPrefix("-") else { return nil }
        let normalized = script.replacingOccurrences(of: "\\", with: "/").lowercased()
        for (package, kind) in packages where normalized.contains("/\(package)/") { return kind }
        let name = URL(fileURLWithPath: script, isDirectory: false).deletingPathExtension().lastPathComponent.lowercased()
        return executables[name]
    }

    static func needsArguments(_ executable: String) -> Bool {
        let name = URL(fileURLWithPath: executable, isDirectory: false).lastPathComponent.lowercased()
        return kind(executable: executable, arguments: []) != nil || interpreters.contains(name) ||
            ["bash", "zsh", "sh", "fish", "nu", "herdr", "tmux"].contains(name)
    }
}

enum ProcessDiscovery {
    static let environmentKeys: Set<String> = [
        "HERDR_PANE_ID", "HERDR_SOCKET_PATH", "TMUX", "TMUX_PANE", "GHOSTTY_SURFACE_ID"
    ]

    private static let terminalLock = NSLock()
    private static var terminalPaths: [dev_t: String] = [:]

    private static func terminalPath(device: dev_t) -> String? {
        terminalLock.lock()
        defer { terminalLock.unlock() }
        if let cached = terminalPaths[device] {
            var info = stat()
            // A terminal can close or its device number can be reused. Validate
            // the cached path on every scan before using it for navigation.
            if lstat(cached, &info) == 0, info.st_mode & S_IFMT == S_IFCHR, info.st_rdev == device {
                return cached
            }
            terminalPaths.removeValue(forKey: device)
        }
        guard let name = devname(device, S_IFCHR) else { return nil }
        let path = "/dev/" + String(cString: name)
        if terminalPaths.count >= 256 { terminalPaths.removeAll() }
        terminalPaths[device] = path
        return path
    }

    static func identity(pid: Int32) -> ProcessIdentity? {
        guard let info = processInfo(pid: pid) else { return nil }
        return identity(info)
    }

    private static func identity(_ info: kinfo_proc) -> ProcessIdentity {
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessIdentity(pid: info.kp_proc.p_pid, startedAt: "\(start.tv_sec).\(start.tv_usec)")
    }

    private static func processInfo(pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size else { return nil }
        return info
    }

    static func snapshot() -> [SystemProcess] {
        // One scratch buffer per scan rather than a megabyte allocation for every shell/agent.
        var argumentBuffer = [UInt8](repeating: 0, count: 1_048_576)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        // Processes can be created between the sizing call and the read.
        for _ in 0..<3 {
            var records = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 128)
            size = records.count * MemoryLayout<kinfo_proc>.stride
            let result = records.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
            if result != 0 { continue }
            // devname scans /dev. Many processes share a TTY (including unresolved
            // device numbers), so resolve each device only once in this snapshot.
            var terminalNames: [dev_t: String] = [:]
            var resolvedDevices: Set<dev_t> = []
            return records.prefix(size / MemoryLayout<kinfo_proc>.stride).map { info in
                let pid = info.kp_proc.p_pid
                // Root-owned login processes are kept for ancestry, without reading their arguments.
                let own = info.kp_eproc.e_ucred.cr_uid == getuid()
                var path = own ? executablePath(pid: pid) : ""
                if own && path.isEmpty {
                    path = withUnsafeBytes(of: info.kp_proc.p_comm) {
                        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                    }
                }
                let command = own && AgentCatalog.needsArguments(path) ? command(pid: pid, buffer: &argumentBuffer) : nil
                let deviceNumber = info.kp_eproc.e_tdev
                if deviceNumber != dev_t(-1), resolvedDevices.insert(deviceNumber).inserted,
                   let path = terminalPath(device: deviceNumber) {
                    terminalNames[deviceNumber] = path
                }
                let tty = terminalNames[deviceNumber]
                return SystemProcess(identity: identity(info), parentPID: info.kp_eproc.e_ppid,
                                     executable: command?.0 ?? path, arguments: command?.1 ?? [],
                                     environment: command?.2 ?? [:], tty: tty, workingDirectory: nil)
            }
        }
        return []
    }

    /// Decode KERN_PROCARGS2, retaining only routing metadata. Never retain secrets in the environment.
    static func parseCommand(_ buffer: [UInt8], count: Int? = nil) -> (String, [String], [String: String])? {
        let bytes = buffer.prefix(count ?? buffer.count)
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 32_768 else { return nil }
        var offset = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return String(decoding: bytes[offset..<end], as: UTF8.self)
        }
        guard let executable = nextString() else { return nil }
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        var args: [String] = []
        for _ in 0..<argc {
            guard let value = nextString() else { return nil }
            args.append(value)
        }
        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<separator])
            if environmentKeys.contains(key) { environment[key] = String(entry[entry.index(after: separator)...]) }
        }
        return (executable, args, environment)
    }

    private static func command(pid: Int32, buffer bytes: inout [UInt8]) -> (String, [String], [String: String])? {
        var size = bytes.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        return parseCommand(bytes, count: size)
    }

    private static func executablePath(pid: Int32) -> String {
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; the C macro is not imported by Swift.
        var path = [UInt8](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return "" }
        return String(decoding: path.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer in
            let bytes = buffer.prefix { $0 != 0 }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }

    static func ancestry(of pid: Int32, in processes: [Int32: SystemProcess]) -> [SystemProcess] {
        var pid = pid
        var visited = Set<Int32>()
        var result: [SystemProcess] = []
        while pid > 1, visited.insert(pid).inserted, let process = processes[pid] {
            result.append(process)
            pid = process.parentPID
        }
        return result
    }

    static func isSharedBackend(_ process: SystemProcess, kind: String) -> Bool {
        let arguments = process.arguments
        if kind == "opencode", arguments.dropFirst().contains("serve") { return true }
        guard kind == "codex", arguments.dropFirst().contains("app-server") else { return false }
        // `app-server` is also a valid prompt. Require an actual server flag so a
        // TUI that merely mentions the word keeps its real terminal target.
        return arguments.contains("--listen") || arguments.contains("--managed-daemon") ||
            arguments.contains("--analytics-default-enabled") || arguments.dropFirst().first == "app-server"
    }

    static func agents(in processes: [SystemProcess], applications: [HostApplication]) -> [AgentInfo] {
        let byPID = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { _, last in last })
        let applicationPIDs = Set(applications.map(\.pid))
        let candidates = processes.compactMap { process -> (SystemProcess, String)? in
            guard !applicationPIDs.contains(process.identity.pid) else { return nil }
            guard let kind = AgentCatalog.kind(executable: process.executable, arguments: process.arguments) else { return nil }
            return (process, kind)
        }
        return candidates.compactMap { process, kind in
            let chain = ancestry(of: process.identity.pid, in: byPID)
            // Keep the native process, whose files/status belong to the session.
            // Independent agents launched through a shell are not wrappers.
            if AgentCatalog.interpreters.contains(URL(fileURLWithPath: process.executable, isDirectory: false).lastPathComponent.lowercased()),
               candidates.contains(where: { child, childKind in
                   child.parentPID == process.identity.pid && childKind == kind && child.tty == process.tty
               }) {
                return nil
            }
            var location = location(for: process, chain: chain, applications: applications)
            if isSharedBackend(process, kind: kind) {
                // A long-lived backend inherits its launcher's terminal. It does
                // not own that terminal's screen or multiplexer pane, and its
                // rollout files may belong to panes started later.
                location.tty = nil
                location.herdr = nil
                location.tmux = nil
                location.ghosttySurfaceID = nil
            }
            let project = location.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
            return AgentInfo(id: process.identity.id, name: kind, kind: kind, state: .unknown,
                             terminalID: process.identity.id, title: project.map { "\(kind) · \($0)" }, location: location)
        }
    }

    static func location(for process: SystemProcess, chain: [SystemProcess], applications: [HostApplication]) -> AgentLocation {
        let hosts = Dictionary(applications.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
        let host = chain.compactMap { hosts[$0.identity.pid] }.first
        // A GUI launched from a terminal owns its descendants. Its launcher's TTY
        // and multiplexer variables must not send editor agents back to that terminal.
        let localChain = Array(chain.prefix { $0.identity.pid != host?.pid })
        var env = localChain.reversed().reduce(into: [String: String]()) { $0.merge($1.environment) { _, child in child } }
        let editorHost = host != nil && ![TerminalIntegration.terminal, TerminalIntegration.iterm,
                                         TerminalIntegration.ghostty].contains(host?.bundleID ?? "")
        if editorHost {
            let names = Set(localChain.map { URL(fileURLWithPath: $0.executable).lastPathComponent.lowercased() })
            if !names.contains("herdr") { env.removeValue(forKey: "HERDR_PANE_ID") }
            if !names.contains("tmux") { env.removeValue(forKey: "TMUX") }
            env.removeValue(forKey: "GHOSTTY_SURFACE_ID")
        }
        var location = AgentLocation(process: process.identity, applicationPID: host?.pid,
                             bundleID: host?.bundleID, tty: localChain.reversed().compactMap(\.tty).first,
                             workingDirectory: process.workingDirectory ?? workingDirectory(pid: process.identity.pid),
                             ghosttySurfaceID: env["GHOSTTY_SURFACE_ID"])
        if let pane = env["HERDR_PANE_ID"], !pane.isEmpty {
            location.herdr = HerdrLocation(socketPath: env["HERDR_SOCKET_PATH"] ?? defaultHerdrSocket, paneID: pane)
        }
        if let tmux = env["TMUX"], let pane = env["TMUX_PANE"], pane.hasPrefix("%") {
            // The path may contain commas; the two final fields are PID and session ID.
            let parts = tmux.split(separator: ",", omittingEmptySubsequences: false)
            if parts.count >= 3 {
                location.tmux = TmuxLocation(socketPath: parts.dropLast(2).joined(separator: ","), paneID: pane)
            }
        }
        return location
    }

    static var defaultHerdrSocket: String {
        ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"] ?? NSHomeDirectory() + "/.config/herdr/herdr.sock"
    }
}
