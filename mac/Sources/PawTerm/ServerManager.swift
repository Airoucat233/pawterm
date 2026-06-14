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
            return PawTermConfig(port: BuildConfig.defaultServerPort, token: nil, startCommand: nil, stopCommand: nil, filePath: path)
        }
        return PawTermConfig(
            port: json["port"] as? Int ?? BuildConfig.defaultServerPort,
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

enum AppUpdateChannel {
    case stable
    case prerelease
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
    @Published var latestAppReleaseTag: String? = nil
    @Published var latestAppDownloadURL: URL? = nil
    @Published var appUpdateChannel: AppUpdateChannel = .stable
    @Published var serverUpdateChannel: AppUpdateChannel = .stable
    @Published var availableConfigs: [String] = []

    var port: Int { config.port }
    var isRunning: Bool { if case .running = status { return true }; return false }
    var isStopping: Bool { if case .stopping = status { return true }; return false }

    private var config: PawTermConfig
    private var pollTimer: Timer?
    private var updateCheckTimer: Timer?
    private var sseTask: Task<Void, Never>?
    private var stoppingStartedAt: Date?
    private static let legacyPrereleaseChannelKey = "pawterm_prerelease_channel"
    private static let appPrereleaseChannelKey = "pawterm_app_prerelease_channel"
    private static let serverPrereleaseChannelKey = "pawterm_server_prerelease_channel"
    private static let blockedKey = "pawterm_blocked_devices"
    private var blockedDeviceIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.blockedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.blockedKey) }
    }

    private static let activeConfigPtrPath = "\(NSHomeDirectory())/.config/pawterm/active-config"

    var isDevBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
    }

    var appPrereleaseChannelEnabled: Bool {
        get { appUpdateChannel == .prerelease }
        set {
            appUpdateChannel = newValue ? .prerelease : .stable
            UserDefaults.standard.set(newValue, forKey: Self.appPrereleaseChannelKey)
            Task { await checkAppUpdate() }
        }
    }

    var serverPrereleaseChannelEnabled: Bool {
        get { serverUpdateChannel == .prerelease }
        set {
            serverUpdateChannel = newValue ? .prerelease : .stable
            UserDefaults.standard.set(newValue, forKey: Self.serverPrereleaseChannelKey)
            Task { await checkServerUpdate() }
        }
    }

    var appReleasePageURL: URL {
        if let tag = latestAppReleaseTag {
            return URL(string: "https://github.com/Airoucat233/pawterm/releases/tag/\(tag)")!
        }
        return URL(string: "https://github.com/Airoucat233/pawterm/releases/latest")!
    }

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
        let defaults = UserDefaults.standard
        let legacyPrerelease = defaults.bool(forKey: Self.legacyPrereleaseChannelKey)
        self.appUpdateChannel = defaults.bool(forKey: Self.appPrereleaseChannelKey) || legacyPrerelease ? .prerelease : .stable
        self.serverUpdateChannel = defaults.bool(forKey: Self.serverPrereleaseChannelKey) ? .prerelease : .stable
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
        let serverPackage = serverUpdateChannel == .prerelease ? "pawterm-server@prerelease" : "pawterm-server@latest"
        proc.arguments = ["install", "-g", serverPackage]
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

    func updateServer() async {
        installLog = []
        status = .installing("Updating pawterm-server…")

        guard let serverURL = findExecutable("pawterm-server") else {
            await installServer()
            return
        }

        let proc = Process()
        proc.executableURL = serverURL
        proc.arguments = [
            "update",
            serverUpdateChannel == .prerelease ? "--prerelease" : "--latest",
        ]
        proc.environment = enrichedEnvironment()

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() } catch {
            status = .error("Failed to launch pawterm-server update: \(error.localizedDescription)")
            return
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
            installLog.append("Done. Server updated.")
            status = .running
            await poll()
        } else {
            let stderr = stderrLines.joined(separator: "\n")
            if stderr.contains("EACCES") || stderr.contains("permission") {
                status = .error("需要权限：终端运行 sudo pawterm-server update")
            } else if stderr.contains("ENOTFOUND") || stderr.contains("timeout") {
                status = .error("网络错误，请检查网络后重试")
            } else {
                status = .error("Update failed: \(stderrLines.last ?? "exit \(proc.terminationStatus)")")
            }
        }
    }

    // MARK: - Update Check

    func checkForUpdates() async {
        async let _ = checkServerUpdate()
        async let _ = checkAppUpdate()
    }

    func checkServerUpdateOnly() async {
        await checkServerUpdate()
    }

    func checkAppUpdateOnly() async {
        await checkAppUpdate()
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
        let serverTag = serverUpdateChannel == .prerelease ? "prerelease" : "latest"
        guard let url = URL(string: "https://registry.npmjs.org/pawterm-server/\(serverTag)") else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let latest = json["version"] as? String {
            latestServerVersion = latest
            if let current = currentServerVersion, !current.isEmpty {
                serverUpdateAvailable = Self.compareVersions(latest, current) == .orderedDescending
            }
        }
    }

    private func checkAppUpdate() async {
        if isDevBuild {
            latestAppVersion = nil
            latestAppReleaseTag = nil
            latestAppDownloadURL = nil
            appUpdateAvailable = false
            return
        }

        let urlString: String
        switch appUpdateChannel {
        case .stable:
            urlString = "https://api.github.com/repos/Airoucat233/pawterm/releases/latest"
        case .prerelease:
            urlString = "https://api.github.com/repos/Airoucat233/pawterm/releases"
        }

        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let release = parseMacAppRelease(from: data) else {
            latestAppVersion = nil
            latestAppReleaseTag = nil
            latestAppDownloadURL = nil
            appUpdateAvailable = false
            return
        }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        latestAppReleaseTag = release.tagName
        latestAppVersion = release.version
        latestAppDownloadURL = release.downloadURL
        appUpdateAvailable = Self.compareVersions(release.version, current) == .orderedDescending
    }

    private func parseMacAppRelease(from data: Data) -> (tagName: String, version: String, downloadURL: URL)? {
        switch appUpdateChannel {
        case .stable:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let asset = macAppAsset(fromRelease: json) else {
                return nil
            }
            return (tagName, asset.version, asset.downloadURL)
        case .prerelease:
            guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }
            for release in releases {
                guard (release["draft"] as? Bool) != true,
                      (release["prerelease"] as? Bool) == true,
                      let tagName = release["tag_name"] as? String,
                      tagName.hasPrefix("prerelease-v"),
                      let asset = macAppAsset(fromRelease: release) else {
                    continue
                }
                return (tagName, asset.version, asset.downloadURL)
            }
            return nil
        }
    }

    private func macAppAsset(fromRelease release: [String: Any]) -> (version: String, downloadURL: URL)? {
        guard let assets = release["assets"] as? [[String: Any]] else { return nil }
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let rawURL = asset["browser_download_url"] as? String,
                  let downloadURL = URL(string: rawURL) else { continue }
            if let version = macAppVersion(fromAssetName: name) {
                return (version, downloadURL)
            }
        }
        return nil
    }

    private func macAppVersion(fromAssetName name: String) -> String? {
        let pattern = #"^PawTerm-(?:prerelease-)?(.+)-mac\.zip$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else {
            return nil
        }
        return String(name[range])
    }

    enum MacAppUpdateError: LocalizedError {
        case devBuild
        case noUpdate
        case noDownloadURL
        case downloadFailed
        case unzipFailed
        case appNotFound
        case cannotLocateCurrentApp
        case relaunchFailed

        var errorDescription: String? {
            switch self {
            case .devBuild: return "Dev build does not support official Mac App updates."
            case .noUpdate: return "Mac App is already up to date."
            case .noDownloadURL: return "Release asset download URL is missing."
            case .downloadFailed: return "Failed to download Mac App update."
            case .unzipFailed: return "Failed to unzip Mac App update."
            case .appNotFound: return "Downloaded archive does not contain PawTerm.app."
            case .cannotLocateCurrentApp: return "Cannot locate current PawTerm.app."
            case .relaunchFailed: return "Failed to launch updater."
            }
        }
    }

    func updateMacApp() async throws {
        if isDevBuild { throw MacAppUpdateError.devBuild }
        if !appUpdateAvailable { await checkAppUpdate() }
        guard appUpdateAvailable else { throw MacAppUpdateError.noUpdate }
        guard let downloadURL = latestAppDownloadURL else { throw MacAppUpdateError.noDownloadURL }

        let previousStatus = status
        status = .installing("Downloading PawTerm update…")
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pawterm-mac-update-\(UUID().uuidString)", isDirectory: true)
        let zipURL = tmpRoot.appendingPathComponent("PawTerm-update.zip")
        let unzipDir = tmpRoot.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

        let downloaded: URL
        do {
            let (fileURL, _) = try await URLSession.shared.download(from: downloadURL)
            downloaded = fileURL
            try? FileManager.default.removeItem(at: zipURL)
            try FileManager.default.moveItem(at: downloaded, to: zipURL)
        } catch {
            status = previousStatus
            throw MacAppUpdateError.downloadFailed
        }

        status = .installing("Preparing PawTerm update…")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipURL.path, unzipDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            status = previousStatus
            throw MacAppUpdateError.unzipFailed
        }

        guard let newApp = findAppBundle(named: "PawTerm.app", under: unzipDir) else {
            status = previousStatus
            throw MacAppUpdateError.appNotFound
        }
        let currentApp = Bundle.main.bundleURL
        guard currentApp.pathExtension == "app" else {
            status = previousStatus
            throw MacAppUpdateError.cannotLocateCurrentApp
        }

        status = .installing("Installing PawTerm update…")
        try launchReplacementScript(newApp: newApp, currentApp: currentApp, tmpRoot: tmpRoot)
        NSApplication.shared.terminate(nil)
    }

    private func findAppBundle(named name: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == name && url.pathExtension == "app" {
                return url
            }
        }
        return nil
    }

    private func launchReplacementScript(newApp: URL, currentApp: URL, tmpRoot: URL) throws {
        let scriptURL = tmpRoot.appendingPathComponent("install-update.sh")
        let script = """
        #!/bin/zsh
        set -e
        sleep 1
        /bin/rm -rf "\(currentApp.path)"
        /usr/bin/ditto "\(newApp.path)" "\(currentApp.path)"
        /usr/bin/xattr -d com.apple.quarantine "\(currentApp.path)" 2>/dev/null || true
        /usr/bin/open "\(currentApp.path)"
        /bin/rm -rf "\(tmpRoot.path)"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = [scriptURL.path]
        do {
            try proc.run()
        } catch {
            throw MacAppUpdateError.relaunchFailed
        }
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        struct ParsedVersion {
            let parts: [Int]
            let preNumber: Int?
        }

        func parse(_ value: String) -> ParsedVersion {
            let semantic = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
            let base = semantic.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
            var preNumber: Int? = nil
            if let range = semantic.range(of: #"-(?:prerelease|pre|rc)\.(\d+)$"#, options: .regularExpression),
               let suffix = semantic[range].split(separator: ".").last {
                preNumber = Int(suffix)
            }
            return ParsedVersion(
                parts: base.split(separator: ".").map { Int($0) ?? 0 },
                preNumber: preNumber
            )
        }
        let leftVersion = parse(lhs)
        let rightVersion = parse(rhs)
        let left = leftVersion.parts
        let right = rightVersion.parts
        let count = max(left.count, right.count)
        for i in 0..<count {
            let a = i < left.count ? left[i] : 0
            let b = i < right.count ? right[i] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        if leftVersion.preNumber == nil && rightVersion.preNumber != nil { return .orderedDescending }
        if leftVersion.preNumber != nil && rightVersion.preNumber == nil { return .orderedAscending }
        if let leftPre = leftVersion.preNumber, let rightPre = rightVersion.preNumber {
            if leftPre < rightPre { return .orderedAscending }
            if leftPre > rightPre { return .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Pairing PIN

    func requestPairWindow() async -> (pin: String, expiresAt: Int)? {
        guard let token = config.token, !token.isEmpty,
              let url = URL(string: "http://127.0.0.1:\(config.port)/api/admin/pair-window") else { return nil }
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
              let url = URL(string: "http://127.0.0.1:\(config.port)/api/admin/login-codes") else { return nil }
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
              let url = URL(string: "http://127.0.0.1:\(config.port)/api/admin/events") else { return }
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
              let url = URL(string: "http://localhost:\(config.port)/api/admin/pair-approve") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["requestId": requestId])
        _ = try? await URLSession.shared.data(for: req)
    }

    func denyPairRequest(requestId: String) async {
        guard let token = config.token, !token.isEmpty,
              let url = URL(string: "http://localhost:\(config.port)/api/admin/pair-deny") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["requestId": requestId])
        _ = try? await URLSession.shared.data(for: req)
    }

    func revokeDevice(_ deviceId: String) async {
        guard let token = config.token, !token.isEmpty,
              let url = URL(string: "http://localhost:\(config.port)/api/admin/devices/\(deviceId)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
        // SSE device_revoked will update pairedDevices list
    }

    // MARK: - Fetch Paired Devices

    private func fetchPairedDevices() async {
        guard let token = config.token, !token.isEmpty,
              let url = URL(string: "http://127.0.0.1:\(config.port)/api/admin/devices") else { return }
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
