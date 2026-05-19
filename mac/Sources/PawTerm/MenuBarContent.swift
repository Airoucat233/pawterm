import SwiftUI
import UniformTypeIdentifiers

struct MenuBarContent: View {
    @EnvironmentObject var serverManager: ServerManager

    var body: some View {
        switch serverManager.status {
        case .nodeNotInstalled:
            nodeNotInstalledSection
        case .notInstalled:
            notInstalledSection
        case .installing(let msg):
            installingSection(msg)
        default:
            normalSection
        }
    }

    // MARK: - Node not installed

    private var nodeNotInstalledSection: some View {
        Group {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text("Node.js not installed")
            }
            .disabled(true)
            Divider()
            Button("Install Node.js via Homebrew…") {
                Task { await serverManager.installNodeViaHomebrew() }
            }
            Button("Download Node.js…") {
                NSWorkspace.shared.open(URL(string: "https://nodejs.org/")!)
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    // MARK: - Server not installed

    private var notInstalledSection: some View {
        Group {
            HStack {
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
                Text("Server not installed")
            }
            .disabled(true)
            Divider()
            Button("Install Server…") {
                Task { await serverManager.installServer() }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    // MARK: - Installing

    private func installingSection(_ msg: String) -> some View {
        Group {
            Text("Installing… ⏳").disabled(true)
            Text(msg.isEmpty ? "Please wait…" : msg)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(2).disabled(true)
        }
    }

    // MARK: - Normal

    private var normalSection: some View {
        Group {
            // App update banner
            if serverManager.appUpdateAvailable, let latest = serverManager.latestAppVersion {
                HStack {
                    Image(systemName: "arrow.up.circle.fill").foregroundColor(.blue)
                    Text("App update v\(latest) available").foregroundColor(.blue)
                }
                .disabled(true)
                Button("Download App…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Airoucat233/pawterm/releases/latest")!)
                }
                Divider()
            }

            // Server update banner
            if serverManager.serverUpdateAvailable,
               let current = serverManager.currentServerVersion,
               let latest = serverManager.latestServerVersion {
                HStack {
                    Image(systemName: "arrow.up.circle.fill").foregroundColor(.orange)
                    Text("Server v\(current) → v\(latest)").foregroundColor(.orange)
                }
                .disabled(true)
                Button("Update Server…") {
                    Task { await serverManager.updateServer() }
                }
                Divider()
            }

            // Status line: NSImage baked color bypasses NSMenu template recoloring
            Button(action: {}) {
                HStack(spacing: 5) {
                    Image(nsImage: dotImage(color: statusDotNSColor, size: 7))
                    Text(statusText)
                    if let ver = serverManager.currentServerVersion {
                        Text("v\(ver)").foregroundColor(.secondary).font(.caption)
                    }
                }
            }

            Menu("Devices: \(serverManager.pairedDevices.count) paired") {
                if serverManager.pairedDevices.isEmpty {
                    Text("No paired devices").disabled(true)
                } else {
                    ForEach(serverManager.pairedDevices) { device in
                        Menu(device.name) {
                            Button("Revoke") {
                                Task { await serverManager.revokeDevice(device.deviceId) }
                            }
                        }
                    }
                }
            }
            .disabled(!serverManager.isRunning)

            Divider()

            Button("Open Admin…") { openAdmin() }
                .disabled(!serverManager.isRunning)
            Button("Show QR…") { openAdminQR() }
                .disabled(!serverManager.isRunning)
            Button("Show PIN…") { showPin() }
                .disabled(!serverManager.isRunning)

            Divider()

            if case .stopping = serverManager.status {
                Button("Stopping…") {}.disabled(true)
            } else if !serverManager.isRunning {
                Button("Start Server") { Task { await serverManager.start() } }
            } else {
                Button("Stop Server") { Task { await serverManager.stop() } }
            }
            Button("Restart Server") { Task { await serverManager.restart() } }
                .disabled(!serverManager.isRunning)

            Divider()

            // Config management
            Menu("Config") {
                Picker("", selection: Binding(
                    get: { serverManager.configPath },
                    set: { serverManager.reloadConfig(from: $0) }
                )) {
                    ForEach(serverManager.availableConfigs, id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Edit Config…") { editConfig() }
                Button("New Config…") { newConfig() }
            }

            Divider()

            Button("Check for Updates…") {
                Task {
                    await serverManager.checkForUpdates()
                    showUpdateResult()
                }
            }

            Button("About PawTerm…") {
                NSWorkspace.shared.open(URL(string: "https://github.com/Airoucat233/pawterm")!)
            }

            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    // MARK: - Status helpers

    private var statusDotNSColor: NSColor {
        switch serverManager.status {
        case .running:  return .systemGreen
        case .starting: return .systemYellow
        case .stopping: return .systemYellow
        case .error:    return .systemRed
        default:        return .secondaryLabelColor
        }
    }

    private func dotImage(color: NSColor, size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    private var statusText: String {
        switch serverManager.status {
        case .running:        return "Running on :\(serverManager.port)"
        case .starting:       return "Starting…"
        case .stopping:       return "Stopping…"
        case .stopped:        return "Stopped"
        case .error(let msg): return "Error — \(msg)"
        default:              return ""
        }
    }

    // MARK: - Admin actions

    private func openAdmin() {
        guard let token = token, let url = AdminURL.adminURL(port: serverManager.port, token: token) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openAdminQR() {
        guard let token = token,
              let base = AdminURL.adminURL(port: serverManager.port, token: token),
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        comps.fragment = "qr"
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    private var token: String? {
        // Read fresh from config file so token changes after restart are picked up
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: serverManager.configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = json["token"] as? String, !t.isEmpty else { return nil }
        return t
    }

    private func showPin() {
        Task {
            if let res = await serverManager.requestPairWindow() {
                let spaced = res.pin.map(String.init).joined(separator: " ")
                Alerts.info("配对 PIN", "\(spaced)\n\n5 分钟内有效。在手机端输入此 PIN。")
            } else {
                Alerts.info("无法获取 PIN", "Server 未响应或版本过旧（需要 pawterm-server 0.6+）。")
            }
        }
    }

    // MARK: - Config management

    private func switchConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.directoryURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.config/pawterm")
        panel.title = "Select PawTerm Config"
        if panel.runModal() == .OK, let url = panel.url {
            serverManager.reloadConfig(from: url.path)
        }
    }

    private func editConfig() {
        let url = URL(fileURLWithPath: serverManager.configPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Alerts.info("Config Not Found", "Start the server first — it will create the config file automatically.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func newConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "config.json"
        panel.directoryURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.config/pawterm")
        panel.title = "New PawTerm Config"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let template: [String: Any] = [
            "port": 8765,
            "token": "your-token-here"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: template, options: .prettyPrinted) {
            try? data.write(to: url)
        }
        NSWorkspace.shared.open(url)
        serverManager.reloadConfig(from: url.path)
        serverManager.refreshAvailableConfigs()
    }

    // MARK: - Update result dialog

    @MainActor
    private func showUpdateResult() {
        var parts: [String] = []
        if serverManager.serverUpdateAvailable,
           let c = serverManager.currentServerVersion, let l = serverManager.latestServerVersion {
            parts.append("Server: v\(c) → v\(l)")
        }
        if serverManager.appUpdateAvailable, let l = serverManager.latestAppVersion {
            parts.append("Mac App: v\(l) available")
        }
        if parts.isEmpty {
            let ver = serverManager.currentServerVersion.map { " (v\($0))" } ?? ""
            Alerts.info("Up to Date", "PawTerm Server\(ver) is up to date.")
        } else {
            Alerts.info("Updates Available", parts.joined(separator: "\n"))
        }
    }
}
