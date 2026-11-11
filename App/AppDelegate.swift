import AppKit
import SwiftUI
import ServiceManagement
import PPasteCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: ClipStore!
    private var watcher: PasteboardWatcher!
    private var shelf: ShelfController!
    private var hotKeys: [HotKey] = []
    private var statusItem: NSStatusItem!
    private var loginItem: NSMenuItem!
    private var previewItem: NSMenuItem!
    private var fetcher: LinkPreviewFetcher!
    private var linkPreviewDir: URL!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // PPASTE_DATA_DIR runs against a separate data folder (used for demos/screenshots and testing).
        // In that mode the clipboard watcher is off, so the real clipboard never leaks into the demo data.
        let dataDirOverride = ProcessInfo.processInfo.environment["PPASTE_DATA_DIR"]
        let support = dataDirOverride.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ppaste", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        do { store = try ClipStore(path: support.appendingPathComponent("history.sqlite").path) }
        catch { NSAlert(error: error).runModal(); NSApp.terminate(nil); return }

        let imageDir = support.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        linkPreviewDir = support.appendingPathComponent("link-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: linkPreviewDir, withIntermediateDirectories: true)
        fetcher = LinkPreviewFetcher(store: store, imageDir: linkPreviewDir)
        watcher = PasteboardWatcher(store: store, imageDir: imageDir)
        watcher.onLinkSaved = { [weak self] item in self?.fetcher.enqueue(item) }
        if dataDirOverride == nil { watcher.start() }
        pruneImages(in: imageDir)
        let pruneTimer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            if let self { self.pruneImages(in: imageDir) }
        }
        pruneTimer.tolerance = 600
        RunLoop.main.add(pruneTimer, forMode: .common)

        shelf = ShelfController(store: store, watcher: watcher, fetcher: fetcher)
        registerHotKeys()
        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKeys()
        }

        if let out = ProcessInfo.processInfo.environment["PPASTE_SNAPSHOT_FILE"] {
            // Demo/docs only: open the shelf (optionally on a pinboard tab), write a PNG, quit.
            let board = ProcessInfo.processInfo.environment["PPASTE_SNAPSHOT_PINBOARD"].flatMap(Int.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.shelf.toggle() }
            if let board { DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.shelf.selectPinboard(at: board) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.shelf.snapshot(to: out)
                NSApp.terminate(nil)
            }
        } else if ProcessInfo.processInfo.environment["PPASTE_SHOW_SHELF"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.shelf.toggle() }
        }

        if let out = ProcessInfo.processInfo.environment["PPASTE_SETTINGS_SNAPSHOT"] {
            // Dev only: render the settings window to a PNG and quit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openSettings() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                if let v = self?.settingsWindow?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                NSApp.terminate(nil)
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ppaste")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Clipboard History", action: #selector(show), keyEquivalent: "").target = self
        menu.addItem(.separator())
        loginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        previewItem = menu.addItem(withTitle: "Fetch Link Previews", action: #selector(toggleLinkPreviews), keyEquivalent: "")
        previewItem.target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Clear All History…", action: #selector(clearAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit ppaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
    }

    private var settingsWindow: NSWindow?

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "ppaste Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// (Re)registers the global shortcuts from settings. Dropping the old HotKey objects unregisters them.
    private func registerHotKeys() {
        hotKeys = [AppSettings.primaryShortcut, AppSettings.alternateShortcut].compactMap { $0 }.map { sc in
            HotKey(keyCode: sc.keyCode, modifiers: sc.modifiers) { [weak self] in self?.shelf.toggle() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        previewItem.state = LinkPreviewSettings.isEnabled ? .on : .off
    }

    @objc private func toggleLinkPreviews() {
        LinkPreviewSettings.isEnabled.toggle()
        previewItem.state = LinkPreviewSettings.isEnabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText = "Launch at login only works when ppaste is installed in /Applications.\n\n" + error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func show() { shelf.toggle() }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This permanently deletes every saved item."
        alert.addButton(withTitle: "Clear All"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            try? store.deleteAll()
            for url in (try? FileManager.default.contentsOfDirectory(at: linkPreviewDir, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Images are kept for the configured retention (default 30 days); text and links are kept forever.
    private func pruneImages(in dir: URL) {
        let days = AppSettings.imageRetentionDays
        guard days > 0 else { return } // "Forever"
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for path in (try? store.pruneImages(olderThan: cutoff)) ?? [] {
            try? FileManager.default.removeItem(atPath: path)
        }
        // Link preview images follow the same 30-day rule; the link clip and its title are kept.
        for path in (try? store.pruneLinkPreviewImages(olderThan: cutoff)) ?? [] {
            try? FileManager.default.removeItem(atPath: path)
        }
        // Safety net so the folder can never grow without bound: drop any stray file older than the cutoff.
        let files = (try? FileManager.default.contentsOfDirectory(
            at: linkPreviewDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files {
            if let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
