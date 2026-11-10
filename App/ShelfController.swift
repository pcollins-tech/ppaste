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

    init(store: ClipStore, watcher: PasteboardWatcher) {
        self.store = store; self.watcher = watcher
        model.store = store
        model.onPaste = { [weak self] item, plain in self?.paste(item, plainText: plain) }
        model.onClose = { [weak self] in self?.hide() }
    }

    func toggle() { panel?.isVisible == true ? hide() : show() }

    private func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        model.reset()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let height: CGFloat = 340
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
