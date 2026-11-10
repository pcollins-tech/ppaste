import SwiftUI
import PPasteCore

final class ShelfModel: ObservableObject {
    var store: ClipStore!
    var onPaste: ((ClipItem, Bool) -> Void)?
    var onClose: (() -> Void)?
    @Published var items: [ClipItem] = []
    @Published var query = "" { didSet { reload() } }
    @Published var selection = 0
    /// Link clips whose preview is still being fetched.
    @Published var pendingIDs: Set<Int64> = []

    func reset() { query = ""; reload(); selection = 0 }
    func reload() { items = (try? store.items(matching: query)) ?? []; selection = min(selection, max(items.count - 1, 0)) }
    func move(_ d: Int) { selection = max(0, min(items.count - 1, selection + d)) }
    func pasteSelected(plain: Bool = false) { if items.indices.contains(selection) { onPaste?(items[selection], plain) } }
    func deleteSelected() {
        guard items.indices.contains(selection), let id = items[selection].id else { return }
        if let p = items[selection].linkImagePath { try? FileManager.default.removeItem(atPath: p) }
        try? store.delete(id: id); reload()
    }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard", text: $model.query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { model.pasteSelected() }
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.white.opacity(0.08), in: Capsule())

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                            CardView(item: item, index: idx + 1, selected: idx == model.selection,
                                     loadingPreview: item.id.map(model.pendingIDs.contains) ?? false)
                                .id(idx)
                                .onTapGesture(count: 2) { model.selection = idx; model.pasteSelected() }
                                .onTapGesture { model.selection = idx }
                        }
                    }.padding(.horizontal, 16)
                }
                .onChange(of: model.selection) { _, new in withAnimation { proxy.scrollTo(new, anchor: .center) } }
            }
            if model.items.isEmpty { Text(model.query.isEmpty ? "Nothing copied yet" : "No matches").foregroundStyle(.secondary) }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .preferredColorScheme(.dark)
        .onAppear { searchFocused = true }
        .background(
            // Cmd+F focuses the search field, even after clicking a card
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0).accessibilityHidden(true)
        )
        .onKeyPress(.leftArrow) { model.move(-1); return .handled }
        .onKeyPress(.rightArrow) { model.move(1); return .handled }
        .onKeyPress(.escape) {
            if model.query.isEmpty { model.onClose?() } else { model.query = "" }
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
}

struct CardView: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    var loadingPreview = false

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
        .frame(width: 230, height: 240)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
