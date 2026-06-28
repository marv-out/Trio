import Foundation
import GRDB

/// GRDB record replacing the Core Data `ContactImageEntryStored` entity.
///
/// All attributes are String/Int16/Bool/UUID — no Decimals — so a plain `Codable`
/// record works directly (unlike `TDDRecord`). `pk` is the synthetic rowid; `id` is the
/// original UUID. Mapping to/from the `ContactImageEntry` domain model stays in
/// `ContactImageStorage`, exactly as before.
struct ContactImageRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "contactImageEntryStored"

    var pk: Int64?
    var id: UUID?
    var name: String?
    var contactId: String?
    var layout: String?
    var ring: String?
    var primary: String?
    var top: String?
    var bottom: String?
    var hasHighContrast: Bool?
    var ringWidth: Int16?
    var ringGap: Int16?
    var colorMode: String?
    var fontSize: Int16?
    var fontSizeSecondary: Int16?
    var fontWeight: String?
    var fontWidth: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    enum Columns {
        static let contactId = Column("contactId")
        static let hasHighContrast = Column("hasHighContrast")
    }
}

// MARK: - Store

/// Typed data-access API for contact-image entries. Replaces the Core Data CRUD in
/// `ContactImageStorage`. No live UI observes this entity, so on-demand reads suffice.
enum ContactImageStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    /// All entries, high-contrast first (mirrors the former `hasHighContrast` descending sort).
    static func fetchAll() async throws -> [ContactImageRecord] {
        try await pool.read { db in
            try ContactImageRecord
                .order(ContactImageRecord.Columns.hasHighContrast.desc)
                .fetchAll(db)
        }
    }

    static func insert(_ record: ContactImageRecord) async throws {
        var record = record
        try await pool.write { db in
            try record.insert(db)
        }
    }

    /// Updates the entry matching `contactId` in place; no-op if none exists.
    static func updateByContactId(_ record: ContactImageRecord) async throws {
        try await pool.write { db in
            guard let contactId = record.contactId,
                  let existing = try ContactImageRecord
                  .filter(ContactImageRecord.Columns.contactId == contactId)
                  .fetchOne(db)
            else { return }
            var updated = record
            updated.pk = existing.pk // keep the rowid stable
            updated.id = existing.id // preserve the original UUID (update never changed it)
            try updated.update(db)
        }
    }

    static func delete(pk: Int64) async throws {
        _ = try await pool.write { db in
            try ContactImageRecord.deleteOne(db, key: pk)
        }
    }
}
