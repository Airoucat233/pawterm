import SwiftUI

@main
struct PawTermApp: App {
    @StateObject private var serverManager = ServerManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(serverManager)
        } label: {
            MenuBarIcon()
                .environmentObject(serverManager)
        }
        .menuBarExtraStyle(.menu)
        .defaultAppStorage(.standard)
        // onAppear equivalent for scenes: use task modifier
        .commands {
            // no custom commands needed
        }
    }

    init() {
        // Kick off prerequisite detection + update check after init
        // The @StateObject is not yet available here; use a Task that runs
        // after the run loop starts, picking up the manager via a local ref.
    }
}

struct MenuBarIcon: View {
    @EnvironmentObject var serverManager: ServerManager

    var body: some View {
        Image(systemName: "pawprint.fill")
            .foregroundStyle(iconColor)
            .task {
                // Runs once when icon appears (app launch)
                await serverManager.detectPrerequisites()
                await serverManager.checkForUpdates()
            }
    }

    private var iconColor: Color {
        switch serverManager.status {
        case .running:
            return serverManager.deviceCount > 0 ? .green : .blue
        case .starting:
            return .yellow
        case .installing:
            return .yellow
        case .stopped, .error, .notInstalled, .nodeNotInstalled:
            return .secondary
        }
    }
}
