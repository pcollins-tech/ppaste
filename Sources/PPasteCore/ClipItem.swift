import Foundation
import GRDB

public enum ClipKind: String, Codable, Sendable {
    case text, link, image
}

public struct ClipItem: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "clip"

    public var id: Int64?
    public var kind: ClipKind
    public var text: String?
    public var imagePath: String?
    public var sourceBundleID: String?
    public var sourceName: String?
    public var contentHash: String
    public var createdAt: Date

    public init(id: Int64? = nil, kind: ClipKind, text: String? = nil, imagePath: String? = nil,
                sourceBundleID: String? = nil, sourceName: String? = nil,
                contentHash: String, createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.text = text; self.imagePath = imagePath
        self.sourceBundleID = sourceBundleID; self.sourceName = sourceName
        self.contentHash = contentHash; self.createdAt = createdAt
    }

    public var characterCount: Int { text?.count ?? 0 }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Classify copied text as a link when it is a single http(s) URL.
    public static func kind(forText text: String) -> ClipKind {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: \.isWhitespace), let url = URL(string: t),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil
        else { return .text }
        return .link
    }
}
