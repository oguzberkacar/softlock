//
//  UpdaterController.swift
//
//  Sparkle auto-update. The app checks the appcast in the background and asks before it
//  installs anything: a lock app that silently replaced itself would be a poor trade.
//  The feed URL and the EdDSA public key live in Info.plist (see scripts/package-app.sh);
//  every update is verified against that key before it is unpacked.
//

import AppKit
import Sparkle

@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController

    /// Sparkle needs a real app bundle (Info.plist with the feed URL and key). A bare
    /// `swift run` / `.build/debug` binary has none, and Sparkle would pop "Unable to Check
    /// For Updates" on every launch, so the updater stays idle there.
    private static let isBundledApp = Bundle.main.bundleURL.pathExtension == "app"

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isBundledApp, updaterDelegate: nil, userDriverDelegate: nil)
        // Default to daily checks without Sparkle's own "check automatically?" prompt — but only
        // until the user has made a choice (Settings → General), which Sparkle stores under
        // this key. Forcing it on every launch used to undo that choice.
        if Self.isBundledApp, UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil {
            controller.updater.automaticallyChecksForUpdates = true
        }
        // Downloading without asking still shows the install prompt; it only makes the
        // "Install" click instant instead of starting a download.
        controller.updater.automaticallyDownloadsUpdates = false
    }

    /// Called at launch so the background check schedule starts.
    func start() {}

    var canCheckForUpdates: Bool { Self.isBundledApp && controller.updater.canCheckForUpdates }

    /// The daily background check. Off still leaves "Check for Updates…" in the menu bar.
    var automaticallyChecksForUpdates: Bool {
        get { Self.isBundledApp && controller.updater.automaticallyChecksForUpdates }
        set { if Self.isBundledApp { controller.updater.automaticallyChecksForUpdates = newValue } }
    }

    func checkForUpdates() {
        guard Self.isBundledApp else { return }
        controller.updater.checkForUpdates()
    }
}
