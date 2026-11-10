import Testing
import Foundation
@testable import PPasteCore

@Suite struct PinboardTests {
    func text(_ s: String) -> ClipItem {
        ClipItem(kind: .text, text: s, contentHash: ClipStore.hash(Data(s.utf8)))
    }

    @Test func createRenameDeleteList() throws {
        let store = try ClipStore(path: nil)
        let a = try store.createPinboard(name: "  Links ")
        let b = try store.createPinboard(name: "Snippets")
        #expect(a.name == "Links")
        #expect(try store.pinboards().map(\.name) == ["Links", "Snippets"])
        try store.renamePinboard(id: a.id!, to: "Useful")
        #expect(try store.pinboards().map(\.name) == ["Useful", "Snippets"])
        try store.deletePinboard(id: a.id!)
        #expect(try store.pinboards().map(\.id) == [b.id])
    }

    @Test func emptyNamesRejected() throws {
        let store = try ClipStore(path: nil)
        #expect(throws: PinboardError.emptyName) { try store.createPinboard(name: "  ") }
        let b = try store.createPinboard(name: "x")
        #expect(throws: PinboardError.emptyName) { try store.renamePinboard(id: b.id!, to: "") }
    }

    @Test func addRemoveAndNewestAddedFirst() throws {
        let store = try ClipStore(path: nil)
        let board = try store.createPinboard(name: "b").id!
        let a = try store.save(text("a")).id!
        let b = try store.save(text("b")).id!
        try store.add(clipID: a, toPinboard: board, at: Date(timeIntervalSince1970: 10))
        try store.add(clipID: b, toPinboard: board, at: Date(timeIntervalSince1970: 20))
        #expect(try store.items(inPinboard: board).map(\.text) == ["b", "a"])
        #expect(try store.pinboardIDs(forClip: a) == [board])
        try store.remove(clipID: b, fromPinboard: board)
        #expect(try store.items(inPinboard: board).map(\.text) == ["a"])
        #expect(try store.items().count == 2) // removing membership keeps the clip
    }

    @Test func addIsIdempotent() throws {
        let store = try ClipStore(path: nil)
        let board = try store.createPinboard(name: "b").id!
        let a = try store.save(text("a")).id!
        try store.add(clipID: a, toPinboard: board)
        try store.add(clipID: a, toPinboard: board)
        #expect(try store.items(inPinboard: board).count == 1)
    }

    @Test func searchWithinPinboard() throws {
        let store = try ClipStore(path: nil)
        let board = try store.createPinboard(name: "b").id!
        for s in ["hello world", "100% done", "other"] {
            try store.add(clipID: try store.save(text(s)).id!, toPinboard: board)
        }
        try store.save(text("hello outside"))
        #expect(try store.items(inPinboard: board, matching: "hello").map(\.text) == ["hello world"])
        #expect(try store.items(inPinboard: board, matching: "%").count == 1)
        #expect(try store.items(inPinboard: board, matching: " ").count == 3)
    }

    @Test func deletingClipCleansMembership() throws {
        let store = try ClipStore(path: nil)
        let board = try store.createPinboard(name: "b").id!
        let a = try store.save(text("a")).id!
        try store.add(clipID: a, toPinboard: board)
        try store.delete(id: a)
        #expect(try store.items(inPinboard: board).isEmpty)
        #expect(try store.pinboardIDs(forClip: a).isEmpty)
    }

    @Test func membershipsMap() throws {
        let store = try ClipStore(path: nil)
        let b1 = try store.createPinboard(name: "1").id!
        let b2 = try store.createPinboard(name: "2").id!
        let a = try store.save(text("a")).id!
        try store.add(clipID: a, toPinboard: b1)
        try store.add(clipID: a, toPinboard: b2)
        #expect(try store.memberships() == [a: [b1, b2]])
    }

    @Test func deletingPinboardKeepsClips() throws {
        let store = try ClipStore(path: nil)
        let board = try store.createPinboard(name: "b").id!
        try store.add(clipID: try store.save(text("a")).id!, toPinboard: board)
        try store.deletePinboard(id: board)
        #expect(try store.items().count == 1)
    }

    @Test func pinnedImagesAreNotPruned() throws {
        let store = try ClipStore(path: nil)
        let old = Date().addingTimeInterval(-40 * 86400)
        let pinned = try store.save(ClipItem(kind: .image, imagePath: "pinned.png", contentHash: "p", createdAt: old))
        try store.save(ClipItem(kind: .image, imagePath: "loose.png", contentHash: "l", createdAt: old))
        let board = try store.createPinboard(name: "b").id!
        try store.add(clipID: pinned.id!, toPinboard: board)
        let removed = try store.pruneImages(olderThan: Date().addingTimeInterval(-30 * 86400))
        #expect(removed == ["loose.png"])
        #expect(try store.items(inPinboard: board).map(\.imagePath) == ["pinned.png"])
        // once unpinned it becomes prunable again
        try store.remove(clipID: pinned.id!, fromPinboard: board)
        #expect(try store.pruneImages(olderThan: Date().addingTimeInterval(-30 * 86400)) == ["pinned.png"])
    }
}
