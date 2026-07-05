import Combine
import Foundation
import GRDB
import LoopKit
import SwiftDate
import Swinject

protocol PumpHistoryObserver {
    func pumpHistoryDidUpdate(_ events: [PumpHistoryEvent])
}

protocol PumpHistoryStorage {
    var updatePublisher: AnyPublisher<Void, Never> { get }
    func getPumpHistory() async throws -> [PumpHistoryEvent]
    func storePumpEvents(_ events: [NewPumpEvent]) async throws
    func storeExternalInsulinEvent(amount: Decimal, timestamp: Date) async
    func getPumpHistoryNotYetUploadedToNightscout() async throws -> [NightscoutTreatment]
    func getPumpHistoryNotYetUploadedToHealth() async throws -> [PumpHistoryEvent]
    func getPumpHistoryNotYetUploadedToTidepool() async throws -> [PumpHistoryEvent]
}

final class BasePumpHistoryStorage: PumpHistoryStorage, Injectable {
    private let processQueue = DispatchQueue(label: "BasePumpHistoryStorage.processQueue")
    @Injected() private var storage: FileStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var settings: SettingsManager!

    private let updateSubject = PassthroughSubject<Void, Never>()

    var updatePublisher: AnyPublisher<Void, Never> {
        updateSubject.eraseToAnyPublisher()
    }

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    typealias PumpEvent = PumpEventStored.EventType
    typealias TempType = PumpEventStored.TempType

    private func roundDose(_ dose: Double, toIncrement increment: Double) -> Decimal {
        let roundedValue = (dose / increment).rounded() * increment
        // `Decimal(_ double:)` captures the full binary-float representation (e.g. 0.05 * 6 →
        // 0.30000000000000004 → 0.3000…512), which then round-trips through GRDB's lossless TEXT storage
        // and breaks exact-value comparisons. Round to 4 places to strip the float artifact while keeping
        // every real insulin increment (0.1 / 0.05 / 0.025 / 0.01) intact.
        return Decimal(roundedValue).rounded(toPlaces: 4)
    }

    func storePumpEvents(_ events: [NewPumpEvent]) async throws {
        try await storePumpEvents(events, in: nil)
    }

    /// GRDB variant with an injectable `pool` (default `nil` = shared store) so tests exercise the
    /// de-dup + partial-bolus + external-insulin logic against an in-memory pool.
    ///
    /// The (timestamp, type) de-duplication, the partial-bolus smaller-value update, and the
    /// restrict-to-now clamp are preserved verbatim from the former Core Data path. The duplicate check
    /// runs in SQLite per event (`PumpEventStore.fetchExisting`) rather than against an in-memory `Date`
    /// key — the DB stores timestamps at millisecond precision, so a Swift-side key would drift on
    /// sub-millisecond timestamps and let a re-reported event slip past, hit the `(timestamp, type)`
    /// composite unique index, and abort the whole dosing write. Each insert commits before the next
    /// event, so the DB check also catches duplicates *within* this batch; the unique index remains the
    /// race-safe backstop for concurrent writers.
    func storePumpEvents(_ events: [NewPumpEvent], in pool: DatabasePool?) async throws {
        var didChange = false

        // Inserts a bare pump event unless a (timestamp, type) duplicate already exists in the store.
        // The duplicate check runs in SQLite (see `PumpEventStore.fetchExisting`) so it matches the
        // millisecond-precision the DB stores — an in-memory `Date` key would drift on sub-millisecond
        // timestamps and let a re-reported event slip past, hitting the composite unique index and
        // aborting the whole dosing write. Each insert commits before the next event, so this also
        // catches duplicates within the batch.
        @discardableResult func makeEventIfNew(timestamp: Date, type: PumpEvent, note: String? = nil) async throws -> Bool {
            guard try await PumpEventStore.fetchExisting(timestamp: timestamp, type: type.rawValue, pool: pool) == nil
            else {
                debug(.coreData, "Duplicate event found with timestamp: \(timestamp)")
                return false
            }
            let event = PumpEventRecord(id: UUID().uuidString, timestamp: timestamp, type: type.rawValue, note: note)
            try await PumpEventStore.insert(event: event, pool: pool)
            return true
        }

        for event in events {
            switch event.type {
            case .bolus:
                guard let dose = event.dose else { continue }
                let amount = roundDose(
                    dose.unitsInDeliverableIncrements,
                    toIncrement: Double(settings.preferences.bolusIncrement)
                )
                // restrict entry to now or past
                let timestamp = event.date > Date() ? Date() : event.date

                if let existingEvent = try await PumpEventStore.fetchExisting(
                    timestamp: timestamp,
                    type: PumpEvent.bolus.rawValue,
                    pool: pool
                ) {
                    // Duplicate found, do not store the event
                    debug(.coreData, "Duplicate event found with timestamp: \(event.date)")

                    if let existingAmount = existingEvent.bolus?.amount, amount < existingAmount,
                       let pk = existingEvent.event.pk
                    {
                        // Update existing event with new smaller value (e.g. a cancelled / partial bolus)
                        let isSMB = dose.automatic ?? true
                        try await PumpEventStore.updateBolusAmount(pk: pk, amount: amount, isSMB: isSMB, pool: pool)
                        didChange = true

                        debug(.coreData, "Updated existing event with smaller value: \(amount)")
                    }
                    continue
                }

                let isSMB = dose.automatic ?? true
                let newPumpEvent = PumpEventRecord(id: UUID().uuidString, timestamp: timestamp, type: PumpEvent.bolus.rawValue)
                let newBolus = BolusRecord(amount: amount, isSMB: isSMB, isExternal: dose.manuallyEntered)
                try await PumpEventStore.insert(event: newPumpEvent, bolus: newBolus, pool: pool)
                didChange = true

            case .tempBasal:
                guard let dose = event.dose else { continue }

                let delivered = dose.deliveredUnits
                let isCancel = delivered != nil
                guard !isCancel else { continue }

                guard try await PumpEventStore.fetchExisting(
                    timestamp: event.date,
                    type: PumpEvent.tempBasal.rawValue,
                    pool: pool
                ) == nil else {
                    debug(.coreData, "Duplicate event found with timestamp: \(event.date)")
                    continue
                }

                let rate = Decimal(dose.unitsPerHour)
                let minutes = (dose.endDate - dose.startDate).timeInterval / 60

                let newPumpEvent = PumpEventRecord(
                    id: UUID().uuidString,
                    timestamp: event.date,
                    type: PumpEvent.tempBasal.rawValue
                )
                let newTempBasal = TempBasalRecord(
                    duration: Int16(round(minutes)),
                    rate: rate,
                    tempType: TempType.absolute.rawValue
                )
                try await PumpEventStore.insert(event: newPumpEvent, tempBasal: newTempBasal, pool: pool)
                didChange = true

            case .suspend:
                if try await makeEventIfNew(timestamp: event.date, type: .pumpSuspend) { didChange = true }

            case .resume:
                if try await makeEventIfNew(timestamp: event.date, type: .pumpResume) { didChange = true }

            case .rewind:
                if try await makeEventIfNew(timestamp: event.date, type: .rewind) { didChange = true }

            case .prime:
                if try await makeEventIfNew(timestamp: event.date, type: .prime) { didChange = true }

            case .alarm:
                if try await makeEventIfNew(timestamp: event.date, type: .pumpAlarm, note: event.title) { didChange = true }

            case .replaceComponent(componentType: .infusionSet),
                 .replaceComponent(componentType: .pump):
                if try await makeEventIfNew(timestamp: event.date, type: .siteChange) { didChange = true }

            default:
                continue
            }
        }

        if didChange {
            updateSubject.send(())
            debug(.coreData, "\(DebuggingIdentifiers.succeeded) stored pump events in GRDB")
        }
    }

    func storeExternalInsulinEvent(amount: Decimal, timestamp: Date) async {
        await storeExternalInsulinEvent(amount: amount, timestamp: timestamp, in: nil)
    }

    func storeExternalInsulinEvent(amount: Decimal, timestamp: Date, in pool: DatabasePool?) async {
        // restrict entry to now or past
        let clampedTimestamp = timestamp > Date() ? Date() : timestamp
        let newPumpEvent = PumpEventRecord(
            id: UUID().uuidString,
            timestamp: clampedTimestamp,
            type: PumpEvent.bolus.rawValue
        )
        // external dose, manually administered
        let newBolus = BolusRecord(amount: amount, isSMB: false, isExternal: true)
        do {
            try await PumpEventStore.insert(event: newPumpEvent, bolus: newBolus, pool: pool)
            debug(.coreData, "External insulin saved")
            updateSubject.send(())
        } catch {
            debug(.coreData, "Failed to store external insulin: \(error)")
        }
    }

    func getPumpHistory() async throws -> [PumpHistoryEvent] {
        let events = try await PumpEventStore.fetchHistory(within: 24, limit: 288)
        return events.compactMap { event in
            switch event.type {
            case PumpEvent.bolus.rawValue:
                return PumpHistoryEvent(
                    id: event.event.id ?? UUID().uuidString,
                    type: .bolus,
                    timestamp: event.timestamp ?? Date(),
                    amount: event.bolus?.amount
                )
            case PumpEvent.tempBasal.rawValue:
                return PumpHistoryEvent(
                    id: event.event.id ?? UUID().uuidString,
                    type: .tempBasal,
                    timestamp: event.timestamp ?? Date(),
                    amount: event.tempBasal?.rate,
                    duration: Int(event.tempBasal?.duration ?? 0)
                )
            default:
                return nil
            }
        }
    }

    func determineBolusEventType(for event: PumpEventDetails) -> PumpEventStored.EventType {
        guard let bolus = event.bolus else {
            return event.type.flatMap { PumpEventStored.EventType(rawValue: $0) } ?? .bolus
        }
        if bolus.isSMB {
            return .smb
        }
        if bolus.isExternal {
            return .isExternal
        }
        return event.type.flatMap { PumpEventStored.EventType(rawValue: $0) } ?? .bolus
    }

    func getPumpHistoryNotYetUploadedToNightscout() async throws -> [NightscoutTreatment] {
        let fetchedPumpEvents = try await PumpEventStore.fetchNotYetUploaded(channel: .nightscout)

        return fetchedPumpEvents.compactMap { event in
            switch event.type {
            case PumpEvent.bolus.rawValue:
                // eventType determines whether bolus is external, smb or manual (=administered via app by user)
                let eventType = determineBolusEventType(for: event)
                return NightscoutTreatment(
                    duration: nil,
                    rawDuration: nil,
                    rawRate: nil,
                    absolute: nil,
                    rate: nil,
                    eventType: eventType,
                    createdAt: event.timestamp,
                    enteredBy: NightscoutTreatment.local,
                    bolus: nil,
                    insulin: event.bolus?.amount,
                    notes: nil,
                    carbs: nil,
                    fat: nil,
                    protein: nil,
                    targetTop: nil,
                    targetBottom: nil,
                    id: event.event.id
                )
            case PumpEvent.tempBasal.rawValue:
                return NightscoutTreatment(
                    duration: Int(event.tempBasal?.duration ?? 0),
                    rawDuration: nil,
                    rawRate: nil,
                    absolute: event.tempBasal?.rate,
                    rate: event.tempBasal?.rate,
                    eventType: .nsTempBasal,
                    createdAt: event.timestamp,
                    enteredBy: NightscoutTreatment.local,
                    bolus: nil,
                    insulin: nil,
                    notes: nil,
                    carbs: nil,
                    fat: nil,
                    protein: nil,
                    targetTop: nil,
                    targetBottom: nil,
                    id: event.event.id
                )
            case PumpEvent.pumpSuspend.rawValue:
                return NightscoutTreatment(
                    duration: nil,
                    rawDuration: nil,
                    rawRate: nil,
                    absolute: nil,
                    rate: nil,
                    eventType: .nsNote,
                    createdAt: event.timestamp,
                    enteredBy: NightscoutTreatment.local,
                    bolus: nil,
                    insulin: nil,
                    notes: PumpEvent.pumpSuspend.rawValue,
                    carbs: nil,
                    fat: nil,
                    protein: nil,
                    targetTop: nil,
                    targetBottom: nil
                )
            case PumpEvent.pumpResume.rawValue:
                return NightscoutTreatment(
                    duration: nil,
                    rawDuration: nil,
                    rawRate: nil,
                    absolute: nil,
                    rate: nil,
                    eventType: .nsNote,
                    createdAt: event.timestamp,
                    enteredBy: NightscoutTreatment.local,
                    bolus: nil,
                    insulin: nil,
                    notes: PumpEvent.pumpResume.rawValue,
                    carbs: nil,
                    fat: nil,
                    protein: nil,
                    targetTop: nil,
                    targetBottom: nil
                )
            case PumpEvent.rewind.rawValue:
                return NightscoutTreatment(
                    duration: nil,
                    rawDuration: nil,
                    rawRate: nil,
                    absolute: nil,
                    rate: nil,
                    eventType: .nsInsulinChange,
                    createdAt: event.timestamp,
                    enteredBy: NightscoutTreatment.local,
                    bolus: nil,
                    insulin: nil,
                    notes: nil,
                    carbs: nil,
                    fat: nil,
                    protein: nil,
                    targetTop: nil,
                    targetBottom: nil
                )
            case PumpEvent.siteChange.rawValue:
                return NightscoutTreatment(
                    duration: nil,
                    rawDuration: nil,
                    rawRate: nil,
                    absolute: nil,
                    rate: nil,
                    eventType: .nsSiteChange,
                    createdAt: event.timestamp,
                    enteredBy: NightscoutTreatment.local,
                    bolus: nil,
                    insulin: nil,
                    notes: nil,
                    carbs: nil,
                    fat: nil,
                    protein: nil,
                    targetTop: nil,
                    targetBottom: nil
                )
            case PumpEvent.pumpAlarm.rawValue:
                return NightscoutTreatment(
                    duration: 30, // minutes
                    rawDuration: nil,
                    rawRate: nil,
                    absolute: nil,
                    rate: nil,
                    eventType: .nsAnnouncement,
                    createdAt: event.timestamp,
                    enteredBy: NightscoutTreatment.local,
                    bolus: nil,
                    insulin: nil,
                    notes: "Alarm \(String(describing: event.note)) \(PumpEvent.pumpAlarm.rawValue)",
                    carbs: nil,
                    fat: nil,
                    protein: nil,
                    targetTop: nil,
                    targetBottom: nil
                )

            default:
                return nil
            }
        }
    }

    func getPumpHistoryNotYetUploadedToHealth() async throws -> [PumpHistoryEvent] {
        let fetchedPumpEvents = try await PumpEventStore.fetchNotYetUploaded(channel: .health)

        return fetchedPumpEvents.compactMap { event in
            switch event.type {
            case PumpEvent.bolus.rawValue:
                return PumpHistoryEvent(
                    id: event.event.id ?? UUID().uuidString,
                    type: .bolus,
                    timestamp: event.timestamp ?? Date(),
                    amount: event.bolus?.amount
                )
            case PumpEvent.tempBasal.rawValue:
                if let id = event.event.id, let timestamp = event.timestamp, let tempBasal = event.tempBasal,
                   let tempBasalRate = tempBasal.rate
                {
                    return PumpHistoryEvent(
                        id: id,
                        type: .tempBasal,
                        timestamp: timestamp,
                        amount: tempBasalRate,
                        duration: Int(tempBasal.duration)
                    )
                } else {
                    return nil
                }
            default:
                return nil
            }
        }
    }

    func getPumpHistoryNotYetUploadedToTidepool() async throws -> [PumpHistoryEvent] {
        let fetchedPumpEvents = try await PumpEventStore.fetchNotYetUploaded(channel: .tidepool)

        return fetchedPumpEvents.compactMap { event in
            switch event.type {
            case PumpEvent.bolus.rawValue:
                return PumpHistoryEvent(
                    id: event.event.id ?? UUID().uuidString,
                    type: .bolus,
                    timestamp: event.timestamp ?? Date(),
                    amount: event.bolus?.amount,
                    isSMB: event.bolus?.isSMB ?? true,
                    isExternal: event.bolus?.isExternal ?? false
                )
            case PumpEvent.tempBasal.rawValue:
                if let id = event.event.id, let timestamp = event.timestamp, let tempBasal = event.tempBasal,
                   let tempBasalRate = tempBasal.rate
                {
                    return PumpHistoryEvent(
                        id: id,
                        type: .tempBasal,
                        timestamp: timestamp,
                        amount: tempBasalRate,
                        duration: Int(tempBasal.duration)
                    )
                } else {
                    return nil
                }

            default:
                return nil
            }
        }
    }
}
