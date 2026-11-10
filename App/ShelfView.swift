import SwiftUI
import PPasteCore

final class ShelfModel: ObservableObject {
    var store: ClipStore!
    var onPaste: ((ClipItem, Bool) -> Void)?
    var onClose: (() -> Void)?
    @Published var items: [ClipItem] = []
    @Published var query = "" { didSet { reload() } }
    @Published var selection = 0

    func reset() { query = ""; reload(); selection = 0 }
    func reload() { items = (try? store.items(matching: query)) ?? []; selection = min(selection, max(items.count - 1, 0)) }
    func move(_ d: Int) { selection = max(0, min(items.count - 1, selection + d)) }
    func pasteSelected(plain: Bool = false) { if items.indices.contains(selection) { onPaste?(items[selection], plain) } }
    func deleteSelected() {
        guard items.indices.contains(selection), let id = items[selection].id else { return }
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
                            CardView(item: item, index: idx + 1, selected: idx == model.selection)
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
