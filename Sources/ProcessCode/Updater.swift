import AppKit
import Combine
import Sparkle

/// Gets new versions of the app, with Sparkle: it reads the release feed, and when there is a newer
/// version it asks, then downloads it, checks its signature, replaces the app and opens it again.
///
/// It looks twice only: once as the app opens, and when asked to in Settings or the app menu. Sparkle's
/// own daily schedule is off (`SUEnableAutomaticChecks` in Info.plist, written by build-app.sh).
///
/// Only a released build has a feed to read. One built here, or the bare binary the tests and the
/// snapshots run, has none, so it never looks and never reaches the network.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// Whether a check can start now: false in a build with no feed, and while one is under way.
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?

    /// The version to show, or nil for the bare binary, which has no Info.plist.
    static var version: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    /// Whether this build has a feed to update from.
    static var hasFeed: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    /// Called once as the app opens: starts Sparkle and looks for a new version without showing
    /// anything unless there is one.
    func start() {
        guard controller == nil, AppUpdater.hasFeed else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        controller.updater.checkForUpdatesInBackground()
    }

    /// The check someone asked for: it shows its progress, and says so when there is nothing newer.
    func check() { controller?.checkForUpdates(nil) }
}
