import Testing
import Foundation
@testable import PPasteCore

@Suite struct ClipStoreTests {
    func text(_ s: String, at date: Date = Date()) -> ClipItem {
        ClipItem(kind: ClipItem.kind(forText: s), text: s, contentHash: ClipStore.hash(Data(s.utf8)), createdAt: date)
    }

    @Test func dedupeBumpsToTop() throws {
        let store = try ClipStore(path: nil)
        try store.save(text("a", at: Date(timeIntervalSince1970: 1)))
        try store.save(text("b", at: Date(timeIntervalSince1970: 2)))
        try store.save(text("a", at: Date(timeIntervalSince1970: 3)))
        let items = try store.items()
        #expect(items.map(\.text) == ["a", "b"])
    }

    @Test func searchFiltersAndEscapesWildcards() throws {
        let store = try ClipStore(path: nil)
        try store.save(text("hello world"))
        try store.save(text("100% done"))
        #expect(try store.items(matching: "world").count == 1)
        #expect(try store.items(matching: "%").count == 1)
        #expect(try store.items(matching: "").count == 2)
    }

    @Test func linkDetection() {
        #expect(ClipItem.kind(forText: "https://pulumi.com/docs") == .link)
        #expect(ClipItem.kind(forText: "see https://pulumi.com") == .text)
        #expect(ClipItem.kind(forText: "claude --resume abc") == .text)
    }

    @Test func pruningOnlyRemovesOldImages() throws {
        let store = try ClipStore(path: nil)
        let old = Date().addingTimeInterval(-40 * 86400)
        try store.save(ClipItem(kind: .image, imagePath: "old.png", contentHash: "i1", createdAt: old))
        try store.save(ClipItem(kind: .image, imagePath: "new.png", contentHash: "i2"))
        try store.save(text("ancient text", at: old))
        let removed = try store.pruneImages(olderThan: Date().addingTimeInterval(-30 * 86400))
        #expect(removed == ["old.png"])
        #expect(try store.items().count == 2)
    }
}
