import CoreData
import Foundation
import GRDB
import Swinject
import Testing

@testable import LoopKit
@testable import Trio

@Suite("PumpHistoryStorage Tests", .serialized) struct PumpHistoryStorageTests: Injectable {
    @Injected() var storage: PumpHistoryStorage!
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!
    /// In-memory GRDB pool backing every pump-event assertion (pump events now live in GRDB).
    let pool: DatabasePool
    typealias PumpEvent = PumpEventStored.EventType

    init() async throws {
        // Core Data is still needed by the other assemblies; pump events themselves live in GRDB.
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()
        pool = try GRDBStack.makeInMemoryForTests().pool

        // Create assembler with test assembly (provides the injected SettingsManager the storage needs).
        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext) // Add our test assembly last to override PumpHistoryStorage
        ])

        resolver = assembler.resolver
        injectServices(resolver)
    }

    /// The concrete storage, so tests can pass the in-memory pool to the `in:` seam.
    private var baseStorage: BasePumpHistoryStorage {
        storage as! BasePumpHistoryStorage
    }

    /// All stored pump events (with their children), newest first, from the in-memory pool.
    private func allDetails() async throws -> [PumpEventDetails] {
        try await pool.read { db in
            let events = try PumpEventRecord.order(PumpEventRecord.Columns.timestamp.desc).fetchAll(db)
            var result: [PumpEventDetails] = []
            for event in events {
                let bolus = try BolusRecord.filter(BolusRecord.Columns.pumpEventPk == event.pk).fetchOne(db)
                let tempBasal = try TempBasalRecord.filter(TempBasalRecord.Columns.pumpEventPk == event.pk).fetchOne(db)
                result.append(PumpEventDetails(event: event, bolus: bolus, tempBasal: tempBasal))
            }
            return result
        }
    }

    private func bolusEvent(date: Date, value: Double, automatic: Bool, manuallyEntered: Bool) -> LoopKit.NewPumpEvent {
        LoopKit.NewPumpEvent(
            date: date,
            dose: LoopKit.DoseEntry(
                type: .bolus,
                startDate: date,
                value: value,
                unit: .units,
                deliveredUnits: nil,
                description: nil,
                syncIdentifier: nil,
                scheduledBasalRate: nil,
                insulinType: .lyumjev,
                automatic: automatic,
                manuallyEntered: manuallyEntered,
                isMutable: false
            ),
            raw: Data(),
            title: "Test Bolus",
            type: .bolus
        )
    }

    @Test("Storage is correctly initialized") func testStorageInitialization() {
        #expect(storage != nil, "PumpHistoryStorage should be injected")
        #expect(storage is BasePumpHistoryStorage, "Storage should be of type BasePumpHistoryStorage")
        #expect(storage.updatePublisher != nil, "Update publisher should be available")
    }

    @Test("Test store function in PumpHistoryStorage") func testStorePumpEvents() async throws {
        // Given
        let date = Date()
        let tenMinAgo = date.addingTimeInterval(-10.minutes.timeInterval)
        let halfHourInFuture = date.addingTimeInterval(30.minutes.timeInterval)

        // Create 2 test events, 1 SMB bolus + 1 temp basal event
        let events: [LoopKit.NewPumpEvent] = [
            bolusEvent(date: tenMinAgo, value: 0.4, automatic: true, manuallyEntered: false),
            LoopKit.NewPumpEvent(
                date: date,
                dose: LoopKit.DoseEntry(
                    type: .tempBasal,
                    startDate: date,
                    endDate: halfHourInFuture,
                    value: 1.2,
                    unit: .unitsPerHour,
                    deliveredUnits: nil,
                    description: nil,
                    syncIdentifier: nil,
                    scheduledBasalRate: nil,
                    insulinType: .lyumjev,
                    automatic: true,
                    manuallyEntered: false,
                    isMutable: true
                ),
                raw: Data(),
                title: "Test Temp Basal",
                type: .tempBasal
            )
        ]

        // When
        try await baseStorage.storePumpEvents(events, in: pool)

        // Then
        let finalEntries = try await allDetails()
        #expect(finalEntries.count == 2, "Should have added 2 new events")

        let bolus = finalEntries.first { $0.type == PumpEvent.bolus.rawValue }
        #expect(bolus != nil, "Should have found bolus event")
        #expect(bolus?.bolus?.amount == 0.4, "Bolus amount should be 0.4")
        #expect(bolus?.bolus?.isSMB == true, "Should be a SMB")
        #expect(bolus?.bolus?.isExternal == false, "Should not be external insulin")
        #expect(bolus?.event.isUploadedToNS == false, "Should not be uploaded to NS")
        #expect(bolus?.event.isUploadedToHealth == false, "Should not be uploaded to Health")
        #expect(bolus?.event.isUploadedToTidepool == false, "Should not be uploaded to Tidepool")

        let tempBasal = finalEntries.first { $0.type == PumpEvent.tempBasal.rawValue }
        #expect(tempBasal != nil, "Should have found temp basal event")
        #expect(tempBasal?.tempBasal?.rate == 1.2, "Temp basal rate should be 1.2")
        #expect(tempBasal?.tempBasal?.duration == 30, "Temp basal duration should be 30 minutes")
    }

    @Test("Test store function for manual boluses") func testStorePumpEventsWithManualBoluses() async throws {
        // Given
        let date = Date().addingTimeInterval(-5.minutes.timeInterval)
        let events = [bolusEvent(date: date, value: 4, automatic: false, manuallyEntered: false)]

        // When
        try await baseStorage.storePumpEvents(events, in: pool)

        // Then
        let details = try await allDetails()
        #expect(details.count == 1, "Should have found exactly one event")
        let event = details.first
        #expect(event?.type == PumpEvent.bolus.rawValue, "Should be a bolus event")
        #expect(event?.bolus?.amount == 4, "Bolus amount should be 4 U")
        #expect(event?.bolus?.isSMB == false, "Should not be a SMB")
        #expect(event?.bolus?.isExternal == false, "Should not be external Insulin")
    }

    @Test("Test partial-bolus smaller-value update") func testPartialBolusUpdate() async throws {
        // Given a stored bolus of 0.5 U
        let date = Date().addingTimeInterval(-5.minutes.timeInterval)
        try await baseStorage.storePumpEvents(
            [bolusEvent(date: date, value: 0.5, automatic: true, manuallyEntered: false)],
            in: pool
        )

        // Mark it uploaded so we can verify the update re-clears the flags.
        let stored = try await allDetails()
        try await PumpEventStore.markUploaded(channel: .nightscout, ids: [stored.first?.event.id].compactMap { $0 }, pool: pool)

        // When a same-(timestamp,type) bolus with a smaller value arrives (a cancelled/partial bolus)
        try await baseStorage.storePumpEvents(
            [bolusEvent(date: date, value: 0.3, automatic: true, manuallyEntered: false)],
            in: pool
        )

        // Then the amount is overwritten with the smaller value and the upload flags are re-cleared;
        // no duplicate row is created.
        let details = try await allDetails()
        #expect(details.count == 1, "Duplicate (timestamp, type) must not create a second row")
        #expect(details.first?.bolus?.amount == 0.3, "Amount should be updated to the smaller value")
        #expect(details.first?.event.isUploadedToNS == false, "The partial-bolus update must re-clear the NS upload flag")
    }

    @Test("Test not-yet-uploaded fetch + mark uploaded") func testNotYetUploaded() async throws {
        let date = Date().addingTimeInterval(-5.minutes.timeInterval)
        try await baseStorage.storePumpEvents(
            [bolusEvent(date: date, value: 1.0, automatic: false, manuallyEntered: false)],
            in: pool
        )

        let notUploaded = try await PumpEventStore.fetchNotYetUploaded(channel: .nightscout, pool: pool)
        #expect(notUploaded.count == 1, "The new bolus should be pending Nightscout upload")

        let ids = notUploaded.compactMap(\.event.id)
        try await PumpEventStore.markUploaded(channel: .nightscout, ids: ids, pool: pool)

        let afterMark = try await PumpEventStore.fetchNotYetUploaded(channel: .nightscout, pool: pool)
        #expect(afterMark.isEmpty, "After marking uploaded, nothing should be pending")
    }

    @Test("Test duplicates in PumpHistoryStorage") func testDuplicatePumpEvents() async throws {
        // Given
        let date = Date()
        let twoHoursAgo = date - 2.hours.timeInterval
        let oneMinuteAgo = date - 1.minutes.timeInterval

        // Create two suspend events and two resume events (each pair shares a (timestamp, type)).
        let events: [LoopKit.NewPumpEvent] = [
            LoopKit.NewPumpEvent(date: twoHoursAgo, dose: nil, raw: Data(), title: "Test Suspend", type: .suspend),
            LoopKit.NewPumpEvent(date: twoHoursAgo, dose: nil, raw: Data(), title: "Test Suspend", type: .suspend),
            LoopKit.NewPumpEvent(date: oneMinuteAgo, dose: nil, raw: Data(), title: "Test Resume", type: .resume),
            LoopKit.NewPumpEvent(date: oneMinuteAgo, dose: nil, raw: Data(), title: "Test Resume", type: .resume)
        ]

        // When
        try await baseStorage.storePumpEvents(events, in: pool)

        // Then — the (timestamp, type) de-dup collapses each pair; only 2 rows remain.
        let finalEntries = try await allDetails().sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
        #expect(finalEntries.count == 2, "Should have added 2 new events (duplicates de-duped)")
        #expect(finalEntries.first?.type == PumpEvent.pumpSuspend.rawValue)
        #expect(finalEntries.last?.type == PumpEvent.pumpResume.rawValue)
    }
}
