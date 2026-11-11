import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var primary = AppSettings.primaryShortcut
    @State private var alternate = AppSettings.alternateShortcut
    @State private var ignored = AppSettings.ignoredBundleIDs
    @State private var retention = AppSettings.imageRetentionDays
    @State private var previews = LinkPreviewSettings.isEnabled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var pendingLogin = false

    var body: some View {
        Form {
            Section("Shortcuts") {
                HStack { Text("Open history"); Spacer(); ShortcutRecorder(shortcut: $primary) }
                HStack { Text("Alternate"); Spacer(); ShortcutRecorder(shortcut: $alternate) }
                Text("Click a field, then press the new shortcut. Esc cancels; the ✕ clears it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)) {
                    HStack(spacing: 6) {
                        Text("Launch at login")
                        if pendingLogin { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(pendingLogin)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Fetch link previews", isOn: $previews)
                Picker("Keep images for", selection: $retention) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("Forever").tag(0)
                }
                Text("Text and links are always kept. Pinned images are never removed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignored apps") {
                Label("Password managers (1Password, Bitwarden, KeePassXC, Keychain, Passwords)", systemImage: "lock.fill")
                    .foregroundStyle(.secondary).font(.callout)
                ForEach(ignored, id: \.self) { id in
                    HStack {
                        Text(Self.appName(id))
                        Spacer()
                        Button { ignored.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Stop ignoring this app")
                    }
                }
                Button("Add App…", action: addApp)
                Text("Copies made while these apps are frontmost are never saved. Password managers are always ignored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 570)
        .onChange(of: primary) { _, v in AppSettings.primaryShortcut = v }
        .onChange(of: alternate) { _, v in AppSettings.alternateShortcut = v }
        .onChange(of: ignored) { _, v in AppSettings.ignoredBundleIDs = v }
        .onChange(of: retention) { _, v in AppSettings.imageRetentionDays = v }
        .onChange(of: previews) { _, v in LinkPreviewSettings.isEnabled = v }
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        pendingLogin = true; loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Only works when ppaste is installed in /Applications. " + error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        pendingLogin = false
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Ignore"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            if !ignored.contains(id), !PasteboardWatcher.ignoredBundleIDs.contains(id) { ignored.append(id) }
        }
    }

    static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

/// Click-to-record shortcut field.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false

    var body: some View {
        HStack(spacing: 4) {
            RecorderField(shortcut: $shortcut, recording: $recording)
                .frame(width: 130, height: 24)
            if shortcut != nil {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Clear shortcut")
            }
        }
    }
}

private struct RecorderField: NSViewRepresentable {
    @Binding var shortcut: Shortcut?
    @Binding var recording: Bool

    func makeNSView(context: Context) -> RecorderNSView {
        let v = RecorderNSView()
        v.onCapture = { shortcut = $0 }
        v.onRecordingChange = { recording = $0 }
        return v
    }
    func updateNSView(_ v: RecorderNSView, context: Context) {
        v.onCapture = { shortcut = $0 }
        v.shortcut = shortcut
        v.isRecording = recording
        v.needsDisplay = true
    }
}

final class RecorderNSView: NSView {
    var shortcut: Shortcut?
    var isRecording = false
    var onCapture: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        setRecording(true)
    }
    override func resignFirstResponder() -> Bool { setRecording(false); return super.resignFirstResponder() }

    private func setRecording(_ on: Bool) {
        guard isRecording != on else { return }
        isRecording = on; onRecordingChange?(on); needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { setRecording(false); window?.makeFirstResponder(nil); return } // Esc
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Require a real modifier so a plain letter can't hijack typing everywhere.
        guard !mods.isDisjoint(with: [.command, .control, .option]) else { NSSound.beep(); return }
        let label = Self.label(for: event)
        onCapture?(Shortcut(keyCode: UInt32(event.keyCode), modifiersRaw: mods.rawValue, keyLabel: label))
        setRecording(false)
        window?.makeFirstResponder(nil)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }

    private static func label(for event: NSEvent) -> String {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                         122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                         101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        return special[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()
        let text = isRecording ? "Press shortcut…" : (shortcut?.display ?? "Click to record")
        let color: NSColor = (shortcut == nil && !isRecording) ? .secondaryLabelColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
