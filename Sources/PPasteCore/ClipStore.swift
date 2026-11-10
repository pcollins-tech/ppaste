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
}
