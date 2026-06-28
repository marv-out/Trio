import Combine
import Foundation
import GRDB

/// GRDB record replacing the Core Data `MealPresetStored` entity (saved meal templates).
///
/// `Hashable` so it can back a SwiftUI `Picker` selection / `ForEach(id: \.self)` — the role
/// the `NSManagedObject` played before. Decimals stored as TEXT (lossless), like `TDDRecord`.
struct MealPresetRecord: FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "mealPresetStored"

    var pk: Int64?
    var dish: String?
    var carbs: Decimal?
    var fat: Decimal?
    var protein: Decimal?

    init(pk: Int64? = nil, dish: String? = nil, carbs: Decimal? = nil, fat: Decimal? = nil, protein: Decimal? = nil) {
        self.pk = pk
        self.dish = dish
        self.carbs = carbs
        self.fat = fat
        self.protein = protein
    }

    init(row: Row) {
        pk = row["pk"]
        dish = row["dish"]
        carbs = Self.decimal(row["carbs"])
        fat = Self.decimal(row["fat"])
        protein = Self.decimal(row["protein"])
    }

    func encode(to container: inout PersistenceContainer) {
        container["pk"] = pk
        container["dish"] = dish
        container["carbs"] = Self.string(carbs)
        container["fat"] = Self.string(fat)
        container["protein"] = Self.string(protein)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }

    private static func string(_ value: Decimal?) -> String? {
        value.map { NSDecimalNumber(decimal: $0).stringValue }
    }

    private static func decimal(_ string: String?) -> Decimal? {
        string.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
    }

    enum Columns {
        static let dish = Column("dish")
    }
}

// MARK: - Store

/// Typed data-access API for meal presets. Replaces the Core Data create/fetch/delete in
/// `MealPresetView`, `TreatmentsStateModel`, and `SettingsExportStateModel`.
enum MealPresetStore {
    private static var pool: DatabasePool { GRDBStack.shared.pool }

    /// All presets, alphabetical by dish (mirrors the former `@FetchRequest` sort).
    static func fetchAll() async throws -> [MealPresetRecord] {
        try await pool.read { db in
            try MealPresetRecord.order(MealPresetRecord.Columns.dish).fetchAll(db)
        }
    }

    static func insert(_ record: MealPresetRecord) async throws {
        var record = record
        try await pool.write { db in try record.insert(db) }
    }

    static func delete(pk: Int64) async throws {
        _ = try await pool.write { db in
            try MealPresetRecord.deleteOne(db, key: pk)
        }
    }

    /// Reactive feed of all presets — replaces the SwiftUI `@FetchRequest`. Drives the
    /// `Treatments.StateModel.carbPresets` array.
    static func observeAll() -> AnyPublisher<[MealPresetRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try MealPresetRecord.order(MealPresetRecord.Columns.dish).fetchAll(db)
        }
        return observation.publisher(in: pool).eraseToAnyPublisher()
    }
}
