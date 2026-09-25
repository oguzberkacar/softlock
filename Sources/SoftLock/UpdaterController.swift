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

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = true
        // Downloading without asking still shows the install prompt; it only makes the
        // "Install" click instant instead of starting a download.
        controller.updater.automaticallyDownloadsUpdates = false
    }

    /// Called at launch so the background check schedule starts.
    func start() {}

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
