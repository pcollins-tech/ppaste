import AppKit
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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
        watcher.start()
        pruneImages(in: imageDir)
        let pruneTimer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            if let self { self.pruneImages(in: imageDir) }
        }
        pruneTimer.tolerance = 600
        RunLoop.main.add(pruneTimer, forMode: .common)

        shelf = ShelfController(store: store, watcher: watcher, fetcher: fetcher)
        for mods: NSEvent.ModifierFlags in [[.command, .shift], [.control, .shift]] {
            hotKeys.append(HotKey(keyCode: 9 /* V */, modifiers: mods) { [weak self] in self?.shelf.toggle() })
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
        menu.addItem(withTitle: "Clear All History…", action: #selector(clearAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit ppaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
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

    /// Images are only kept for 30 days; text and links are kept forever.
    private func pruneImages(in dir: URL) {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
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
