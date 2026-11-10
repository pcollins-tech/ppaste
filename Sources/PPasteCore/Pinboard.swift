import Foundation
import GRDB

public struct Pinboard: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "pinboard"

    public var id: Int64?
    public var name: String
    public var sortOrder: Int
    public var createdAt: Date

    public init(id: Int64? = nil, name: String, sortOrder: Int = 0, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.sortOrder = sortOrder; self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum PinboardError: Error, Equatable { case emptyName }
