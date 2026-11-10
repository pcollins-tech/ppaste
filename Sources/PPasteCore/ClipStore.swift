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

    public func delete(id: Int64) throws { _ = try db.write { try ClipItem.deleteOne($0, key: id) } }
    public func deleteAll() throws { _ = try db.write { try ClipItem.deleteAll($0) } }

    /// Text and links are kept forever; images are pruned. Returns image paths to remove from disk.
    @discardableResult
    public func pruneImages(olderThan cutoff: Date) throws -> [String] {
        try db.write { db in
            let old = try ClipItem.filter(Column("kind") == ClipKind.image.rawValue && Column("createdAt") < cutoff).fetchAll(db)
            _ = try ClipItem.filter(Column("kind") == ClipKind.image.rawValue && Column("createdAt") < cutoff).deleteAll(db)
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
