import Foundation
import AppKit

// MARK: - Status

enum ServerStatus: Equatable {
    case notInstalled
    case nodeNotInstalled
    case stopped
    case starting
    case stopping
    case running
    case installing(String)
    case error(String)
}

// MARK: - Config

struct PawTermConfig {
    let port: Int
    let token: String?
    let startCommand: [String]?
    let stopCommand: [String]?
    let filePath: String

    static func load(from path: String) -> PawTermConfig {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PawTermConfig(port: 8765, token: nil, startCommand: nil, stopCommand: nil, filePath: path)
        }
        return PawTermConfig(
            port: json["port"] as? Int ?? 8765,
            token: json["token"] as? String,
            startCommand: json["start_command"] as? [String],
            stopCommand: json["stop_command"] as? [String],
            filePath: path
        )
    }
}

// MARK: - PairedDeviceInfo

struct PairedDeviceInfo: Identifiable {
    let deviceId: String
    let name: String
    var id: String { deviceId }
}

// MARK: - ServerManager

@MainActor
class ServerManager: ObservableObject {
    @Published var status: ServerStatus = .stopped
    @Published var deviceCount: Int = 0
    @Published var pairedDevices: [PairedDeviceInfo] = []
    @Published var configPath: String
    @Published var installLog: [String] = []

    // Server update
    @Published var currentServerVersion: String? = nil
    @Published var latestServerVersion: String? = nil
    @Published var serverUpdateAvailable: Bool = false

    // App update
    @Published var appUpdateAvailable: Bool = false
    @Published var latestAppVersion: String? = nil
    @Published var availableConfigs: [String] = []

    var port: Int { config.port }
    var isRunning: Bool { if case .running = status { return true }; return false }
    var isStopping: Bool { if case .stopping = status { return true }; return false }

    private var config: PawTermConfig
    private var pollTimer: Timer?
    private var updateCheckTimer: Timer?
    private var sseTask: Task<Void, Never>?
    private var stoppingStartedAt: Date?
    private static let blockedKey = "pawterm_blocked_devices"
    private var blockedDeviceIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.blockedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.blockedKey) }
    }

    private static let activeConfigPtrPath = "\(NSHomeDirectory())/.config/pawterm/active-config"

    private static func readActiveConfigPath() -> String {
        if let ptr = try? String(contentsOfFile: activeConfigPtrPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !ptr.isEmpty {
            return ptr
        }
        return BuildConfig.defaultConfigPath
    }

    private func writeActiveConfigPtr(_ path: String) {
        let dir = (Self.activeConfigPtrPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if path == BuildConfig.defaultConfigPath {
            try? FileManager.default.removeItem(atPath: Self.activeConfigPtrPath)
        } else {
            try? path.write(toFile: Self.activeConfigPtrPath, atomically: true, encoding: .utf8)
        }
    }

    init() {
        let active = Self.readActiveConfigPath()
        self.configPath = active
        self.config = PawTermConfig.load(from: active)
        refreshAvailableConfigs()
        startPolling()
    }

    // MARK: - Config Management

    func refreshAvailableConfigs() {
        let dir = URL(fileURLWithPath: "\(NSHomeDirectory())/.config/pawterm")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        availableConfigs = files
            .filter { $0.pathExtension == "json" }
            .map { $0.path }
            .sorted()
    }

    func reloadConfig(from path: String) {
        Task { await reloadConfigAsync(from: path) }
    }

    private func reloadConfigAsync(from path: String) async {
        writeActiveConfigPtr(path)
        configPath = path
        config = PawTermConfig.load(from: path)
        deviceCount = 0
        pairedDevices = []
        currentServerVersion = nil
        stopSSE()
        pollTimer?.invalidate()
        refreshAvailableConfigs()
        await restart()
    }

    // MARK: - Prerequisites

    func detectPrerequisites() async {
        if findExecutable("node") == nil {
            status = .nodeNotInstalled; return
        }
        if config.startCommand == nil {
            if findExecutable("pawterm-server") == nil {
                status = .notInstalled; return
            }
            // Binary exists but launchd service not registered → still needs install
            let plist = "\(NSHomeDirectory())/Library/LaunchAgents/com.airoucat.pawterm-server.plist"
            if !FileManager.default.fileExists(atPath: plist) {
                status = .notInstalled; return
            }
        }
        if case .notInstalled = status { status = .stopped }
        if case .nodeNotInstalled = status { status = .stopped }
    }

    // MARK: - Control

    func start() async {
        guard case .stopped = status else { return }
        await detectPrerequisites()
        guard case .stopped = status else { return }
        status = .starting
        let cmd = config.startCommand ?? ["pawterm-server", "start"]
        if !(await runDetached(cmd)) {
            status = .error("Failed to run: \(cmd.joined(separator: " "))")
        }
        // Poll will transition to .running when server responds
    }

    func stop() async {
        guard case .running = status else { return }
        status = .stopping
        stoppingStartedAt = Date()
        deviceCount = 0
        pairedDevices = []
        currentServerVersion = nil
        stopSSE()
        let cmd = config.stopCommand ?? ["pawterm-server", "stop"]
        await runDetached(cmd)
    }

    func restart() async {
        await stop()
        // Wait for poll() to confirm the server is down (stopping → stopped)
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if case .stopped = status { break }
            if case .stopping = status { continue }
            break
        }
        await start()
    }

    // MARK: - Install / Update

    func installServer() async {
        installLog = []
        status = .installing("Installing pawterm-server via npm…")

        guard let npmURL = findExecutable("npm") else {
            status = .error("npm not found — install Node.js first"); return
        }

        let proc = Process()
        proc.executableURL = npmURL
        proc.arguments = ["install", "-g", "pawterm-server@latest"]
        proc.environment = enrichedEnvironment()

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() } catch {
            status = .error("Failed to launch npm: \(error.localizedDescription)"); return
        }

        Task { [weak self] in
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                self?.installLog.append(line)
                self?.status = .installing(line)
            }
        }
        var stderrLines: [String] = []
        Task.detached {
            for try await line in errPipe.fileHandleForReading.bytes.lines { stderrLines.append(line) }
        }

        proc.waitUntilExit()
        if proc.terminationStatus == 0 {
            installLog.append("Registering service…")
            status = .installing("Registering service…")
            await runDetached(["pawterm-server", "install"])
            installLog.append("Done. Ready to start.")
            status = .stopped
        } else {
            let stderr = stderrLines.joined(separator: "\n")
            if stderr.contains("EACCES") || stderr.contains("permission") {
                status = .error("需要权限：终端运行 sudo npm install -g pawterm-server")
            } else if stderr.contains("ENOTFOUND") || stderr.contains("timeout") {
                status = .error("网络错误，请检查网络后重试")
            } else {
                status = .error("Install failed: \(stderrLines.last ?? "exit \(proc.terminationStatus)")")
            }
        }
    }

    func updateServer() async { await installServer() }

    // MARK: - Update Check

    func checkForUpdates() async {
        async let _ = checkServerUpdate()
        async let _ = checkAppUpdate()
    }

    private func checkServerUpdate() async {
        // When running, version is already set by poll() from /health.
        // Only fall back to binary when stopped (and no custom start_command).
        if (currentServerVersion == nil || currentServerVersion!.isEmpty),
           config.startCommand == nil,
           let serverURL = findExecutable("pawterm-server") {
            let proc = Process()
            proc.executableURL = serverURL
            proc.arguments = ["--version"]
            proc.environment = enrichedEnvironment()
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                currentServerVersion = raw.hasPrefix("pawterm-server ")
                    ? String(raw.dropFirst("pawterm-server ".count)) : raw
            }
        }
        guard let url = URL(string: "https://registry.npmjs.org/pawterm-server/latest") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let latest = json["version"] as? String {
            latestServerVersion = latest
            if let current = currentServerVersion, !current.isEmpty {
                serverUpdateAvailable = current != latest
            }
        }
    }

    private func checkAppUpdate() async {
        guard let url = URL(string: "https://api.github.com/repos/Airoucat233/pawterm/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else { return }
        let latest = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        latestAppVersion = latest
        appUpdateAvailable = latest != current
    }

    // MARK: - Pairing PIN

    func requestPairWindow() async -> (pin: String, expiresAt: Int)? {
        guard let token = config.token, !token.isEmpty,
              let url = URL(string: "http://localhost:\(config.port)/admin/pair-window") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pin = json["pin"] as? String,
              let expiresAt = json["expiresAt"] as? Int else { return nil }
        return (pin, expiresAt)
    }

    func requestAdminLoginCode() async -> String? {
        guard let token = config.token, !token.isEmpty,
              let url = URL(string: "http://localhost:\(config.port)/admin/login-codes") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["admin_login_code"] as? String,
              !code.isEmpty else { return nil }
        return code
    }

    // MARK: - Node Installation

    func installNodeViaHomebrew() async {
        if findExecutable("brew") == nil {
            NSWorkspace.shared.open(URL(string: "https://nodejs.org/")!)
            return
        }
        let confirmed = Alerts.confirm(
            "Install Node.js via Homebrew",
            "This will run 'brew install node@20'. It may take a few minutes.",
            confirmText: "Install"
        )
        guard confirmed else { return }

        status = .installing("Installing Node.js via Homebrew…")
        installLog = []
        guard let brewURL = findExecutable("brew") else { status = .error("brew not found"); return }

        let proc = Process()
        proc.executableURL = brewURL
        proc.arguments = ["install", "node@20"]
        proc.environment = enrichedEnvironment()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do { try proc.run() } catch {
            status = .error("Failed to launch brew: \(error.localizedDescription)"); return
        }
        Task { [weak self] in
            for try await line in pipe.fileHandleForReading.bytes.lines {
                self?.installLog.append(line)
                self?.status = .installing(line)
            }
        }
        proc.waitUntilExit()
        await detectPrerequisites()
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        Task { await poll() }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { await self?.checkForUpdates() }
        }
    }

    private func poll() async {
        switch status {
        case .installing, .nodeNotInstalled, .notInstalled: return
        default: break
        }

        guard let healthURL = URL(string: "http://127.0.0.1:\(config.port)/health") else { return }

        guard let (healthData, _) = try? await URLSession.shared.data(from: healthURL) else {
            if case .starting = status { return }
            if case .running = status {
                status = .stopped
                deviceCount = 0
                pairedDevices = []
                currentServerVersion = nil
                stopSSE()
            }
            if case .stopping = status {
                status = .stopped
                stoppingStartedAt = nil
            }
            return
        }

        // Parse version from /health response
        if let json = try? JSONSerialization.jsonObject(with: healthData) as? [String: Any],
           let ver = json["version"] as? String, !ver.isEmpty {
            currentServerVersion = ver
        }

        // Server is up
        switch status {
        case .stopped, .error, .starting:
            status = .running
            Task { await fetchPairedDevices() }
            startSSE()
        case .stopping:
            // Force stop after 15s if the server refuses to go down
            if let since = stoppingStartedAt, Date().timeIntervalSince(since) > 15 {
                status = .stopped
                stoppingStartedAt = nil
            }
        default: break
        }
    }

    // MARK: - SSE

    private func startSSE() {
        guard let token = config.token, !token.isEmpty else { return }
        stopSSE()
        sseTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runSSE()
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func stopSSE() {
        sseTask?.cancel()
        sseTask = nil
    }

    private func runSSE() async {
        guard let token = config.token, !token.isEmpty,
              let url = URL(string: "http://127.0.0.1:\(config.port)/admin/events") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 86400
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        guard let (bytes, _) = try? await URLSession.shared.bytes(for: request) else { return }

        var eventType = ""
        var dataLines: [String] = []

        do {
            for try await line in bytes.lines {
                if case .running = status {} else { break }
                if line.isEmpty {
                    if !dataLines.isEmpty {
                        let data = dataLines.joined(separator: "\n")
                        handleSSEData(type: eventType, data: data)
                        eventType = ""
                        dataLines = []
                    }
                } else if line.hasPrefix("event: ") {
                    eventType = String(line.dropFirst(7))
                } else if line.hasPrefix("data: ") {
                    dataLines.append(String(line.dropFirst(6)))
                }
            }
        } catch {}
    }

    private func handleSSEData(type: String, data: String) {
        guard let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }
        switch type {
        case "pair_request":
            guard let requestId = json["requestId"] as? String,
                  let deviceName = json["deviceName"] as? String,
                  let ip = json["ip"] as? String else { return }
            let deviceId = json["deviceId"] as? String ?? ""
            showPairApproval(requestId: requestId, deviceId: deviceId, deviceName: deviceName, ip: ip)
        case "device_paired":
            guard let deviceId = json["deviceId"] as? String,
                  let name = json["name"] as? String else { return }
            if !pairedDevices.contains(where: { $0.deviceId == deviceId }) {
                pairedDevices.append(PairedDeviceInfo(deviceId: deviceId, name: name))
            }
            deviceCount = pairedDevices.count
        case "device_revoked":
            guard let deviceId = json["deviceId"] as? String else { return }
            pairedDevices.removeAll { $0.deviceId == deviceId }
            deviceCount = pairedDevices.count
        default: break
        }
    }

    // MARK: - Pair Approval

    private func showPairApproval(requestId: String, deviceId: String, deviceName: String, ip: String) {
        // Auto-deny blocked devices
        if blockedDeviceIds.contains(deviceId) {
            Task { await denyPairRequest(requestId: requestId) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "配对请求"
        alert.informativeText = "\(deviceName)\n\(ip)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Block")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await approvePairRequest(requestId: requestId) }
        case .alertSecondButtonReturn:
            Task { await denyPairRequest(requestId: requestId) }
        default:
            var blocked = blockedDeviceIds
            blocked.insert(deviceId)
            blockedDeviceIds = blocked
            Task { await denyPairRequest(requestId: requestId) }
        }
    }

    // MARK: - Pairing HTTP

    func approvePairRequest(requestId: String) async {
        guard let token = config.token, !token.isEmpty,
              let url = URL(string: "http://localhost:\(config.port)/admin/pair-approve") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["requestId": requestId])
        _ = try? await URLSession.shared.data(for: req)
    }

    func denyPairRequest(requestId: String) async {
        guard let token = config.token, !token.isEmpty,
              let url = URL(string: "http://localhost:\(config.port)/admin/pair-deny") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["requestId": requestId])
        _ = try? await URLSession.shared.data(for: req)
    }

    func revokeDevice(_ deviceId: String) async {
        guard let token = config.token, !token.isEmpty,
              let url = URL(string: "http://localhost:\(config.port)/admin/devices/\(deviceId)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
        // SSE device_revoked will update pairedDevices list
    }

    // MARK: - Fetch Paired Devices

    private func fetchPairedDevices() async {
        guard let token = config.token, !token.isEmpty,
              let url = URL(string: "http://127.0.0.1:\(config.port)/admin/devices") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        pairedDevices = json.compactMap { d in
            guard let id = d["deviceId"] as? String, let name = d["name"] as? String else { return nil }
            return PairedDeviceInfo(deviceId: id, name: name)
        }
        deviceCount = pairedDevices.count
    }

    // MARK: - Helpers

    @discardableResult
    private func runDetached(_ cmd: [String]) async -> Bool {
        guard !cmd.isEmpty, let execURL = resolveExecutable(cmd[0]) else { return false }
        let proc = Process()
        proc.executableURL = execURL
        proc.arguments = Array(cmd.dropFirst())
        proc.environment = enrichedEnvironment()
        // /dev/null: child can write freely, no pipe buffers to fill, no SIGPIPE on dealloc
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        return (try? proc.run()) != nil
    }

    private func resolveExecutable(_ nameOrPath: String) -> URL? {
        if nameOrPath.hasPrefix("/") || nameOrPath.hasPrefix("./") {
            let url = URL(fileURLWithPath: nameOrPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return findExecutable(nameOrPath)
    }

    func findExecutable(_ name: String) -> URL? {
        let paths = [
            "/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "\(NSHomeDirectory())/.nvm/versions/node/\(nvmCurrentVersion())/bin",
            "/usr/bin", "/bin"
        ]
        for dir in paths {
            let url = URL(fileURLWithPath: "\(dir)/\(name)")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":").map(String.init) {
                let url = URL(fileURLWithPath: "\(dir)/\(name)")
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    private func nvmCurrentVersion() -> String {
        let dir = "\(NSHomeDirectory())/.nvm/versions/node"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted().last ?? "current"
    }

    private func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin",
                     "\(NSHomeDirectory())/.npm-global/bin"]
        env["PATH"] = extra.joined(separator: ":") + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        return env
    }
}
