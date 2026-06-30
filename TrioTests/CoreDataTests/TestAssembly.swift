import CoreData
import Foundation
import Swinject
@testable import Trio

class TestAssembly: Assembly {
    private let testContext: NSManagedObjectContext

    init(testContext: NSManagedObjectContext) {
        self.testContext = testContext
    }

    func assemble(container: Container) {
        // Override PumpHistoryStorage registration for tests
        container.register(PumpHistoryStorage.self) { r in
            BasePumpHistoryStorage(resolver: r, contextProvider: { self.testContext })
        }.inObjectScope(.container)

        // Override DeterminationStorage registration for tests
        container.register(DeterminationStorage.self) { r in
            BaseDeterminationStorage(resolver: r, contextProvider: { self.testContext })
        }.inObjectScope(.container)

        // Override CarbsStorage registration for tests
        container.register(CarbsStorage.self) { r in
            BaseCarbsStorage(resolver: r, contextProvider: { self.testContext })
        }.inObjectScope(.container)

        // Override GlucoseStorage registration for tests
        container.register(GlucoseStorage.self) { r in
            BaseGlucoseStorage(resolver: r, contextProvider: { self.testContext })
        }.inObjectScope(.container)

        // Override TempTargetStorage registration for tests. Temp targets now live in GRDB, so this
        // no longer needs a Core Data context; the GRDB round-trip is tested directly in
        // TempTargetStorageTests against an in-memory pool.
        container.register(TempTargetsStorage.self) { r in
            BaseTempTargetsStorage(resolver: r)
        }.inObjectScope(.container)

        // Override OverrideStorage registration for tests. Overrides now live in GRDB, so this no
        // longer needs a Core Data context; the GRDB round-trip is tested directly in
        // OverrideStorageTests against an in-memory pool.
        container.register(OverrideStorage.self) { r in
            BaseOverrideStorage(resolver: r)
        }.inObjectScope(.container)
    }
}
