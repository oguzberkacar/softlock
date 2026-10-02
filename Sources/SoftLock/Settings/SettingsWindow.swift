//
//  SettingsWindow.swift
//
//  Hosts the SwiftUI settings panes in a System Settings-style window: a translucent sidebar
//  that runs the full height under a unified title bar, and the pane's name as the window
//  title. The window is created once and reused, so reopening it from the menu bar never
//  jumps it around.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    private let window: NSWindow
    private var cancellables: Set<AnyCancellable> = []

    init(
        settings: AppSettings,
        onLock: @escaping () -> Void,
        onChangePasscode: @escaping () -> Void,
        onDeleteApp: @escaping () -> Void
    ) {
        model = SettingsModel(settings: settings, onLock: onLock, onChangePasscode: onChangePasscode, onDeleteApp: onDeleteApp)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        model.hostWindow = window
        configureWindow()
    }

    private func configureWindow() {
        window.title = model.selection.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 640, height: 420)
        window.titlebarSeparatorStyle = .automatic
        // An (empty) unified toolbar is what gives the tall title bar and lets the sidebar
        // extend underneath it, the way System Settings does.
        let toolbar = NSToolbar(identifier: "SoftLockSettingsToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: SettingsRootView(model: model))
        // The hosting controller sizes the window to its ideal content; pin the intended size.
        window.setContentSize(NSSize(width: 720, height: 600))

        model.$selection
            .removeDuplicates()
            .sink { [weak self] pane in
                self?.window.title = pane.title
            }
            .store(in: &cancellables)
    }

    func show() {
        // Permissions, displays and cameras may have changed while the window was closed.
        model.refresh()
        // Only place the window when it first appears — re-centering an already-open window
        // (e.g. picking "Settings" from the menu again) made it jump under the user.
        if !window.isVisible {
            window.centerOnActiveScreen()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing while a shortcut recorder is armed would leave the global hot keys suspended
        // (the recorder's "stopped recording" callback never fires on a closed window).
        HotKeyCenter.shared.resume()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
    }
}
