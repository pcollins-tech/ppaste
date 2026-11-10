import SwiftUI
import PPasteCore

enum ShelfTab: Hashable {
    case clipboard
    case pinboard(Int64)
}

enum TabEdit: Equatable {
    case create
    case rename(Int64)
}

final class ShelfModel: ObservableObject {
    var store: ClipStore!
    var onPaste: ((ClipItem, Bool) -> Void)?
    var onClose: (() -> Void)?
    @Published var items: [ClipItem] = []
    @Published var query = "" { didSet { reload() } }
    @Published var selection = 0
    /// Link clips whose preview is still being fetched.
    @Published var pendingIDs: Set<Int64> = []
    @Published var pinboards: [Pinboard] = []
    @Published var memberships: [Int64: Set<Int64>] = [:]
    @Published var tab: ShelfTab = .clipboard
    @Published var editing: TabEdit?
    @Published var editText = ""
    @Published var pendingDelete: Int64?
    @Published var pickerOpen = false
    @Published var pickerIndex = 0

    func reset() {
        editing = nil; pendingDelete = nil; pickerOpen = false
        tab = .clipboard; query = ""; reload(); selection = 0
    }

    func reload() {
        pinboards = (try? store.pinboards()) ?? []
        memberships = (try? store.memberships()) ?? [:]
        if case .pinboard(let id) = tab, !pinboards.contains(where: { $0.id == id }) { tab = .clipboard }
        switch tab {
        case .clipboard: items = (try? store.items(matching: query)) ?? []
        case .pinboard(let id): items = (try? store.items(inPinboard: id, matching: query)) ?? []
        }
        selection = min(selection, max(items.count - 1, 0))
    }

    func move(_ d: Int) { selection = max(0, min(items.count - 1, selection + d)) }
    func pasteSelected(plain: Bool = false) { if items.indices.contains(selection) { onPaste?(items[selection], plain) } }

    /// Clipboard tab: delete the clip. Pinboard tab: just unpin it (the clip stays in history).
    func deleteSelected() {
        guard items.indices.contains(selection), let id = items[selection].id else { return }
        if case .pinboard(let board) = tab { try? store.remove(clipID: id, fromPinboard: board) }
        else {
            if let p = items[selection].linkImagePath { try? FileManager.default.removeItem(atPath: p) }
            try? store.delete(id: id)
        }
        reload()
    }

    // MARK: Tabs

    var allTabs: [ShelfTab] { [.clipboard] + pinboards.compactMap { $0.id.map(ShelfTab.pinboard) } }

    func select(_ t: ShelfTab) { guard t != tab else { return }; tab = t; selection = 0; reload() }

    func cycleTab(_ d: Int) {
        let tabs = allTabs
        guard let i = tabs.firstIndex(of: tab) else { return }
        select(tabs[(i + d + tabs.count) % tabs.count])
    }

    func beginCreate() { editText = ""; editing = .create }
    func beginRename(_ b: Pinboard) { guard let id = b.id else { return }; editText = b.name; editing = .rename(id) }
    func cancelEdit() { editing = nil }

    func commitEdit() {
        defer { editing = nil }
        let name = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let e = editing else { return }
        switch e {
        case .create:
            if let b = try? store.createPinboard(name: name), let id = b.id { tab = .pinboard(id); selection = 0 }
        case .rename(let id): try? store.renamePinboard(id: id, to: name)
        }
        reload()
    }

    func confirmDelete(_ id: Int64) {
        pendingDelete = nil
        try? store.deletePinboard(id: id)
        reload()
    }

    // MARK: Pinning

    func pin(_ item: ClipItem, to board: Pinboard) {
        guard let c = item.id, let b = board.id else { return }
        try? store.add(clipID: c, toPinboard: b); reload()
    }

    func unpin(_ item: ClipItem, from board: Pinboard) {
        guard let c = item.id, let b = board.id else { return }
        try? store.remove(clipID: c, fromPinboard: b); reload()
    }

    func openPicker() {
        guard items.indices.contains(selection) else { return }
        pickerIndex = 0; pickerOpen = true
    }

    func pickerCommit(_ index: Int) {
        defer { pickerOpen = false }
        guard pinboards.indices.contains(index), items.indices.contains(selection) else { return }
        pin(items[selection], to: pinboards[index])
    }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @FocusState private var searchFocused: Bool
    @FocusState private var nameFocused: Bool
    @FocusState private var pickerFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            tabStrip

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(searchPlaceholder, text: $model.query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { model.pasteSelected() }
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.white.opacity(0.08), in: Capsule())

            ZStack {
                cards
                if model.pickerOpen { picker }
            }
            if model.items.isEmpty { Text(emptyText).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .preferredColorScheme(.dark)
        .onAppear { searchFocused = true }
        .onChange(of: model.editing) { _, e in
            if e != nil { nameFocused = true } else { searchFocused = true }
        }
        .onChange(of: model.pickerOpen) { _, open in
            if open { pickerFocused = true } else { searchFocused = true }
        }
        .background(
            // Hidden buttons give reliable app-level shortcuts even while a text field has focus.
            Group {
                Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                Button("") { model.cycleTab(-1) }.keyboardShortcut("[", modifiers: .command)
                Button("") { model.cycleTab(1) }.keyboardShortcut("]", modifiers: .command)
                Button("") { model.openPicker() }.keyboardShortcut("p", modifiers: .command)
            }
            .opacity(0).accessibilityHidden(true)
        )
        .onKeyPress(.leftArrow) { model.move(-1); return .handled }
        .onKeyPress(.rightArrow) { model.move(1); return .handled }
        .onKeyPress(.tab) { // Tab / Shift+Tab; may be swallowed by focus traversal, Cmd+[ / ] always work
            model.cycleTab(NSEvent.modifierFlags.contains(.shift) ? -1 : 1); return .handled
        }
        .onKeyPress(.escape) {
            if model.pendingDelete != nil { model.pendingDelete = nil }
            else if model.query.isEmpty { model.onClose?() } else { model.query = "" }
            return .handled
        }
        .onKeyPress(keys: [.return]) { press in
            if press.modifiers.contains(.shift) { model.pasteSelected(plain: true); return .handled }
            return .ignored // plain Enter goes to the search field's onSubmit
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.deleteSelected(); return .handled
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard press.modifiers.contains(.command), let n = Int(press.characters), n >= 1,
                  model.items.indices.contains(n - 1) else { return .ignored }
            model.selection = n - 1; model.pasteSelected(); return .handled
        }
    }

    private var searchPlaceholder: String {
        if case .pinboard(let id) = model.tab, let b = model.pinboards.first(where: { $0.id == id }) {
            return "Search \(b.name)"
        }
        return "Search clipboard"
    }

    private var emptyText: String {
        if !model.query.isEmpty { return "No matches" }
        if case .pinboard = model.tab { return "Nothing pinned yet. Select a card and press Cmd+P" }
        return "Nothing copied yet"
    }

    // MARK: Tab strip

    private var tabStrip: some View {
        HStack(spacing: 6) {
            TabChip(title: "Clipboard", systemImage: "clipboard", selected: model.tab == .clipboard)
                .onTapGesture { model.select(.clipboard) }
            ForEach(model.pinboards) { board in
                if let id = board.id { pinboardTab(board, id: id) }
            }
            if model.editing == .create {
                nameField
            } else {
                Button { model.beginCreate() } label: {
                    Image(systemName: "plus").padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain).help("New pinboard")
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func pinboardTab(_ board: Pinboard, id: Int64) -> some View {
        if model.editing == .rename(id) {
            nameField
        } else if model.pendingDelete == id {
            HStack(spacing: 6) {
                Text("Delete \u{201C}\(board.name)\u{201D}?").font(.callout)
                Button("Delete", role: .destructive) { model.confirmDelete(id) }
                Button("Cancel") { model.pendingDelete = nil }
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(.red.opacity(0.18), in: Capsule())
        } else {
            TabChip(title: board.name, systemImage: "pin", selected: model.tab == .pinboard(id))
                .onTapGesture { model.select(.pinboard(id)) }
                .contextMenu {
                    Button("Rename\u{2026}") { model.beginRename(board) }
                    Button("Delete\u{2026}", role: .destructive) { model.pendingDelete = id }
                }
        }
    }

    private var nameField: some View {
        TextField("Pinboard name", text: $model.editText)
            .textFieldStyle(.plain).focused($nameFocused)
            .onSubmit { model.commitEdit() }
            .onKeyPress(.escape) { model.cancelEdit(); return .handled }
            .frame(width: 140)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.white.opacity(0.14), in: Capsule())
    }

    // MARK: Cards

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                        CardView(item: item, index: idx + 1, selected: idx == model.selection,
                                 loadingPreview: item.id.map(model.pendingIDs.contains) ?? false,
                                 pinned: !(model.memberships[item.id ?? -1] ?? []).isEmpty)
                            .id(idx)
                            .onTapGesture(count: 2) { model.selection = idx; model.pasteSelected() }
                            .onTapGesture { model.selection = idx }
                            .contextMenu { cardMenu(item, idx: idx) }
                    }
                }.padding(.horizontal, 16)
                .id(model.tab) // rebuild the lazy row when switching tabs so cards never show stale content
            }
            .onChange(of: model.selection) { _, new in withAnimation { proxy.scrollTo(new, anchor: .center) } }
        }
    }

    @ViewBuilder private func cardMenu(_ item: ClipItem, idx: Int) -> some View {
        let member = model.memberships[item.id ?? -1] ?? []
        if model.pinboards.isEmpty {
            Text("No pinboards yet - press + to create one")
        } else {
            Menu("Pin to\u{2026}") {
                ForEach(model.pinboards) { b in
                    Button(b.name) { model.pin(item, to: b) }.disabled(b.id.map(member.contains) ?? true)
                }
            }
        }
        ForEach(model.pinboards.filter { $0.id.map(member.contains) ?? false }) { b in
            Button("Remove from \(b.name)") { model.unpin(item, from: b) }
        }
    }

    // MARK: Cmd+P picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pin to\u{2026}").font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
            if model.pinboards.isEmpty {
                Text("No pinboards yet - press Esc, then +").font(.callout)
            }
            ForEach(Array(model.pinboards.enumerated()), id: \.element.id) { i, b in
                HStack {
                    Text(b.name)
                    Spacer()
                    if i < 9 { Text("\(i + 1)").foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(i == model.pickerIndex ? Color.accentColor.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { model.pickerCommit(i) }
            }
        }
        .padding(12).frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12)
        .focusable().focused($pickerFocused)
        .onKeyPress(.upArrow) { model.pickerIndex = max(0, model.pickerIndex - 1); return .handled }
        .onKeyPress(.downArrow) {
            model.pickerIndex = min(max(model.pinboards.count - 1, 0), model.pickerIndex + 1); return .handled
        }
        .onKeyPress(.return) { model.pickerCommit(model.pickerIndex); return .handled }
        .onKeyPress(.escape) { model.pickerOpen = false; return .handled }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), n >= 1, model.pinboards.indices.contains(n - 1) else { return .handled }
            model.pickerCommit(n - 1); return .handled
        }
    }
}

struct TabChip: View {
    let title: String
    let systemImage: String
    let selected: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon).font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.55) : .white.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
    }
}

struct CardView: View {
    static let width: CGFloat = 230
    let item: ClipItem
    let index: Int
    let selected: Bool
    var loadingPreview = false
    var pinned = false

    private var hasPreview: Bool { (item.linkTitle?.isEmpty == false) || item.linkImagePath != nil }
    private var headerColor: Color {
        switch item.kind { case .text: .blue; case .link: .orange; case .image: .purple }
    }
    private var title: String { item.kind == .text ? "Text" : item.kind == .link ? "Link" : "Image" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(item.createdAt, format: .relative(presentation: .named)).font(.caption)
                }
                Spacer()
                if pinned { Image(systemName: "pin.fill").font(.caption) }
                if let id = item.sourceBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                }
            }
            .padding(10).background(headerColor)

            Group {
                if item.kind == .image, let p = item.imagePath, let img = NSImage(contentsOfFile: p) {
                    Image(nsImage: img).resizable().scaledToFit().padding(8)
                } else if item.kind == .link, hasPreview {
                    LinkPreviewBody(item: item)
                } else if item.kind == .link, loadingPreview {
                    LinkLoadingBody(text: item.text ?? "")
                } else {
                    Text(item.text ?? "").font(.system(size: 13)).lineLimit(9).padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            HStack {
                if item.kind != .image { Text("\(item.characterCount) characters") }
                Spacer(); Text("\(index)")
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(width: Self.width, height: 240)
        .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
    }
}

private func hostName(of text: String?) -> String? {
    guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), let host = URL(string: t)?.host else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

/// Link card body once a preview exists: image fills the body, title and host sit on a gradient underneath.
/// Falls back gracefully when there is no image (title + host + URL) or no title (image + host).
private struct LinkPreviewBody: View {
    let item: ClipItem

    var body: some View {
        let host = hostName(of: item.text) ?? ""
        let image = item.linkImagePath.flatMap { NSImage(contentsOfFile: $0) }
        ZStack(alignment: .bottomLeading) {
            if let image {
                if item.linkImageIsIcon == true {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: 0.14))
                } else {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                }
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 80).frame(maxHeight: .infinity, alignment: .bottom)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title = item.linkTitle {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(image == nil ? 5 : 2)
                }
                Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if image == nil && item.linkTitle != nil {
                    Text(item.text ?? "").font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: image == nil ? .infinity : nil, alignment: .topLeading)
        }
        .frame(width: CardView.width) // a scaledToFill image would otherwise widen the card layout and shift the header/footer
        .frame(maxHeight: .infinity)
        .clipped()
    }
}

/// Subtle pending state while a link preview is being fetched.
private struct LinkLoadingBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 13)).lineLimit(4)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading preview…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
