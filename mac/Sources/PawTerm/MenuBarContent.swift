import SwiftUI

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
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
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
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
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
            Text("Installing… ⏳")
                .disabled(true)
            Text(msg.isEmpty ? "Please wait…" : msg)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .disabled(true)
        }
    }

    // MARK: - Normal (stopped / starting / running / error)

    private var normalSection: some View {
        Group {
            // Update banner
            if serverManager.updateAvailable,
               let current = serverManager.currentServerVersion,
               let latest = serverManager.latestServerVersion {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(.orange)
                    Text("Update available: v\(current) → v\(latest)")
                        .foregroundColor(.orange)
                }
                .disabled(true)

                Button("Update Server…") {
                    Task { await serverManager.updateServer() }
                }

                Divider()
            }

            // Status line
            Group {
                switch serverManager.status {
                case .running:
                    Text("Status: Running on localhost:\(serverManager.port)")
                case .starting:
                    Text("Status: Starting…")
                case .stopped:
                    Text("Status: Not running")
                case .error(let msg):
                    Text("Status: Error — \(msg)")
                        .foregroundColor(.red)
                default:
                    EmptyView()
                }
            }
            .disabled(true)

            Text("Devices: \(serverManager.deviceCount) paired")
                .disabled(true)

            Divider()

            Button("Open Admin…") { openAdmin() }
                .disabled(!serverManager.isRunning)

            Button("Show QR…") { openAdminQR() }
                .disabled(!serverManager.isRunning)

            Button("Show PIN…") { showPin() }
                .disabled(!serverManager.isRunning)

            Divider()

            if !serverManager.isRunning {
                Button("Start Server") {
                    Task { await serverManager.start() }
                }
            } else {
                Button("Stop Server") {
                    Task { await serverManager.stop() }
                }
            }

            Button("Restart Server") {
                Task { await serverManager.restart() }
            }

            Divider()

            Button("Check for Updates…") {
                Task {
                    await serverManager.checkForUpdates()
                    await MainActor.run { showUpdateResult() }
                }
            }

            Divider()

            Button("About PawTerm…") {
                NSWorkspace.shared.open(URL(string: "https://github.com/Airoucat233/pawterm")!)
            }

            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    // MARK: - Actions

    private func openAdmin() {
        guard let url = AdminURL.adminURL() else { return }
        NSWorkspace.shared.open(url)
    }

    private func openAdminQR() {
        guard let base = AdminURL.adminURL() else { return }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.fragment = "qr"
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    private func showPin() {
        Task {
            if let res = await serverManager.requestPairWindow() {
                let spaced = res.pin.map(String.init).joined(separator: " ")
                Alerts.info(
                    "配对 PIN",
                    "\(spaced)\n\n5 分钟内有效。在手机端 PairSheet 输入此 PIN。"
                )
            } else {
                Alerts.info(
                    "无法获取 PIN",
                    "Server 未响应或版本过旧（需要 pawterm-server 0.6+）。\n请确认服务端正在运行新版本。"
                )
            }
        }
    }

    @MainActor
    private func showUpdateResult() {
        if serverManager.updateAvailable,
           let current = serverManager.currentServerVersion,
           let latest = serverManager.latestServerVersion {
            let doUpdate = Alerts.confirm(
                "Update Available",
                "Update available: v\(current) → v\(latest)",
                confirmText: "Update Now"
            )
            if doUpdate {
                Task { await serverManager.updateServer() }
            }
        } else if let current = serverManager.currentServerVersion {
            Alerts.info("Up to Date", "PawTerm Server is up to date (v\(current))")
        } else {
            Alerts.info("Check Complete", "Could not determine current version.")
        }
    }
}
