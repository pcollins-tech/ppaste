import AppKit
import SwiftUI
import ApplicationServices
import PPasteCore

/// Borderless panel that can take keyboard focus (for search) without activating the app.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ShelfController {
    private let store: ClipStore
    private let watcher: PasteboardWatcher
    private var panel: ShelfPanel?
    private var previousApp: NSRunningApplication?
    private var clickMonitor: Any?
    private let model = ShelfModel()

    private let fetcher: LinkPreviewFetcher

    init(store: ClipStore, watcher: PasteboardWatcher, fetcher: LinkPreviewFetcher) {
        self.store = store; self.watcher = watcher; self.fetcher = fetcher
        model.store = store
        fetcher.onChange = { [weak self] in
            guard let self else { return }
            self.model.pendingIDs = self.fetcher.pendingIDs
            if self.panel?.isVisible == true { self.model.reload() } // a preview arrived while the shelf is open
        }
        model.onPaste = { [weak self] item, plain in self?.paste(item, plainText: plain) }
        model.onClose = { [weak self] in self?.hide() }
        watcher.onChange = { [weak self] in
            guard self?.panel?.isVisible == true else { return }
            self?.model.reload() // live-update the shelf if it's open while you copy
        }
    }

    /// Dev/demo only: render the shelf to a PNG over a plain backdrop (no screen-recording permission needed).
    func selectPinboard(at index: Int) {
        if model.pinboards.indices.contains(index), let id = model.pinboards[index].id { model.select(.pinboard(id)) }
    }

    func snapshot(to path: String) {
        guard let view = panel?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let inset: CGFloat = 40
        let size = NSSize(width: view.bounds.width + inset * 2, height: view.bounds.height + inset * 2)
        let out = NSImage(size: size)
        out.lockFocus()
        NSGradient(colors: [NSColor(red: 0.20, green: 0.16, blue: 0.45, alpha: 1), NSColor(red: 0.06, green: 0.20, blue: 0.40, alpha: 1)])!
            .draw(in: NSRect(origin: .zero, size: size), angle: -30)
        NSColor(white: 0.10, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: view.bounds.width, height: view.bounds.height), xRadius: 22, yRadius: 22).fill()
        NSImage(size: view.bounds.size, flipped: false) { _ in rep.draw(in: NSRect(origin: .zero, size: view.bounds.size)); return true }
            .draw(at: NSPoint(x: inset, y: inset), from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    func toggle() { panel?.isVisible == true ? hide() : show() }

    private func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        model.pendingIDs = fetcher.pendingIDs
        model.reset()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let height: CGFloat = 380 // room for the pinboard tab strip
        let frame = NSRect(x: screen.frame.minX + 8, y: screen.frame.minY + 8,
                           width: screen.frame.width - 16, height: height)
        if panel == nil {
            let p = ShelfPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: ShelfView(model: model))
            panel = p
        }
        panel?.setFrame(frame, display: true)
        panel?.makeKeyAndOrderFront(nil)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    private func paste(_ item: ClipItem, plainText: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text, .link: pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let path = item.imagePath, let img = NSImage(contentsOfFile: path) { pb.writeObjects([img]) }
        }
        watcher.ignoreCurrentChange()
        try? store.save(item) // bump to top
        hide()

        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        else { return } // copied to clipboard; user can Cmd+V once Accessibility is granted
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        }
    }
}
