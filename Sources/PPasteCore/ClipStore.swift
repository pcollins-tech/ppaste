import Foundation
import GRDB
import CryptoKit

public final class ClipStore: Sendable {
    private let db: DatabaseQueue

    /// Pass `nil` for an in-memory database (tests).
    public init(path: String?) throws {
        db = path == nil ? try DatabaseQueue() : try DatabaseQueue(path: path!)
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "clip") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("text", .text)
                t.column("imagePath", .text)
                t.column("sourceBundleID", .text)
                t.column("sourceName", .text)
                t.column("contentHash", .text).notNull().unique()
                t.column("createdAt", .datetime).notNull().indexed()
            }
        }
        m.registerMigration("v2_pinboards") { db in
            try db.create(table: "pinboard") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "pinboard_clip") { t in
                t.column("pinboardID", .integer).notNull().references("pinboard", onDelete: .cascade)
                t.column("clipID", .integer).notNull().indexed().references("clip", onDelete: .cascade)
                t.column("addedAt", .datetime).notNull()
                t.primaryKey(["pinboardID", "clipID"])
            }
        }
        m.registerMigration("v3_link_previews") { db in
            try db.alter(table: "clip") { t in
                t.add(column: "linkTitle", .text)
                t.add(column: "linkImagePath", .text)
                t.add(column: "linkImageIsIcon", .boolean)
                t.add(column: "linkFetchedAt", .datetime)
            }
        }
        try m.migrate(db)
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Insert a clip, or bump an identical existing one to the top (dedupe).
    @discardableResult
    public func save(_ item: ClipItem) throws -> ClipItem {
        try db.write { db in
            if var existing = try ClipItem.filter(Column("contentHash") == item.contentHash).fetchOne(db) {
                existing.createdAt = item.createdAt
                existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
                existing.sourceName = item.sourceName ?? existing.sourceName
                try existing.update(db)
                return existing
            }
            var new = item
            try new.insert(db)
            return new
        }
    }

    /// Newest first. Empty/nil query returns everything (up to `limit`).
    public func items(matching query: String? = nil, limit: Int = 200) throws -> [ClipItem] {
        try db.read { db in
            var req = ClipItem.order(Column("createdAt").desc).limit(limit)
            let q = query?.trimmingCharacters(in: .whitespaces) ?? ""
            if !q.isEmpty {
                let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                req = req.filter(sql: "text LIKE ? ESCAPE '\\' OR sourceName LIKE ? ESCAPE '\\'",
                                 arguments: ["%\(escaped)%", "%\(escaped)%"])
            }
            return try req.fetchAll(db)
        }
    }

    // MARK: Pinboards

    /// Create a pinboard at the end of the tab order. Names are trimmed; empty names are rejected.
    @discardableResult
    public func createPinboard(name: String) throws -> Pinboard {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw PinboardError.emptyName }
        return try db.write { db in
            let next = (try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM pinboard") ?? -1) + 1
            var b = Pinboard(name: n, sortOrder: next)
            try b.insert(db)
            return b
        }
    }

    public func renamePinboard(id: Int64, to name: String) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw PinboardError.emptyName }
        try db.write { db in
            try db.execute(sql: "UPDATE pinboard SET name = ? WHERE id = ?", arguments: [n, id])
        }
    }

    /// Deletes the pinboard and its memberships; the clips themselves stay in history.
    public func deletePinboard(id: Int64) throws { _ = try db.write { try Pinboard.deleteOne($0, key: id) } }

    public func pinboards() throws -> [Pinboard] {
        try db.read { try Pinboard.order(Column("sortOrder"), Column("id")).fetchAll($0) }
    }

    /// Idempotent: pinning an already-pinned clip keeps its original `addedAt`.
    public func add(clipID: Int64, toPinboard pinboardID: Int64, at date: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO pinboard_clip (pinboardID, clipID, addedAt) VALUES (?, ?, ?)",
                           arguments: [pinboardID, clipID, date])
        }
    }

    public func remove(clipID: Int64, fromPinboard pinboardID: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM pinboard_clip WHERE pinboardID = ? AND clipID = ?",
                           arguments: [pinboardID, clipID])
        }
    }

    /// IDs of the pinboards a clip belongs to.
    public func pinboardIDs(forClip clipID: Int64) throws -> Set<Int64> {
        try db.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT pinboardID FROM pinboard_clip WHERE clipID = ?", arguments: [clipID]))
        }
    }

    /// Every membership as clipID -> pinboard IDs (one query, for UI badges and menus).
    public func memberships() throws -> [Int64: Set<Int64>] {
        try db.read { db in
            var out: [Int64: Set<Int64>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT clipID, pinboardID FROM pinboard_clip") {
                out[row["clipID"], default: []].insert(row["pinboardID"])
            }
            return out
        }
    }

    /// Clips in a pinboard, most recently added first. Same search semantics as `items(matching:)`.
    public func items(inPinboard pinboardID: Int64, matching query: String? = nil, limit: Int = 200) throws -> [ClipItem] {
        try db.read { db in
            var sql = "SELECT clip.* FROM clip JOIN pinboard_clip pc ON pc.clipID = clip.id WHERE pc.pinboardID = ?"
            var args: [any DatabaseValueConvertible] = [pinboardID]
            let q = query?.trimmingCharacters(in: .whitespaces) ?? ""
            if !q.isEmpty {
                let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                sql += " AND (clip.text LIKE ? ESCAPE '\\' OR clip.sourceName LIKE ? ESCAPE '\\')"
                args += ["%\(escaped)%", "%\(escaped)%"]
            }
            sql += " ORDER BY pc.addedAt DESC, clip.id DESC LIMIT ?"
            args.append(limit)
            return try ClipItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    public func delete(id: Int64) throws { _ = try db.write { try ClipItem.deleteOne($0, key: id) } }
    public func deleteAll() throws { _ = try db.write { try ClipItem.deleteAll($0) } }

    /// Text and links are kept forever; images are pruned. Returns image paths to remove from disk.
    @discardableResult
    public func pruneImages(olderThan cutoff: Date) throws -> [String] {
        try db.write { db in
            // Pinned images are exempt: neither the row nor the file is removed.
            let req = ClipItem.filter(Column("kind") == ClipKind.image.rawValue && Column("createdAt") < cutoff)
                .filter(sql: "id NOT IN (SELECT clipID FROM pinboard_clip)")
            let old = try req.fetchAll(db)
            _ = try req.deleteAll(db)
            return old.compactMap(\.imagePath)
        }
    }

    /// Record the outcome of a link preview fetch. Title/image may be nil for a failed fetch;
    /// `fetchedAt` still marks the attempt so a clip is never fetched twice.
    /// Returns false if the clip no longer exists.
    @discardableResult
    public func saveLinkPreview(id: Int64, title: String?, imagePath: String?, imageIsIcon: Bool = false,
                                fetchedAt: Date = Date()) throws -> Bool {
        try db.write { db in
            try ClipItem.filter(key: id).updateAll(db,
                Column("linkTitle").set(to: title),
                Column("linkImagePath").set(to: imagePath),
                Column("linkImageIsIcon").set(to: imagePath == nil ? nil : imageIsIcon),
                Column("linkFetchedAt").set(to: fetchedAt)) > 0
        }
    }

    public func item(id: Int64) throws -> ClipItem? { try db.read { try ClipItem.fetchOne($0, key: id) } }

    /// Drop preview images fetched before `cutoff`; the clip and its title are kept.
    /// Returns the image paths to remove from disk.
    @discardableResult
    public func pruneLinkPreviewImages(olderThan cutoff: Date) throws -> [String] {
        try db.write { db in
            let req = ClipItem.filter(Column("linkImagePath") != nil && Column("linkFetchedAt") < cutoff)
            let old = try req.fetchAll(db)
            try req.updateAll(db, Column("linkImagePath").set(to: nil), Column("linkImageIsIcon").set(to: nil))
            return old.compactMap(\.linkImagePath)
        }
    }
}
