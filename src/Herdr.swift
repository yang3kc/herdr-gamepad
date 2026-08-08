import Foundation

/// Thin client for Herdr's local socket API.
///
/// The protocol is newline-delimited JSON: write one request line, read one
/// response line. Herdr closes the connection after answering a plain method
/// call, so each request opens its own short-lived socket. That is cheap
/// (a local unix socket) and keeps this class free of connection state.
final class HerdrClient {

    enum ClientError: LocalizedError {
        case noSocket(String)
        case connectFailed(String, errno: Int32)
        case ioFailed(String)
        case api(code: String, message: String)

        var errorDescription: String? {
            switch self {
            case .noSocket(let p):
                return """
                Herdr socket not found at \(p)
                Is the Herdr server running? Try `herdr status`.
                """
            case .connectFailed(let p, let e):
                return "cannot connect to \(p): \(String(cString: strerror(e)))"
            case .ioFailed(let what):
                return "socket \(what) failed"
            case .api(let code, let message):
                return "herdr returned \(code): \(message)"
            }
        }
    }

    let socketPath: String

    init(socketPath: String? = nil) {
        if let explicit = socketPath {
            self.socketPath = explicit
        } else if let env = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"], !env.isEmpty {
            self.socketPath = env
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.socketPath = "\(home)/.config/herdr/herdr.sock"
        }
    }

    private var requestCounter = 0

    @discardableResult
    func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw ClientError.noSocket(socketPath)
        }

        requestCounter += 1
        let payload: [String: Any] = [
            "id": "gamepad_\(requestCounter)",
            "method": method,
            "params": params,
        ]
        var line = try JSONSerialization.data(withJSONObject: payload, options: [])
        line.append(0x0A)  // newline terminator

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.ioFailed("create") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path is a fixed 104-byte buffer on Darwin; a longer path cannot
        // be represented, so fail loudly rather than silently truncating.
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            throw ClientError.connectFailed(socketPath, errno: ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ClientError.connectFailed(socketPath, errno: errno) }

        try line.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                guard n > 0 else { throw ClientError.ioFailed("write") }
                sent += n
            }
        }

        // Read until the first newline — that is exactly one response.
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while !response.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            response.append(contentsOf: chunk[0..<n])
        }
        guard !response.isEmpty else { throw ClientError.ioFailed("read") }
        if let nl = response.firstIndex(of: 0x0A) { response = response.prefix(upTo: nl) }

        let parsed = try JSONSerialization.jsonObject(with: response) as? [String: Any] ?? [:]
        if let err = parsed["error"] as? [String: Any] {
            throw ClientError.api(code: err["code"] as? String ?? "unknown",
                                  message: err["message"] as? String ?? "")
        }
        return parsed["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Helpers used across modes

    /// Herdr requires `title`; `body` is optional but is where detail belongs.
    ///
    /// Delivery is NOT guaranteed: Herdr rate-limits notifications and
    /// suppresses popups for the tab you are already looking at. The reply
    /// says which happened, so callers get told rather than silently ignored.
    /// Never rely on this as the only evidence that something worked.
    @discardableResult
    func notify(_ title: String, body: String? = nil) -> Bool {
        var params: [String: Any] = ["title": title]
        if let body { params["body"] = body }
        // Feedback must never be able to take down the daemon.
        guard let result = try? request("notification.show", params) else { return false }
        let shown = result["shown"] as? Bool ?? false
        if !shown {
            let reason = result["reason"] as? String ?? "unknown"
            onNotifySuppressed?(reason, title)
        }
        return shown
    }

    /// Called when a notification was accepted but not displayed.
    var onNotifySuppressed: ((_ reason: String, _ title: String) -> Void)?

    struct Agent {
        let paneID: String
        let workspaceID: String
        let title: String
        let status: String
        let agent: String
        let focused: Bool

        /// Agents that have stopped and want a human.
        var isWaiting: Bool { status == "done" || status == "blocked" }
    }

    func agents() throws -> [Agent] {
        let result = try request("agent.list")
        let raw = result["agents"] as? [[String: Any]] ?? []
        return raw.map {
            Agent(paneID: $0["pane_id"] as? String ?? "",
                  workspaceID: $0["workspace_id"] as? String ?? "",
                  title: ($0["terminal_title_stripped"] as? String)
                      ?? ($0["terminal_title"] as? String) ?? "(untitled)",
                  status: $0["agent_status"] as? String ?? "unknown",
                  agent: $0["agent"] as? String ?? "?",
                  focused: $0["focused"] as? Bool ?? false)
        }
    }
}
