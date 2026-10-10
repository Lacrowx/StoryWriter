import SwiftUI
import Sparkle

/// Sparkle owns update preferences, signature verification, installation and relaunch.
@MainActor
final class AppUpdates: ObservableObject {
    static let shared = AppUpdates()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    private let controller: SPUStandardUpdaterController
    private var started = false

    var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String &&
        Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String
    }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
    }

    func start() {
        guard !started, isConfigured else { return }
        started = true
        controller.startUpdater()
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled }
}

struct UpdateSettings: View {
    @ObservedObject private var updates = AppUpdates.shared
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }

    var body: some View {
        Section("App updates") {
            Text("StoryWriter \(version)").font(.headline)
            Toggle("Automatically check for updates", isOn: Binding(get: { updates.automaticallyChecksForUpdates }, set: updates.setAutomaticChecks))
                .disabled(!updates.isConfigured)
            Toggle("Automatically download and install updates", isOn: Binding(get: { updates.automaticallyDownloadsUpdates }, set: updates.setAutomaticDownloads))
                .disabled(!updates.isConfigured || !updates.automaticallyChecksForUpdates)
            Text("Downloaded updates are verified before installation. StoryWriter saves your writing before quitting to complete an update.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check for Updates…", action: updates.checkForUpdates).disabled(!updates.canCheckForUpdates)
            if !updates.isConfigured {
                Text("Updates are available in release builds. This development build has no update feed configured.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
