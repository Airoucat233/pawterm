import Foundation
import Combine
import AppKit

enum ServerStatus: Equatable {
    case notInstalled          // pawterm-server not in PATH
    case nodeNotInstalled      // node also not found
    case stopped
    case starting
    case running
    case installing(String)    // installing/updating server; payload is status message
    case error(String)
}

@MainActor
class ServerManager: ObservableObject {
    @Published var status: ServerStatus = .stopped
    @Published var deviceCount: Int = 0
    @Published var currentServerVersion: String? = nil
    @Published var latestServerVersion: String? = nil
    @Published var updateAvailable: Bool = false
    @Published var installLog: [String] = []

    let port: Int

    private var process: Process?
    private var pollTimer: Timer?
    private var updateCheckTimer: Timer?
    private let config: PawTermConfig

    init() {
        self.config = PawTermConfig.load()
        self.port = config.port
        startPolling()
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    // MARK: - Prerequisites Detection

    func detectPrerequisites() async {
        if findExecutable("node") == nil {
            status = .nodeNotInstalled
            return
        }
        if findExecutable("pawterm-server") == nil {
            status = .notInstalled
            return
        }
        // Both exist — let polling determine stopped/running naturally
        // Only reset to stopped if we're in a "missing" state
        if case .notInstalled = status { status = .stopped }
        if case .nodeNotInstalled = status { status = .stopped }
    }

    // MARK: - Install / Update

    func installServer() async {
        installLog = []
        status = .installing("Installing pawterm-server via npm…")

        guard let npmURL = findExecutable("npm") else {
            status = .error("npm not found. Please install Node.js first.")
            return
        }

        let proc = Process()
        proc.executableURL = npmURL
        proc.arguments = ["install", "-g", "pawterm-server@latest"]
        proc.environment = enrichedEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            status = .error("Failed to launch npm: \(error.localizedDescription)")
            return
        }

        // Stream stdout
        Task.detached { [weak self] in
            let handle = outPipe.fileHandleForReading
            for try await line in handle.bytes.lines {
                await MainActor.run {
                    self?.installLog.append(line)
                    self?.status = .installing(line)
                }
            }
        }

        // Collect stderr
        var stderrLines: [String] = []
        Task.detached {
            let handle = errPipe.fileHandleForReading
            for try await line in handle.bytes.lines {
                stderrLines.append(line)
            }
        }

        proc.waitUntilExit()
        let exitCode = proc.terminationStatus

        if exitCode == 0 {
            installLog.append("Installation complete.")
            status = .stopped
            await start()
        } else {
            let stderr = stderrLines.joined(separator: "\n")
            if stderr.contains("EACCES") || stderr.contains("permission") {
                status = .error("需要 sudo 权限：在终端运行 sudo npm install -g pawterm-server")
            } else if stderr.contains("ENOTFOUND") || stderr.contains("network") || stderr.contains("timeout") {
                status = .error("网络错误，请检查网络后重试")
            } else {
                let msg = stderrLines.last ?? "Unknown error (exit \(exitCode))"
                status = .error("Install failed: \(msg)")
            }
        }
    }

    func updateServer() async {
        await installServer()
    }

    // MARK: - Check for Updates

    func checkForUpdates() async {
        // Get current version
        if let serverURL = findExecutable("pawterm-server") {
            let proc = Process()
            proc.executableURL = serverURL
            proc.arguments = ["--version"]
            proc.environment = enrichedEnvironment()

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()

            if let _ = try? proc.run() {
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let raw = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) {
                    // Strip "pawterm-server " prefix if present
                    let ver = raw.hasPrefix("pawterm-server ")
                        ? String(raw.dropFirst("pawterm-server ".count))
                        : raw
                    currentServerVersion = ver
                }
            }
        }

        // Fetch latest from npm registry
        guard let url = URL(string: "https://registry.npmjs.org/pawterm-server/latest") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let latest = json["version"] as? String {
                latestServerVersion = latest
                if let current = currentServerVersion, !current.isEmpty {
                    updateAvailable = current != latest
                }
            }
        } catch {
            // Silently ignore network errors during background check
        }
    }

    // MARK: - Pairing PIN

    /// Open a fresh PIN pairing window on the running server and return the 6-digit PIN.
    /// Returns nil if the server is unreachable, config has no token, or the server
    /// is too old to support /admin/pair-window (pre-slice-3).
    func requestPairWindow() async -> (pin: String, expiresAt: Int)? {
        guard let cfg = AdminURL.loadConfig(),
              let url = URL(string: "http://localhost:\(cfg.port)/admin/pair-window") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pin = json["pin"] as? String,
                  let expiresAt = json["expiresAt"] as? Int else { return nil }
            return (pin, expiresAt)
        } catch {
            return nil
        }
    }

    // MARK: - Node Installation

    func installNodeViaHomebrew() async {
        if findExecutable("brew") == nil {
            await MainActor.run {
                NSWorkspace.shared.open(URL(string: "https://nodejs.org/")!)
            }
            return
        }

        let confirmed = await MainActor.run {
            Alerts.confirm(
                "Install Node.js via Homebrew",
                "This will run 'brew install node@20'. It may take a few minutes.",
                confirmText: "Install"
            )
        }
        guard confirmed else { return }

        status = .installing("Installing Node.js via Homebrew…")
        installLog = []

        guard let brewURL = findExecutable("brew") else {
            status = .error("brew not found")
            return
        }

        let proc = Process()
        proc.executableURL = brewURL
        proc.arguments = ["install", "node@20"]
        proc.environment = enrichedEnvironment()

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe

        do {
            try proc.run()
        } catch {
            status = .error("Failed to launch brew: \(error.localizedDescription)")
            return
        }

        Task.detached { [weak self] in
            let handle = outPipe.fileHandleForReading
            for try await line in handle.bytes.lines {
                await MainActor.run {
                    self?.installLog.append(line)
                    self?.status = .installing(line)
                }
            }
        }

        proc.waitUntilExit()
        await detectPrerequisites()
    }

    // MARK: - Control

    func start() async {
        guard case .stopped = status else { return }
        status = .starting

        guard let execURL = findExecutable("pawterm-server") else {
            status = .error("pawterm-server not found — run install.sh first")
            return
        }

        let proc = Process()
        proc.executableURL = execURL
        proc.arguments = []
        proc.environment = enrichedEnvironment()

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            status = .error("Failed to start: \(error.localizedDescription)")
            return
        }

        self.process = proc

        // Monitor stdout for "ready" signal
        Task.detached { [weak self] in
            let handle = pipe.fileHandleForReading
            for try await line in handle.bytes.lines {
                if line.lowercased().contains("ready") || line.lowercased().contains("listening") {
                    await MainActor.run { self?.status = .running }
                    return
                }
            }
        }

        // Fallback: assume running after 3s if process still alive
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if case .starting = status, proc.isRunning {
            status = .running
        }
    }

    func stop() async {
        guard let proc = process, proc.isRunning else {
            status = .stopped
            process = nil
            return
        }
        proc.interrupt() // SIGINT
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if proc.isRunning {
            proc.terminate() // SIGTERM
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        process = nil
        status = .stopped
        deviceCount = 0
    }

    func restart() async {
        await stop()
        await start()
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        // Poll immediately
        Task { await poll() }

        // Check for updates every 30 minutes
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { await self?.checkForUpdates() }
        }
    }

    private func poll() async {
        // Skip polling during install/detect phases
        switch status {
        case .installing, .nodeNotInstalled, .notInstalled:
            return
        default:
            break
        }

        let baseURL = "http://127.0.0.1:\(port)"
        let token = config.token

        // Health check
        guard let healthURL = URL(string: "\(baseURL)/health"),
              let _ = try? await URLSession.shared.data(from: healthURL) else {
            // Only update to stopped if we didn't spawn it ourselves as starting
            if case .starting = status { return }
            if process == nil {
                if case .running = status { status = .stopped }
                if case .error = status { } // keep error
            }
            return
        }

        // If we reach here, server is responding
        if case .stopped = status { status = .running }
        if case .error = status { status = .running }

        // Device count
        guard let token, !token.isEmpty,
              let devURL = URL(string: "\(baseURL)/admin/devices") else { return }

        var req = URLRequest(url: devURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        deviceCount = json.count
    }

    // MARK: - Helpers

    func findExecutable(_ name: String) -> URL? {
        let searchPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "\(NSHomeDirectory())/.nvm/versions/node/\(nvmCurrentVersion())/bin",
            "/usr/bin",
            "/bin"
        ]
        for dir in searchPaths {
            let url = URL(fileURLWithPath: "\(dir)/\(name)")
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        // Also try PATH from environment
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":").map(String.init) {
                let url = URL(fileURLWithPath: "\(dir)/\(name)")
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    private func nvmCurrentVersion() -> String {
        let nvmDir = "\(NSHomeDirectory())/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvmDir)) ?? []
        return versions.sorted().last ?? "current"
    }

    private func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Prepend common bin paths so npm/node/pawterm-server are findable
        let extraPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "\(NSHomeDirectory())/.npm-global/bin"
        ]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = extraPaths.joined(separator: ":") + ":" + existingPath
        return env
    }
}

// MARK: - Config

struct PawTermConfig {
    let port: Int
    let token: String?

    static func load() -> PawTermConfig {
        let configPath = "\(NSHomeDirectory())/.config/pawterm/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PawTermConfig(port: 8765, token: nil)
        }
        let port = json["port"] as? Int ?? 8765
        let token = json["token"] as? String
        return PawTermConfig(port: port, token: token)
    }
}
