import AppKit
import PPasteCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ClipStore!
    private var watcher: PasteboardWatcher!
    private var shelf: ShelfController!
    private var hotKeys: [HotKey] = []
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ppaste", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        do { store = try ClipStore(path: support.appendingPathComponent("history.sqlite").path) }
        catch { NSAlert(error: error).runModal(); NSApp.terminate(nil); return }

        let imageDir = support.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        watcher = PasteboardWatcher(store: store, imageDir: imageDir)
        watcher.start()
        pruneImages(in: imageDir)

        shelf = ShelfController(store: store, watcher: watcher)
        for mods: NSEvent.ModifierFlags in [[.command, .shift], [.control, .shift]] {
            hotKeys.append(HotKey(keyCode: 9 /* V */, modifiers: mods) { [weak self] in self?.shelf.toggle() })
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ppaste")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Clipboard History", action: #selector(show), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear All History…", action: #selector(clearAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit ppaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func show() { shelf.toggle() }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This permanently deletes every saved item."
        alert.addButton(withTitle: "Clear All"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { try? store.deleteAll() }
    }

    /// Images are only kept for 30 days; text and links are kept forever.
    private func pruneImages(in dir: URL) {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        for path in (try? store.pruneImages(olderThan: cutoff)) ?? [] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
