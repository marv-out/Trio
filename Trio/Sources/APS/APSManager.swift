import Combine
import CoreData
import Foundation
import LoopKit
import LoopKitUI
import SwiftDate
import Swinject

protocol APSManager {
    func heartbeat(date: Date)
    /// Mark the next loop attempt as user-initiated (e.g. force-loop button).
    /// Surfaces transient errors immediately instead of waiting for the
    /// usual dwell threshold — when the user explicitly asks for a loop,
    /// they want feedback even if the underlying error is "transient".
    func markNextLoopUserInitiated()
    func enactBolus(amount: Double, isSMB: Bool, callback: ((Bool, String) -> Void)?) async
    var pumpManager: PumpManagerUI? { get set }
    var bluetoothManager: BluetoothStateManager? { get }
    var pumpDisplayState: CurrentValueSubject<PumpDisplayState?, Never> { get }
    var pumpName: CurrentValueSubject<String, Never> { get }
    var isLooping: CurrentValueSubject<Bool, Never> { get }
    var lastLoopDate: Date { get }
    var lastLoopDateSubject: PassthroughSubject<Date, Never> { get }
    var bolusProgress: CurrentValueSubject<Decimal?, Never> { get }
    var pumpExpiresAtDate: CurrentValueSubject<Date?, Never> { get }
    var pumpActivatedAtDate: CurrentValueSubject<Date?, Never> { get }
    var isManualTempBasal: Bool { get }
    var isSuspended: Bool { get }
    /// Runs a determination outside the loop, after a treatment or adjustment changed what the
    /// algorithm reads. Waits for a loop in flight to finish first, since that loop determined
    /// before the change landed. Concurrent calls collapse into the one already running. Algorithm
    /// errors propagate to the caller.
    func determineBasalSync() async throws
    func simulateDetermineBasal(
        simulatedCarbsAmount: Decimal,
        simulatedBolusAmount: Decimal,
        simulatedCarbsDate: Date?
    ) async -> Determination?
    func roundBolus(amount: Decimal) -> Decimal
    var lastError: CurrentValueSubject<Error?, Never> { get }
    func cancelBolus(_ callback: ((Bool, String) -> Void)?) async
    /// Runs the Boost re-derivation now, from the settings screen, and returns one line per result.
    func runBoostAutoConfigNow(overrideHypoProtections: Bool) async -> [String]
    var iobFileDidUpdate: PassthroughSubject<Void, Never> { get }
}

/// Notified after a bolus-related failure so observing UI (e.g. the
/// treatment screen's bolus state) can clean up state. Broadcast by
/// `APSManager` from `enactBolus` / `cancelBolus` error paths.
protocol BolusFailureObserver {
    func bolusDidFail()
}

enum APSError: LocalizedError {
    case pumpError(Error)
    case invalidPumpState(message: String)
    case glucoseError(message: String)
    case apsError(message: String)
    case manualBasalTemp(message: String)

    var errorDescription: String? {
        switch self {
        case let .pumpError(error):
            return String(localized: "Pump Error (\(error.localizedDescription)).")
        case let .invalidPumpState(message):
            return String(localized: "Invalid Pump State (\(message)).")
        case let .glucoseError(message):
            return String(localized: "Invalid Glucose (\(message)).")
        case let .apsError(message):
            return String(localized: "Invalid Algorithm Response (\(message)).")
        case let .manualBasalTemp(message):
            return String(localized: "Manual Temporary Basal Rate (\(message)). Looping suspended.")
        }
    }
}

// MARK: - Thread-safe loop serialization

/// Ensures only one loop runs at a time via actor isolation
private actor LoopGuard {
    private var isRunning = false
    private var isDeterminingStandalone = false
    private var loopWaiters: [CheckedContinuation<Void, Never>] = []

    /// Atomically checks whether a new loop can start and marks it as running if so.
    func tryStart(minInterval: TimeInterval, lastLoopDate: Date, lastLoopStartDate: Date) -> Bool {
        // If the last loop completed after it started, enforce minimum interval
        if lastLoopDate > lastLoopStartDate {
            guard lastLoopStartDate.addingTimeInterval(minInterval) < Date() else { return false }
        }
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    func finish() {
        isRunning = false
        let waiters = loopWaiters
        loopWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Returns once no loop is running.
    func waitForLoop() async {
        guard isRunning else { return }
        await withCheckedContinuation { loopWaiters.append($0) }
    }

    /// Claims the guard for a determination that runs outside the loop. Refuses while another one
    /// runs, since it computes the same state. `tryStart` ignores this claim: a skipped loop has a
    /// therapy cost, an overlapping determination only wastes work.
    func tryStartStandaloneDetermination() -> Bool {
        guard !isDeterminingStandalone else { return false }
        isDeterminingStandalone = true
        return true
    }

    func finishStandaloneDetermination() {
        isDeterminingStandalone = false
    }
}

final class BaseAPSManager: APSManager, Injectable {
    private let processQueue = DispatchQueue(label: "BaseAPSManager.processQueue")
    private let therapyProfileManagerLock = NSLock()
    private var resolvedTherapyProfileManager: TherapyProfileManager?
    @Injected() private var storage: FileStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var determinationStorage: DeterminationStorage!
    @Injected() private var deviceDataManager: DeviceDataManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var tddStorage: TDDStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var trioAlertManager: TrioAlertManager!
    @Injected() private var boostActivityMonitor: BoostActivityMonitor!
    @Persisted(key: "lastLoopStartDate") private var lastLoopStartDate: Date = .distantPast
    private var lastDosingMode: DosingMode?
    @Persisted(key: "lastLoopDate") var lastLoopDate: Date = .distantPast {
        didSet {
            lastLoopDateSubject.send(lastLoopDate)
        }
    }

    private var openAPS: OpenAPS!

    private var lifetime = Lifetime()

    private let loopGuard = LoopGuard()
    /// All reads/writes are dispatched onto `processQueue` so the bolus
    /// trigger sink, `cancelBolus`, and the `DoseProgressReporter`
    /// callback (which the pump manager already invokes on
    /// `processQueue`) all serialize through one queue
    private var bolusReporter: DoseProgressReporter?

    var pumpManager: PumpManagerUI? {
        get { deviceDataManager.pumpManager }
        set { deviceDataManager.pumpManager = newValue }
    }

    var bluetoothManager: BluetoothStateManager? { deviceDataManager.bluetoothManager }

    @Persisted(key: "isManualTempBasal") var isManualTempBasal: Bool = false

    @Persisted(key: "isSuspended") var isSuspended: Bool = false

    let isLooping = CurrentValueSubject<Bool, Never>(false)
    let lastLoopDateSubject = PassthroughSubject<Date, Never>()
    let lastError = CurrentValueSubject<Error?, Never>(nil)
    let iobFileDidUpdate = PassthroughSubject<Void, Never>()

    let bolusProgress = CurrentValueSubject<Decimal?, Never>(nil)

    var pumpDisplayState: CurrentValueSubject<PumpDisplayState?, Never> {
        deviceDataManager.pumpDisplayState
    }

    var pumpName: CurrentValueSubject<String, Never> {
        deviceDataManager.pumpName
    }

    var pumpExpiresAtDate: CurrentValueSubject<Date?, Never> {
        deviceDataManager.pumpExpiresAtDate
    }

    var pumpActivatedAtDate: CurrentValueSubject<Date?, Never> {
        deviceDataManager.pumpActivatedAtDate
    }

    var settings: TrioSettings {
        get { settingsManager.settings }
        set { settingsManager.settings = newValue }
    }

    /// The profile manager depends on this manager, so it is resolved on first use, through the app's locked resolver:
    /// the loop runs on several threads, and Swinject's container is not safe to use from more than one at a time.
    private var therapyProfileManager: TherapyProfileManager? {
        therapyProfileManagerLock.lock()
        defer { therapyProfileManagerLock.unlock() }
        if resolvedTherapyProfileManager == nil {
            resolvedTherapyProfileManager = TrioApp.resolver.resolve(TherapyProfileManager.self)
        }
        return resolvedTherapyProfileManager
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        openAPS = OpenAPS(storage: storage, tddStorage: tddStorage, glucoseStorage: glucoseStorage, carbsStorage: carbsStorage)
        lastDosingMode = settingsManager.settings.dosingMode
        broadcaster.register(SettingsObserver.self, observer: self)
        subscribe()
        lastLoopDateSubject.send(lastLoopDate)

        isLooping
            .weakAssign(to: \.deviceDataManager.loopInProgress, on: self)
            .store(in: &lifetime)
    }

    private func subscribe() {
        if settingsManager.settings.units == .mmolL {
            let wasParsed = storage.parseOnFileSettingsToMgdL()
            if wasParsed {
                Task {
                    do {
                        try await openAPS.createProfiles(for: self.settingsManager.settings.dosingMode)
                    } catch {
                        warning(.algorithm, "Creating profiles after unit conversion failed", error: error)
                    }
                }
            }
        }

        deviceDataManager.recommendsLoop
            .receive(on: processQueue)
            .sink { [weak self] in
                self?.loop()
            }
            .store(in: &lifetime)

        deviceDataManager.errorSubject
            .receive(on: processQueue)
            .map { APSError.pumpError($0) }
            .sink { [weak self] in
                self?.processError($0)
            }
            .store(in: &lifetime)

        deviceDataManager.bolusTrigger
            .receive(on: processQueue)
            .sink { [weak self] bolusState in
                switch bolusState {
                case .initiating,
                     .inProgress:
                    self?.createBolusReporter()
                case .noBolus:
                    self?.clearBolusReporter()
                }
            }
            .store(in: &lifetime)

        deviceDataManager.suspended
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suspended in
                self?.isSuspended = suspended
            }
            .store(in: &lifetime)

        // manage a manual Temp Basal from PumpManager - force loop() after manual temp basal is cancelled or finishes
        deviceDataManager.manualTempBasal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] manualBasal in
                if manualBasal {
                    self?.isManualTempBasal = true
                } else {
                    if self?.isManualTempBasal == true {
                        self?.isManualTempBasal = false
                        self?.loop()
                    }
                }
            }
            .store(in: &lifetime)
    }

    func heartbeat(date: Date) {
        deviceDataManager.heartbeat(date: date)
    }

    // Loop entry point
    private func loop() {
        Task { [weak self] in
            guard let self else { return }

            // Consume the user-initiated flag unconditionally — it was set
            // for the loop the user just triggered. If the guards below block
            // (suspended, too-soon, no pump), the next scheduled tick must
            // not inherit it and bypass dwell suppression for an error the
            // user didn't request.
            let userInitiated = self.nextLoopUserInitiated
            self.nextLoopUserInitiated = false

            // Don't try to run a loop while pump setup / pod pairing is in
            // progress — `verifyStatus` would throw `invalidPumpState("Pump
            // not set")` and surface a modal banner on top of the pod
            // activation sheet, closing the sheet (reported by tester during
            // O5 pairing).
            guard self.pumpManager != nil else {
                debug(.loop, "Loop skipped: no pump configured")
                return
            }

            // Before the loop starts, so the loop doses with the new profile.
            await self.therapyProfileManager?.runDueScheduledSwitch()

            // Atomic check-and-set via actor — eliminates the race between
            // checking isLooping.value and sending isLooping(true).
            guard await loopGuard.tryStart(
                minInterval: Config.loopInterval,
                lastLoopDate: lastLoopDate,
                lastLoopStartDate: lastLoopStartDate
            ) else {
                debug(.loop, "Loop skipped: already running or too soon")
                return
            }

            // Affects whether transient errors surface immediately instead of
            // dwell-suppressed (see `surfaceErrorIfNeeded`).
            self.currentLoopUserInitiated = userInitiated
            defer { self.currentLoopUserInitiated = false }

            // Start background task
            // we probably need to refactor this when implementing Swift 6 due to mutation of a captured var in an async context
            var taskID: UIBackgroundTaskIdentifier = .invalid
            taskID = await UIApplication.shared.beginBackgroundTask(withName: "Loop starting") {
                // closure runs on the Main Thread
                // removed the Task that provided no guarantee to end the background task
                if taskID != .invalid {
                    UIApplication.shared.endBackgroundTask(taskID)
                    taskID = .invalid
                }
            }

            isLooping.send(true)
            info(.loop, "Loop started, mode \(settings.dosingMode.rawValue)\(userInitiated ? ", requested by user" : "")")

            let loopStartDate = Date()
            lastLoopStartDate = loopStartDate
            let interval = await calculateLoopInterval(loopStartDate: loopStartDate)

            var loopStatRecord = LoopStats(
                start: loopStartDate,
                loopStatus: "Starting",
                interval: interval
            )

            do {
                let enacted = try await executeLoop(loopStatRecord: &loopStatRecord)
                requestNightscoutUpload(
                    [.carbs, .pumpHistory, .overrides, .tempTargets, .profiles],
                    source: "APSManager"
                )
                await finalizeLoop(enacted: enacted, loopStatRecord: loopStatRecord)
            } catch {
                let endDate = Date()
                loopStatRecord.end = endDate
                loopStatRecord.duration = roundDouble((endDate - loopStatRecord.start).timeInterval / 60, 2)
                loopStatRecord.loopStatus = error.localizedDescription
                await finalizeLoop(error: error, loopStatRecord: loopStatRecord)
            }

            // End the background task
            if taskID != .invalid {
                await UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
    }

    /// Returns whether the determination was enacted.
    private func executeLoop(loopStatRecord: inout LoopStats) async throws -> Bool {
        try await determineBasal()

        // Closed loop: also enact the determination.
        var enacted = false
        if settings.dosingMode.automation != .off {
            enacted = try await enactDetermination()
        }

        let endDate = Date()
        loopStatRecord.end = endDate
        loopStatRecord.duration = roundDouble((endDate - loopStatRecord.start).timeInterval / 60, 2)
        loopStatRecord.loopStatus = "Success"
        return enacted
    }

    private func calculateLoopInterval(loopStartDate: Date) async -> Double? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "calculateLoopInterval"
        do {
            return try await context.perform { [weak self] in
                guard let self else { return nil }
                let requestStats = LoopStatRecord.fetchRequest() as NSFetchRequest<LoopStatRecord>
                let sortStats = NSSortDescriptor(key: "end", ascending: false)
                requestStats.sortDescriptors = [sortStats]
                requestStats.fetchLimit = 1
                let previousLoop = try context.fetch(requestStats)

                if (previousLoop.first?.end ?? .distantFuture) < loopStartDate {
                    return self.roundDouble(
                        (loopStartDate - (previousLoop.first?.end ?? Date())).timeInterval / 60,
                        1
                    )
                }
                return nil
            }
        } catch {
            warning(.storage, "Fetching the last loop for its interval failed", error: error)
            return nil
        }
    }

    /// Single exit point for loop — replaces the old `loopCompleted()`.
    private func finalizeLoop(error: Error? = nil, enacted: Bool = false, loopStatRecord: LoopStats) async {
        await loopGuard.finish()
        isLooping.send(false)

        if let error = error {
            warning(.loop, "Loop failed", error: error)
            processError(error)
        } else {
            info(.loop, "Loop finished in \(String(format: "%.1f", Date().timeIntervalSince(loopStatRecord.start))) s")
            lastLoopDate = Date()
            lastError.send(nil)
            transientCategoryFirstSeen.removeAll()
            transientCategoryCount.removeAll()
        }

        loopStats(loopStatRecord: loopStatRecord)

        if settings.dosingMode.automation != .off {
            await reportEnacted(wasEnacted: error == nil && enacted)
        }
    }

    private func verifyStatus() -> Error? {
        guard let pump = pumpManager else {
            return APSError.invalidPumpState(message: String(localized: "Pump not set"))
        }
        let status = pump.status.pumpStatus

        guard !status.bolusing else {
            return APSError.invalidPumpState(message: String(localized: "Pump is bolusing"))
        }

        guard !status.suspended else {
            return APSError.invalidPumpState(message: String(localized: "Pump suspended"))
        }

        return nil
    }

    private func autosense() async throws -> Bool {
        guard let autosense = await storage.retrieveAsync(OpenAPS.Settings.autosense, as: Autosens.self),
              (autosense.timestamp ?? .distantPast).addingTimeInterval(30.minutes.timeInterval) > Date()
        else {
            let result = try await openAPS.autosense(
                shouldSmoothGlucose: settingsManager.settings.smoothGlucose
            )
            return result != nil
        }

        return false
    }

    /// Calculates and stores the Total Daily Dose (TDD)
    private func calculateAndStoreTDD() async throws {
        guard let pumpManager else { return }

        let basalProfile = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []

        // Calculate TDD; uncovered gaps are inferred from the basal profile in memory
        let tddResult = try await tddStorage.calculateTDD(
            pumpManager: pumpManager,
            pumpHistory: pumpHistoryStorage.getPumpHistory(),
            basalProfile: basalProfile
        )

        // Store TDD in Core Data
        await tddStorage.storeTDD(tddResult)
    }

    private func determineBasal() async throws {
        // Keep BG impact on ISF consistent with TDD-based ISF before anything reads it (AAPS
        // 3d9d471dbb, f393d02e55). The engine already enforces it at read time; this writes it back
        // so the settings screen shows what the engine uses.
        reconcileBoostSensitivitySettings()
        // Before the determination, so Boost's first cycle is sized by its starting SMB minutes.
        seedBoostSmbBasalMinutes()

        // One-shot: on first switch to Boost V5 active, seed the V5 knobs from the user's own prior
        // (oref) dosing history. Guarded + self-contained; never throws into the dose path.
        await maybeAutoConfigureBoostV5()

        // Periodic re-derivation, every 7 days over a 28-day window (AAPS 2026-08-03). Detached
        // deliberately: the derivation reads a month of glucose and pump history, and nothing that
        // large belongs on the dose path. AAPS moved it off for the same reason. A failure is
        // swallowed, so it can never affect this cycle.
        // Not while onboarding still owns a knob (AAPS maybeRedrive ONBOARDING_INCOMPLETE): a switch
        // re-derivation wrote would otherwise read to onboarding as set by the person, and freeze.
        let onboardingDone = BoostAutoConfigKnob.allCases
            .allSatisfy { settingsManager.preferences.boostV5AutoConfigResolved.contains($0.rawValue) }
        if settingsManager.preferences.boostMode == .active, onboardingDone, BoostRedriveStore.isDue(now: Date()) {
            Task.detached(priority: .utility) { [weak self] in
                guard BoostRedriveStore.tryBeginRun() else { return }
                defer { BoostRedriveStore.endRun() }
                // Checked again under the run lock: a run by hand may have finished meanwhile.
                guard BoostRedriveStore.isDue(now: Date()) else { return }
                await self?.redriveBoostAutoConfig()
            }
        }

        try await calculateAndStoreTDD()

        var invalidGlucoseError: String?

        // Fetch glucose and run validation on the same context to avoid cross-context property access.
        let validationContext = CoreDataStack.shared.newTaskContext()
        validationContext.name = "determineBasal.validation"

        let isValidGlucoseData = await validationContext.perform { [weak self] in
            guard let self else { return false }

            let glucose: [GlucoseStored]
            do {
                glucose = try self.fetchGlucose(
                    on: validationContext,
                    predicate: NSPredicate.predicateForOneHourAgo,
                    fetchLimit: 6
                )
            } catch {
                warning(.loop, "Fetching glucose for validation failed", error: error)
                return false
            }

            guard glucose.count > 2 else {
                debug(.loop, "Glucose check failed: \(glucose.count) readings in the last hour, need 3")
                invalidGlucoseError =
                    String(
                        localized: "Not enough glucose data. You need at least three glucose readings in the last six hours to run the algorithm."
                    )
                return false
            }

            let dateOfLastGlucose = glucose.first?.date
            guard dateOfLastGlucose ?? Date() >= Date().addingTimeInterval(-12.minutes.timeInterval) else {
                debug(.loop, "Glucose check failed: latest reading older than 12 min")
                invalidGlucoseError =
                    String(localized: "Glucose data is stale. The most recent glucose reading is from more than 12 minutes ago.")
                return false
            }

            info(.loop, "Glucose ready: BG \(glucose.first?.glucose ?? 0) mg/dL, \(glucose.count) recent readings")
            return true
        }

        do {
            let now = Date()

            // put profile creation up front since autosens needs it
            try await openAPS.createProfiles(for: settingsManager.settings.dosingMode)
            let currentTemp = try await fetchCurrentTempBasal(date: now)
            _ = try await autosense()

            // Boost: advance the activity/sleep state machine on the loop cadence (AAPS runs its
            // sleep detector every invoke). Without this the detector only updates on HealthKit
            // observer callbacks, which go quiet overnight exactly when drought-based sleep should
            // engage — leaving the snapshot stale and silently disengaging night-mode suppression.
            // Awaited so this cycle's determination reads the freshly-written snapshot (HealthKit
            // completion handlers always fire, so this can't hang the loop; the snapshot's 30-min
            // staleness guard is the backstop). Only when Boost is enabled — when off, nothing reads
            // the snapshot, so the HealthKit work would be pure waste.
            let boostPrefs = storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self)
            let boostEnabled = (boostPrefs?.boostMode ?? .off) != .off
            if boostEnabled {
                await boostActivityMonitor.refresh()
            }

            // Composed brake-floor hypo-gate (2026-07-08, AAPS 9110ef2520 + 8b492a08e7). The floor is
            // insulin-ADDING, so it may engage only while the user's trailing-14d TBR<63 < 2.0% AND
            // TBR<70 < 3.5% (fail-closed). A 14d metric barely moves within an hour, so recompute at
            // most hourly and only when the floor could actually engage (active mode + toggle on) —
            // otherwise the gate stays fail-closed and the 14d BG scan is skipped. BoostV5Adapter
            // ANDs the cached result into composedFloorActive, and since Boost 6.3.0 (AAPS 2221fcb96c)
            // into aggressive early confirm, so either switch being on keeps the gate fresh. Shadow
            // mode refreshes it too, so the logged would-be dose sees the gate active mode would.
            if (boostPrefs?.boostMode ?? .off) != .off,
               boostPrefs?.boostV5ComposedFloorActive == true || boostPrefs?.boostV5AggressiveEarlyConfirm == true,
               BoostComposedFloorGate.shouldRecompute(now: now)
            {
                let since = now.addingTimeInterval(-14 * 86400)
                // dev's `fetchGlucose` is synchronous and context-bound: fetch and read the managed
                // objects inside the context's own `perform`, returning plain Ints.
                let floorContext = CoreDataStack.shared.newTaskContext()
                floorContext.name = "boostComposedFloorGate"
                let values = try await floorContext.perform {
                    let bgs = try self.fetchGlucose(
                        on: floorContext,
                        predicate: NSPredicate(format: "date >= %@", since as NSDate),
                        // No count limit: on a one-minute CGM a cap kept only the newest few days.
                        batchSize: 1000
                    )
                    return bgs.compactMap { Int($0.glucose) }.filter { (20 ... 600).contains($0) }
                }
                BoostComposedFloorGate.update(now: now, glucoseValuesMgdl: values)
            }

            let determination = try await openAPS.determineBasal(
                for: settingsManager.settings.dosingMode,
                currentTemp: currentTemp,
                supportedBasalRates: supportedBasalRates,
                shouldSmoothGlucose: settingsManager.settings.smoothGlucose,
                clock: now
            )
            iobFileDidUpdate.send(())

            guard isValidGlucoseData else {
                throw APSError.glucoseError(message: "Glucose validation failed")
            }

            if let determination = determination {
                info(
                    .loop,
                    "Determination: eventual BG \(determination.eventualBG.map { "\($0) mg/dL" } ?? "none"), temp basal \(determination.rate.map { "\($0) U/h for \(determination.duration ?? 0) min" } ?? "none"), SMB \(determination.units ?? 0) U"
                )
                // Capture weak self in closure
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.broadcaster.notify(DeterminationObserver.self, on: .main) {
                        $0.determinationDidUpdate(determination)
                    }
                }
            }
        } catch {
            iobFileDidUpdate.send(())

            // if we have a glucose validation error we might still run
            // determineBasal to try to get IoB and CoB updates but we
            // know that it will fail, so the invalidGlucoseError always
            // takes priority
            if let invalidGlucoseError = invalidGlucoseError {
                throw APSError.apsError(message: invalidGlucoseError)
            } else {
                throw APSError.apsError(message: "Error determining basal: \(error.localizedDescription)")
            }
        }
    }

    func determineBasalSync() async throws {
        await loopGuard.waitForLoop()
        guard await loopGuard.tryStartStandaloneDetermination() else {
            debug(.loop, "Standalone determination skipped: one is already running")
            return
        }
        do {
            try await determineBasal()
        } catch {
            await loopGuard.finishStandaloneDetermination()
            throw error
        }
        await loopGuard.finishStandaloneDetermination()
    }

    func simulateDetermineBasal(
        simulatedCarbsAmount: Decimal,
        simulatedBolusAmount: Decimal,
        simulatedCarbsDate: Date? = nil
    ) async -> Determination? {
        do {
            let temp = try await fetchCurrentTempBasal(date: Date.now)
            return try await openAPS.determineBasal(
                for: settingsManager.settings.dosingMode,
                currentTemp: temp,
                supportedBasalRates: supportedBasalRates,
                shouldSmoothGlucose: settingsManager.settings.smoothGlucose,
                clock: Date(),
                simulatedCarbsAmount: simulatedCarbsAmount,
                simulatedBolusAmount: simulatedBolusAmount,
                simulatedCarbsDate: simulatedCarbsDate,
                simulation: true
            )
        } catch {
            warning(.algorithm, "Simulated determination failed", error: error)
            return nil
        }
    }

    /// The paired pump's deliverable basal rates, for the algorithm to round against.
    /// Rounded to 3 dp because the kits build their tables as `Double(n) / 20` and similar, and the
    /// resulting binary error would push an entry just above the clean rate it is meant to match.
    private var supportedBasalRates: [Decimal] {
        (pumpManager?.supportedBasalRates ?? []).map { Decimal($0).rounded(scale: 3) }
    }

    func roundBolus(amount: Decimal) -> Decimal {
        guard let pump = pumpManager else { return amount }
        let rounded = Decimal(pump.roundToSupportedBolusVolume(units: Double(amount)))
        let maxBolus = Decimal(pump.roundToSupportedBolusVolume(units: Double(settingsManager.pumpSettings.maxBolus)))
        return min(rounded, maxBolus)
    }

    func enactBolus(amount: Double, isSMB: Bool, callback: ((Bool, String) -> Void)?) async {
        // Answer every caller: a silent return here left the watch waiting on "Processing…" forever
        guard amount > 0 else {
            warning(.bolus, "Bolus of \(amount) U not enacted, amount must be above 0")
            callback?(false, Self.invalidBolusAmountMessage)
            return
        }

        if let error = verifyStatus() {
            warning(.bolus, "Bolus of \(amount) U not enacted", error: error)
            processError(error)
            // Capture broadcaster and queue before async context
            let broadcaster = self.broadcaster
            Task { @MainActor in
                broadcaster?.notify(BolusFailureObserver.self, on: .main) {
                    $0.bolusDidFail()
                }
            }
            callback?(false, String(localized: "Error! Failed to enact bolus.", comment: "Error message for enacting a bolus"))
            return
        }

        guard let pump = pumpManager else {
            callback?(false, String(localized: "Error! Failed to enact bolus.", comment: "Error message for enacting a bolus"))
            return
        }

        let roundedAmount = pump.roundToSupportedBolusVolume(units: amount)

        guard roundedAmount > 0 else {
            warning(.bolus, "Bolus of \(amount) U not enacted, rounds to 0 U on this pump")
            callback?(false, Self.invalidBolusAmountMessage)
            return
        }

        debug(.bolus, "Enacting bolus \(roundedAmount) U, \(isSMB ? "automatic" : "manual")")

        do {
            try await pump.enactBolus(units: roundedAmount, automatic: isSMB)
            info(.bolus, "Bolus enacted: \(roundedAmount) U, \(isSMB ? "automatic" : "manual")")
            bolusProgress.send(0)
            callback?(true, String(localized: "Bolus enacted successfully.", comment: "Success message for enacting a bolus"))
            if !isSMB {
                do {
                    try await determineBasalSync()
                } catch {
                    warning(.loop, "Determination after manual bolus failed", error: error)
                }
            }
        } catch let bolusError {
            error(.bolus, "Bolus of \(roundedAmount) U failed", error: bolusError)
            lastError.send(APSError.pumpError(bolusError))
            issueAlertForCategory(
                .bolusFailed,
                title: String(localized: "Bolus failed"),
                body: String(localized: "Check pump history before repeating.")
                    + "\n\n\(bolusError.localizedDescription)"
            )
            if !isSMB {
                let broadcaster = self.broadcaster
                Task { @MainActor in
                    broadcaster?.notify(BolusFailureObserver.self, on: .main) {
                        $0.bolusDidFail()
                    }
                }
            }
            callback?(
                false,
                String(localized: "Error! Bolus failed with error: \(bolusError.localizedDescription)")
            )
        }
    }

    static let invalidBolusAmountMessage = String(
        localized: "Error! Bolus amount must be greater than 0 U.",
        comment: "Error message when a bolus of zero or less is requested"
    )

    func cancelBolus(_ callback: ((Bool, String) -> Void)?) async {
        guard let pump = pumpManager, pump.status.pumpStatus.bolusing else { return }
        debug(.bolus, "Cancelling bolus")
        do {
            _ = try await pump.cancelBolus()
            info(.bolus, "Bolus cancelled")
            callback?(true, String(localized: "Bolus cancelled successfully.", comment: "Success message for canceling a bolus"))
        } catch let cancelError {
            error(.bolus, "Bolus cancellation failed", error: cancelError)
            lastError.send(APSError.pumpError(cancelError))
            issueAlertForCategory(
                .bolusFailed,
                title: String(localized: "Bolus cancellation failed"),
                body: String(localized: "Try again.") + "\n\n\(cancelError.localizedDescription)"
            )
            callback?(
                false,
                String(
                    localized: "Error! Bolus cancellation failed with error: \(cancelError.localizedDescription)",
                    comment: "Error message for canceling a bolus"
                )
            )
        }
        clearBolusReporter()
    }

    private func fetchCurrentTempBasal(date: Date) async throws -> TempBasal {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchCurrentTempBasal"
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate.recentPumpHistory,
            key: "timestamp",
            ascending: false,
            fetchLimit: 1,
            relationshipKeyPathsForPrefetching: ["tempBasal"]
        )

        let fetchedTempBasal = await context.perform {
            guard let fetchedResults = results as? [PumpEventStored],
                  let tempBasalEvent = fetchedResults.first,
                  let tempBasal = tempBasalEvent.tempBasal,
                  let eventTimestamp = tempBasalEvent.timestamp
            else {
                return TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: date)
            }

            let delta = Int((date.timeIntervalSince1970 - eventTimestamp.timeIntervalSince1970) / 60)
            let duration = max(0, Int(tempBasal.duration) - delta)
            let rate = tempBasal.rate as? Decimal ?? 0
            return TempBasal(duration: duration, rate: rate, temp: .absolute, timestamp: date)
        }

        guard let state = pumpManager?.status.basalDeliveryState else { return fetchedTempBasal }

        switch state {
        case .active,
             .pumpInoperable:
            return TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: date)
        case let .tempBasal(dose):
            let rate = Decimal(dose.unitsPerHour)
            let durationMin = max(0, Int((dose.endDate.timeIntervalSince1970 - date.timeIntervalSince1970) / 60))
            return TempBasal(duration: durationMin, rate: rate, temp: .absolute, timestamp: date)
        default:
            return fetchedTempBasal
        }
    }

    /// Returns false when the determination is skipped because the pump is suspended.
    private func enactDetermination() async throws -> Bool {
        guard let determinationID = try await determinationStorage
            .fetchLastDeterminationObjectID(predicate: NSPredicate.predicateFor30MinAgoForDetermination).first
        else {
            throw APSError.apsError(message: "Determination not found")
        }

        guard let pump = pumpManager else {
            throw APSError.apsError(message: "Pump not set")
        }

        if pump.status.pumpStatus.suspended {
            info(.loop, "Determination not enacted: pump suspended")
            return false
        }

        // Unable to do temp basal during manual temp basal 😁
        if isManualTempBasal {
            throw APSError.manualBasalTemp(message: "Loop not possible during the manual basal temp")
        }

        let (rateDecimal, durationInSeconds, smbToDeliver) = try await setValues(determinationID: determinationID)

        if let rate = rateDecimal, let duration = durationInSeconds {
            try await performBasal(pump: pump, rate: rate, duration: duration)
            info(.loop, "Temp basal enacted: \(rate) U/h for \(Int(duration / 60)) min")
        }

        // only perform a bolus if smbToDeliver is > 0
        if let smb = smbToDeliver, smb.compare(NSDecimalNumber(value: 0)) == .orderedDescending {
            try await performBolus(pump: pump, smbToDeliver: smb)
            info(.loop, "SMB enacted: \(smb) U")
        }
        return true
    }

    private func setValues(determinationID: NSManagedObjectID) async throws
        -> (NSDecimalNumber?, TimeInterval?, NSDecimalNumber?)
    {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "setValues"
        return try await context.perform {
            do {
                let determination = try context.existingObject(with: determinationID) as? OrefDetermination

                let rate = determination?.rate
                let duration = determination?.duration.flatMap { TimeInterval(truncating: $0) * 60 }
                let smbToDeliver = determination?.smbToDeliver ?? 0

                return (rate, duration, smbToDeliver)
            } catch {
                throw error
            }
        }
    }

    private func performBasal(pump: PumpManager, rate: NSDecimalNumber, duration: TimeInterval) async throws {
        // the algorithm already floored this against the pump's own table, so don't floor it
        // again here: the Decimal -> Double hop can land a hair low and cost a whole increment
        let unitsPerHour = rate.decimalValue.nearestDouble
        if pump.roundToSupportedBasalRate(unitsPerHour: unitsPerHour) != unitsPerHour {
            debug(.pump, "Temp basal \(unitsPerHour) U/h is not on the pump's rate table")
        }
        try await pump.enactTempBasal(unitsPerHour: unitsPerHour, for: duration)
    }

    private func performBolus(pump: PumpManager, smbToDeliver: NSDecimalNumber) async throws {
        // Safety clamp: an automatic SMB must never exceed the user's configured Max Bolus, mirroring
        // the manual path (roundBolus). Guards against an over-large determination (e.g. a Boost
        // override) reaching the pump unclamped.
        //
        // The requested volume is not re-rounded, following the same reasoning as performBasal
        // above: the algorithm already floored it against the pump's table, and the Decimal -> Double
        // hop can land a hair low and cost a whole increment. Only the cap goes through
        // roundToSupportedBolusVolume, so a clamped dose is still a volume the pump can deliver.
        let requested = smbToDeliver.decimalValue.nearestDouble
        let maxBolus = pump.roundToSupportedBolusVolume(units: settingsManager.pumpSettings.maxBolus.nearestDouble)
        try await pump.enactBolus(units: min(requested, maxBolus), automatic: true)
        bolusProgress.send(0)
    }

    private func reportEnacted(wasEnacted: Bool) async {
        do {
            guard let determinationID = try await determinationStorage
                .fetchLastDeterminationObjectID(predicate: NSPredicate.predicateFor30MinAgoForDetermination).first
            else {
                debug(.loop, "No recent determination to mark as enacted")
                return
            }

            let context = CoreDataStack.shared.newTaskContext()
            context.name = "reportEnacted"
            try await context.perform {
                guard let determinationUpdated = try context
                    .existingObject(with: determinationID) as? OrefDetermination
                else {
                    debug(.loop, "Determination to mark as enacted no longer exists")
                    return
                }

                determinationUpdated.timestamp = Date()
                determinationUpdated.enacted = wasEnacted
                determinationUpdated.isUploadedToNS = false

                guard context.hasChanges else { return }
                try context.save()
                debug(.loop, "Determination marked as \(wasEnacted ? "enacted" : "not enacted")")
            }
        } catch {
            warning(.storage, "Saving the enacted status failed", error: error)
        }
    }

    private func roundDouble(_ double: Double, _ digits: Double) -> Double {
        let rounded = round(Double(double) * pow(10, digits)) / pow(10, digits)
        return rounded
    }

    // Boost auto-config knobs: the shared BoostAutoConfigKnob enum lives in BoostV5Core (with the
    // per-knob resolution helpers). maxIOB / maxBolus are deliberately NOT managed in Trio: the
    // suggestion merely carries the user's existing values over, so writing them back would be an
    // identity write.

    /// Current value of a double knob in `p` (the Preferences struct always has a value, so
    /// "stored" == current). `fastCarbConfirm` is boolean and never reaches this.
    private static func boostKnobValue(_ knob: BoostAutoConfigKnob, _ p: Preferences) -> Double {
        func dbl(_ d: Decimal) -> Double { Double(truncating: d as NSNumber) }
        switch knob {
        case .aggression: return dbl(p.boostV5Aggression)
        case .hypoCaution: return dbl(p.boostV5HypoCaution)
        case .confirmedCapU: return dbl(p.boostV5ConfirmedCapU)
        case .committedCapU: return dbl(p.boostV5CommittedCapU)
        case .cumulativeSmbCap60Min: return dbl(p.boostCumulativeSmbCap60Min)
        case .boostBolus: return dbl(p.boostBolus)
        case .primerCapU: return dbl(p.boostV5PrimerCapU)
        case .aggressiveEarlyConfirm,
             .fastCarbConfirm,
             .primerTbrFallback,
             .velocityBudgetFloor: return 0 // boolean knobs — handled separately by the caller
        }
    }

    /// "User (or an imported preset) has tuned this knob": the caps use their explicit per-knob
    /// `…UserSet` flags (set only when the user moves the slider) OR the any-era
    /// value-vs-factory test; the remaining knobs use the value test alone. The value test
    /// recognises EVERY factory default the knob has ever shipped with (AAPS fe9d8a1a13 amendment
    /// #1 — Trio's cap defaults changed in 5cf1abb84, so a Preferences JSON persisted before
    /// 2026-06-26 carries 1.0/0.25 that must read as at-factory, not user-tuned).
    private static func boostKnobUserTuned(
        _ knob: BoostAutoConfigKnob,
        _ p: Preferences,
        stock: Preferences
    ) -> Bool {
        switch knob {
        case .fastCarbConfirm:
            return p.boostV5FastCarbConfirm != stock.boostV5FastCarbConfirm
        case .aggressiveEarlyConfirm:
            return p.boostV5AggressiveEarlyConfirm != stock.boostV5AggressiveEarlyConfirm
        case .velocityBudgetFloor:
            return p.boostV5VelocityBudgetActive != stock.boostV5VelocityBudgetActive
        case .primerTbrFallback:
            return p.boostV5PrimerTbrFallback != stock.boostV5PrimerTbrFallback
        case .confirmedCapU where p.boostV5ConfirmedCapUUserSet,
             .committedCapU where p.boostV5CommittedCapUUserSet,
             .cumulativeSmbCap60Min where p.boostCumulativeSmbCap60MinUserSet:
            return true
        default:
            return BoostV5AutoConfigApply.isUserTuned(
                storedValue: boostKnobValue(knob, p),
                factoryDefaults: BoostV5AutoConfigApply.factoryDefaults(
                    knob, currentDefault: boostKnobValue(knob, stock)
                )
            )
        }
    }

    /// The run-now action in Advanced Boost. The same re-derivation as the scheduled one, at least a
    /// day after the last run of either kind: each run moves a setting at most a quarter of the way
    /// and some changes wait for two runs to agree, so repeated presses would otherwise step a cap
    /// up within minutes.
    func runBoostAutoConfigNow(overrideHypoProtections: Bool) async -> [String] {
        guard settingsManager.preferences.boostMode == .active else {
            return ["Auto-config runs only with Boost Active."]
        }
        let onboardingDone = BoostAutoConfigKnob.allCases
            .allSatisfy { settingsManager.preferences.boostV5AutoConfigResolved.contains($0.rawValue) }
        // Before first set-up has resolved every knob, a re-derivation write would read to onboarding
        // as set by the person and freeze it (the same reason the scheduled run waits).
        guard onboardingDone else {
            return ["First set-up has not finished yet. It runs on the loop once Boost is Active and there is enough history."]
        }
        guard BoostRedriveStore.tryBeginRun() else {
            return ["An auto-config run is already in progress."]
        }
        defer { BoostRedriveStore.endRun() }
        if let hours = BoostRedriveStore.hoursSinceLastRun(now: Date()), hours < 24 {
            return [String(
                format: "Auto-config last ran %.0f hours ago. Runs are at least 24 hours apart; the next is possible in %.0f hours.",
                hours, (24 - hours).rounded(.up)
            )]
        }
        return await redriveBoostAutoConfig(overrideHypoProtections: overrideHypoProtections)
    }

    /// Auto-config: when the user runs Boost V5 active, seed the V5 knobs from their own
    /// last-14-day prior (oref) dosing + glycaemia. Suggestion-only: writes a knob ONLY while the
    /// user hasn't tuned it (caps: `…UserSet` flag; others: value differs from EVERY factory
    /// default the knob ever shipped with — old-build users aren't frozen at an old era's value,
    /// AAPS fe9d8a1a13). Dose-cap RAISES are additionally held back (surfaced as suggestions via
    /// the router) when the 14-day TBR<70 exceeds `BoostV5AutoConfigApply.tbrRaiseGuardPct`.
    /// Each knob resolves individually (AAPS b2c0705e5e, see `BoostV5AutoConfigApply`): applied
    /// once, or skipped-because-user-tuned, or held-as-TBR-suggestion, and then never revisited —
    /// the legacy global `boostV5AutoConfigDone` one-shot suppressed knobs ADDED to auto-config
    /// later (and could be carried in via a settings import); a set legacy flag migrates to
    /// per-knob marks (tuned knobs resolved, at-stock knobs re-derivable) and is cleared. A
    /// versioned schema re-migration (AAPS 131923247e) re-audits persisted marks when the
    /// resolution semantics change. If there isn't enough history yet, nothing resolves and every
    /// open knob retries on a later cycle. Fully self-contained — any error is logged and
    /// swallowed, never affecting dosing.
    ///
    /// NOTE: written against verified Trio APIs but NOT yet compiled in Xcode — confirm the field
    /// names `PumpHistoryEvent.timestamp`, `GlucoseStored.glucose`/`.date`, and `pumpSettings.maxBolus`
    /// on first build.
    /// Periodic re-derivation of the derived Boost knobs (AAPS 2026-08-03, second revision).
    ///
    /// Runs off the dose path on a 7-day cadence over a 28-day window. The decision is entirely in
    /// the unit-tested `BoostV5AutoConfigApply.redrive`; this gathers the history, supplies the
    /// baseline and pending ledgers, and writes what it is told to. Every failure is logged and
    /// swallowed.
    ///
    /// Note the window differs from onboarding's 14 days. Two independent 14-day derivations of the
    /// same fortnight differ by 0.69 U [0.30, 1.17] on the confirmed cap, which is noise-dominated
    /// for tracking a drift.
    @discardableResult private func redriveBoostAutoConfig(overrideHypoProtections: Bool = false) async -> [String] {
        BoostRedriveStore.markRun(now: Date())
        do {
            let since = Date().addingTimeInterval(-Double(BoostRedriveStore.windowDays) * 86400)
            let glucoseContext = CoreDataStack.shared.newTaskContext()
            glucoseContext.name = "boostRedriveGlucose"
            let summary: (values: [Int], firstDate: Date)? = try await glucoseContext.perform {
                let glucose = try self.fetchGlucose(
                    on: glucoseContext,
                    predicate: NSPredicate(format: "date >= %@", since as NSDate),
                    // No count limit: a one-minute CGM stores 1,440 readings a day, and a cap kept
                    // only the newest few days, so the history never reached the 7-day minimum.
                    batchSize: 1000
                )
                let values = glucose.compactMap { Int($0.glucose) }.filter { (20 ... 600).contains($0) }
                guard !values.isEmpty else { return nil }
                return (values, glucose.compactMap(\.date).min() ?? since)
            }
            guard let summary else {
                debug(.loop, "BoostV5 re-derivation: no glucose in the window — skipped")
                return ["No glucose in the last \(BoostRedriveStore.windowDays) days, so nothing was changed."]
            }
            let values = summary.values
            let n = values.count
            let tbr70 = 100.0 * Double(values.filter { $0 < 70 }.count) / Double(n)
            let sev54 = 100.0 * Double(values.filter { $0 < 54 }.count) / Double(n)
            let meanBg = Double(values.reduce(0, +)) / Double(n)
            let daysWithData = max(1, Int(Date().timeIntervalSince(summary.firstDate) / 86400))

            let history = (try? await pumpHistoryStorage.getPumpHistory()) ?? []
            let recent = history.filter { $0.timestamp >= since && ($0.type == .bolus || $0.type == .smb) }
            func amt(_ e: PumpHistoryEvent) -> Double? {
                e.amount.map { Double(truncating: $0 as NSNumber) }.flatMap { $0 > 0 ? $0 : nil }
            }
            let smb = recent.filter { $0.isSMB == true || $0.type == .smb }.compactMap(amt)
            let manual = recent.filter { !($0.isSMB == true || $0.type == .smb) }.compactMap(amt)

            var tddMedian = (smb + manual).reduce(0, +) / Double(daysWithData)
            if let pm = pumpManager {
                let windowHistory = history.filter { $0.timestamp >= since }
                let basalProfile = (try? await storage.retrieveAsync(
                    OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self
                )) ?? []
                if let tdd = try? await tddStorage.calculateTDD(
                    pumpManager: pm, pumpHistory: windowHistory, basalProfile: basalProfile
                ) {
                    let daily = Double(truncating: tdd.total as NSNumber) / Double(daysWithData)
                    if (5.0 ... 200.0).contains(daily) { tddMedian = daily }
                }
            }

            let maxBolus = Double(truncating: settingsManager.pumpSettings.maxBolus as NSNumber)
            guard let s = BoostV5AutoConfig.compute(BoostV5AutoConfig.PriorDosing(
                daysWithData: daysWithData, bgReadingCount: n, tddMedianU: tddMedian,
                manualBolusesU: manual, smbAmountsU: smb,
                tbrBelow70Pct: tbr70, timeBelow54Pct: sev54, meanGlucoseMgdl: meanBg,
                currentMaxBolusU: maxBolus
            )) else {
                debug(.loop, "BoostV5 re-derivation: insufficient history (days=\(daysWithData), bg=\(n))")
                return ["Not enough history yet (\(daysWithData) days, \(n) readings), so nothing was changed."]
            }

            // When the override lifts a guard that would otherwise hold, this run's votes go to a
            // separate ledger: a scheduled run must not complete a two-run confirmation with them.
            let separateVotes = BoostRedriveStore.voteLedger(
                overrideLiftsGuard: overrideHypoProtections &&
                    BoostV5AutoConfigApply.raiseGuardTripped(tbrBelow70Pct: tbr70, timeBelow54Pct: sev54)
            )
            var prefs = settingsManager.preferences
            let stock = Preferences()
            let resolutions = BoostV5AutoConfigApply.redrive(
                suggestion: s,
                tbrBelow70Pct: tbr70,
                timeBelow54Pct: sev54,
                overrideHypoProtections: overrideHypoProtections,
                storedValue: { Self.boostKnobValue($0, prefs) },
                currentDefault: { Self.boostKnobValue($0, stock) },
                baselineValue: { BoostRedriveStore.baseline($0) },
                pendingValue: { BoostRedriveStore.pending($0, overridden: separateVotes) },
                put: { knob, value in
                    switch knob {
                    case .aggression: prefs.boostV5Aggression = Decimal(value)
                    case .hypoCaution: prefs.boostV5HypoCaution = Decimal(value)
                    case .confirmedCapU: prefs.boostV5ConfirmedCapU = Decimal(value)
                    case .committedCapU: prefs.boostV5CommittedCapU = Decimal(value)
                    case .cumulativeSmbCap60Min: prefs.boostCumulativeSmbCap60Min = Decimal(value)
                    case .boostBolus: prefs.boostBolus = Decimal(value)
                    case .primerCapU: prefs.boostV5PrimerCapU = Decimal(value)
                    case .aggressiveEarlyConfirm,
                         .fastCarbConfirm,
                         .primerTbrFallback,
                         .velocityBudgetFloor: break // the on/off settings are re-evaluated below
                    }
                },
                setBaseline: { BoostRedriveStore.setBaseline($0, $1) },
                setPending: { BoostRedriveStore.setPending($0, $1, overridden: separateVotes) },
                isUserTuned: { Self.boostKnobUserTuned($0, prefs, stock: stock) },
                lastWritten: { BoostRedriveStore.lastWritten($0) },
                recordWritten: { BoostRedriveStore.recordWritten($0, $1) }
            )
            // Primer delivery route and the two insulin-adding switches, re-evaluated each window
            // (AAPS Boost 6.3.0, audit 16). The derivation's primerTbrFallback is the negation of
            // its well-controlled verdict.
            let route = BoostV5AutoConfigApply.resolvePrimerRoute(
                wellControlled: !s.primerTbrFallback,
                bgReadings: n,
                previousWellControlled: BoostRedriveStore.pendingFlag(BoostV5AutoConfigApply.primerRoutePrevWcKey),
                stored: prefs.boostV5PrimerTbrFallback,
                lastWritten: BoostRedriveStore.lastWrittenBool(.primerTbrFallback),
                put: { prefs.boostV5PrimerTbrFallback = $0 },
                recordWritten: { BoostRedriveStore.recordWrittenBool(.primerTbrFallback, $0) },
                recordWellControlled: { BoostRedriveStore.setPendingFlag(BoostV5AutoConfigApply.primerRoutePrevWcKey, $0) }
            )
            debug(.loop, "BoostV5 re-derivation: primerTbrFallback → \(route.reason)")
            let raiseGuard = BoostV5AutoConfigApply.raiseGuardTripped(
                tbrBelow70Pct: tbr70, timeBelow54Pct: sev54, overridden: overrideHypoProtections
            )
            if overrideHypoProtections {
                debug(.loop, "BoostV5 re-derivation: hypo protections overridden by the person for this run")
            }
            var switchLines: [String] = []
            for (knob, allowsOn) in [
                (BoostAutoConfigKnob.aggressiveEarlyConfirm, s.aggressiveEarlyConfirm),
                (.fastCarbConfirm, s.fastCarbConfirm)
            ] {
                let verdictKey = BoostV5AutoConfigApply.switchPreviousVerdictKey(knob)
                let isAec = knob == .aggressiveEarlyConfirm
                let r = BoostV5AutoConfigApply.resolveInsulinAddingSwitch(
                    allowsOn: allowsOn,
                    raiseGuard: raiseGuard,
                    bgReadings: n,
                    previousAllowsOn: BoostRedriveStore.pendingFlag(verdictKey, overridden: separateVotes),
                    stored: isAec ? prefs.boostV5AggressiveEarlyConfirm : prefs.boostV5FastCarbConfirm,
                    defaultValue: isAec ? stock.boostV5AggressiveEarlyConfirm : stock.boostV5FastCarbConfirm,
                    lastWritten: BoostRedriveStore.lastWrittenBool(knob),
                    userMarked: BoostRedriveStore.lastWritten(knob) == BoostV5AutoConfigApply.switchUserSetMark,
                    put: { if isAec { prefs.boostV5AggressiveEarlyConfirm = $0 } else { prefs.boostV5FastCarbConfirm = $0 } },
                    recordWritten: { BoostRedriveStore.recordWrittenBool(knob, $0) },
                    recordVerdict: { BoostRedriveStore.setPendingFlag(verdictKey, $0, overridden: separateVotes) }
                )
                debug(.loop, "BoostV5 re-derivation: \(knob.rawValue) → \(r.reason)")
                switchLines.append("\(knob.rawValue): \(r.reason)")
            }
            settingsManager.preferences = prefs
            for r in resolutions {
                debug(.loop, "BoostV5 re-derivation: \(r.knob.rawValue) → \(r.reason)")
            }
            let header = String(
                format: "%d days, %d readings. Time below 70: %.1f%%, below 54: %.1f%%.%@",
                daysWithData, n, tbr70, sev54, overrideHypoProtections ? " Hypo protections overridden." : ""
            )
            return [header] + resolutions.map { "\($0.knob.rawValue): \($0.reason)" } +
                ["primerTbrFallback: \(route.reason)"] + switchLines
        } catch {
            debug(.loop, "BoostV5 re-derivation failed (non-fatal): \(error)")
            return ["Auto-config failed: \(error.localizedDescription)"]
        }
    }

    /// Sets the two SMB basal-minutes settings to Boost's starting values the first time Boost is
    /// active, where they are above them (AAPS Boost 6.3.2 `seedSmbMinutes`; see
    /// `BoostV5AutoConfigApply.seedSmbBasalMinutes` for why above rather than unset). Once only:
    /// afterwards they are the person's to change. Whether it has run is bookkeeping, so it
    /// lives in UserDefaults like the other Boost stores.
    private func seedBoostSmbBasalMinutes() {
        var prefs = settingsManager.preferences
        guard prefs.boostMode == .active else { return }
        let seededKey = "boost.smbBasalMinutesSeeded"
        let r = BoostV5AutoConfigApply.seedSmbBasalMinutes(
            smb: Double(truncating: prefs.maxSMBBasalMinutes as NSNumber),
            uam: Double(truncating: prefs.maxUAMSMBBasalMinutes as NSNumber),
            alreadySeeded: UserDefaults.standard.bool(forKey: seededKey)
        )
        UserDefaults.standard.set(true, forKey: seededKey)
        var written: [String] = []
        if let v = r.smb { prefs.maxSMBBasalMinutes = Decimal(v)
            written.append("standard \(Int(v))") }
        if let v = r.uam { prefs.maxUAMSMBBasalMinutes = Decimal(v)
            written.append("UAM \(Int(v))") }
        guard !written.isEmpty else { return }
        settingsManager.preferences = prefs // persists + notifies via SettingsManager.didSet

        let what = written.joined(separator: "; ") + " minutes of basal"
        debug(.loop, "Boost SMB basal minutes set to Boost's starting values: \(what)")
        let content = Alert.Content(
            title: String(localized: "Boost SMB limits"),
            body: "Boost set the largest microbolus to its starting values: \(what). You can change them in the SMB settings.",
            acknowledgeActionButtonLabel: String(localized: "OK")
        )
        trioAlertManager.issueAlert(Alert(
            identifier: Alert.Identifier(
                managerIdentifier: "trio.boost",
                alertIdentifier: "boost.smbBasalMinutesSeed"
            ),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: .active,
            sound: nil
        ))
    }

    /// Writes the result of `DynIsf.reconcileSensitivitySettings` back to preferences (AAPS
    /// `applySensitivitySettingsReconcile`, 3d9d471dbb and f393d02e55). With TDD-based ISF off, BG
    /// impact on ISF is set to 0; when TDD-based ISF is switched on, it is set back to the factory
    /// value once, detected from the state recorded at the previous run. No record only records,
    /// so an upgrade leaves a TDD user's BG impact as it is. The TDD state is bookkeeping rather than
    /// a setting, so it lives in UserDefaults, as the other Boost stores do.
    private func reconcileBoostSensitivitySettings() {
        var prefs = settingsManager.preferences
        guard prefs.boostMode != .off else { return }

        let lastUseTddKey = "boost.lastUseTdd"
        let lastUseTdd = UserDefaults.standard.object(forKey: lastUseTddKey) as? Bool
        let useTdd = prefs.boostUseTdd
        let velocityOnPct = Double(truncating: Preferences().boostDynIsfVelocity as NSNumber)
        let r = DynIsf.reconcileSensitivitySettings(
            useTdd: useTdd,
            velocityPct: Double(truncating: prefs.boostDynIsfVelocity as NSNumber),
            tddJustEnabled: DynIsf.isTddJustEnabled(lastUseTdd: lastUseTdd, useTdd: useTdd),
            velocityOnPct: velocityOnPct
        )
        if lastUseTdd != useTdd { UserDefaults.standard.set(useTdd, forKey: lastUseTddKey) }
        guard r.changed else { return }

        prefs.boostDynIsfVelocity = Decimal(r.velocityPct)
        settingsManager.preferences = prefs // persists + notifies via SettingsManager.didSet

        let what = "BG impact on ISF set to \(Int(r.velocityPct))%"
        let why = r.zeroedVelocity ? "TDD-based ISF is off" : "TDD-based ISF was switched on"
        debug(.loop, "Boost sensitivity settings: \(what) (\(why))")
        let content = Alert.Content(
            title: String(localized: "Boost sensitivity settings"),
            body: "Boost: \(what), because \(why).",
            acknowledgeActionButtonLabel: String(localized: "OK")
        )
        trioAlertManager.issueAlert(Alert(
            identifier: Alert.Identifier(
                managerIdentifier: "trio.boost",
                alertIdentifier: "boost.sensitivitySettings"
            ),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: .active,
            sound: nil
        ))
    }

    private func maybeAutoConfigureBoostV5() async {
        guard settingsManager.preferences.boostMode == .active else { return }

        let stock = Preferences() // factory defaults, for the value-vs-default tuned test

        // Migration from the legacy global one-shot flag: mark resolved ONLY knobs the user (or
        // the old run) moved off their factory default — never rewritten; knobs still AT stock
        // become eligible again (rescues installs where a consumed/imported flag wrongly skipped
        // them). Clearing the flag makes the migration one-shot. (AAPS b2c0705e5e.)
        if settingsManager.preferences.boostV5AutoConfigDone {
            var prefs = settingsManager.preferences
            let migrated = BoostV5AutoConfigApply.migrateLegacyDoneFlag(
                knobs: BoostAutoConfigKnob.allCases,
                isUserTuned: { Self.boostKnobUserTuned($0, prefs, stock: stock) },
                markResolved: { knob in
                    if !prefs.boostV5AutoConfigResolved.contains(knob.rawValue) {
                        prefs.boostV5AutoConfigResolved.append(knob.rawValue)
                    }
                }
            )
            prefs.boostV5AutoConfigDone = false
            settingsManager.preferences = prefs
            debug(
                .loop,
                "BoostV5 auto-config: migrated legacy done-flag → per-knob; resolved=\(migrated.map(\.rawValue))"
            )
        }

        // Versioned re-migration of the persisted resolved marks (idempotent; stamps the schema
        // version; MUST run before the steady-state early-return — a stranded install has every
        // knob resolved). v2 re-opens knobs an era-blind isUserTuned could have mis-resolved at
        // OLD factory values. Mirrors AAPS 131923247e; on Trio no RELEASED build ever persisted
        // era-blind marks (per-knob resolution + historical awareness land together), so this is
        // a scaffold + source-builder rescue — see BoostV5AutoConfigApply.autoConfigSchemaVersion.
        if settingsManager.preferences.boostV5AutoConfigSchemaVersion < BoostV5AutoConfigApply.autoConfigSchemaVersion {
            var prefs = settingsManager.preferences
            let reopened = BoostV5AutoConfigApply.runSchemaMigrations(
                storedVersion: prefs.boostV5AutoConfigSchemaVersion,
                knobs: BoostAutoConfigKnob.doubleKnobs,
                isResolved: { prefs.boostV5AutoConfigResolved.contains($0.rawValue) },
                isUserTuned: { Self.boostKnobUserTuned($0, prefs, stock: stock) },
                clearResolved: { knob in prefs.boostV5AutoConfigResolved.removeAll { $0 == knob.rawValue } },
                setVersion: { prefs.boostV5AutoConfigSchemaVersion = $0 }
            )
            settingsManager.preferences = prefs
            for knob in reopened {
                debug(
                    .loop,
                    "BoostV5 auto-config re-migration v2: \(knob.rawValue) value " +
                        "\(Self.boostKnobValue(knob, prefs)) matches historical factory — re-opened for derivation"
                )
            }
        }

        // Steady state: everything resolved → nothing to do (cheap check, no data pulls).
        let resolvedNow = settingsManager.preferences.boostV5AutoConfigResolved
        guard !BoostAutoConfigKnob.allCases.allSatisfy({ resolvedNow.contains($0.rawValue) }) else { return }
        do {
            let since = Date().addingTimeInterval(-14 * 86400)

            // Glycaemia (last 14 days). dev's `fetchGlucose` is synchronous and context-bound, so
            // both the fetch and every read of the returned managed objects happen inside the
            // context's `perform` block; only plain values cross back out.
            let glucoseContext = CoreDataStack.shared.newTaskContext()
            glucoseContext.name = "boostAutoConfigGlucose"
            let summary: (values: [Int], firstDate: Date)? = try await glucoseContext.perform {
                let glucose = try self.fetchGlucose(
                    on: glucoseContext,
                    predicate: NSPredicate(format: "date >= %@", since as NSDate),
                    // No count limit: a one-minute CGM stores 1,440 readings a day, and a cap kept
                    // only the newest few days, so the history never reached the 7-day minimum.
                    batchSize: 1000
                )
                let values = glucose.compactMap { Int($0.glucose) }.filter { (20 ... 600).contains($0) }
                guard !values.isEmpty else { return nil }
                return (values, glucose.compactMap(\.date).min() ?? since)
            }
            guard let summary else { return }
            let values = summary.values
            let n = values.count
            let tbr70 = 100.0 * Double(values.filter { $0 < 70 }.count) / Double(n)
            let sev54 = 100.0 * Double(values.filter { $0 < 54 }.count) / Double(n)
            let meanBg = Double(values.reduce(0, +)) / Double(n)
            let daysWithData = max(1, Int(Date().timeIntervalSince(summary.firstDate) / 86400))

            // Boluses (last 14 days), split into SMB vs manual.
            let history = (try? await pumpHistoryStorage.getPumpHistory()) ?? []
            let recent = history.filter { ($0.timestamp) >= since && ($0.type == .bolus || $0.type == .smb) }
            func amt(_ e: PumpHistoryEvent) -> Double? { e.amount.map { Double(truncating: $0 as NSNumber) }
                .flatMap { $0 > 0 ? $0 : nil } }
            let smb = recent.filter { $0.isSMB == true || $0.type == .smb }.compactMap(amt)
            let manual = recent.filter { !($0.isSMB == true || $0.type == .smb) }.compactMap(amt)

            // True daily TDD (basal + bolus) via TDDStorage over the 14-day history, with a sanity
            // guard; falls back to the conservative bolus-only estimate if unavailable/implausible.
            var tddMedian = (smb + manual).reduce(0, +) / Double(daysWithData) // fallback: bolus-only
            if let pm = pumpManager {
                let history14d = history.filter { $0.timestamp >= since }
                let basalProfile = (try? await storage.retrieveAsync(
                    OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self
                )) ?? []
                if let tdd = try? await tddStorage.calculateTDD(
                    pumpManager: pm, pumpHistory: history14d, basalProfile: basalProfile
                ) {
                    let daily = Double(truncating: tdd.total as NSNumber) / Double(daysWithData)
                    if (5.0 ... 200.0).contains(daily) { tddMedian = daily }
                }
            }

            let maxBolus = Double(truncating: settingsManager.pumpSettings.maxBolus as NSNumber)

            guard let s = BoostV5AutoConfig.compute(BoostV5AutoConfig.PriorDosing(
                daysWithData: daysWithData, bgReadingCount: n, tddMedianU: tddMedian,
                manualBolusesU: manual, smbAmountsU: smb,
                tbrBelow70Pct: tbr70, timeBelow54Pct: sev54, meanGlucoseMgdl: meanBg,
                currentMaxBolusU: maxBolus
            )) else {
                // Nothing resolves here: every open knob stays eligible and genuinely retries next cycle.
                debug(.loop, "BoostV5 auto-config: insufficient history (days=\(daysWithData), bg=\(n)) — will retry")
                return
            }

            // Per-knob suggestion-only seeding (AAPS b2c0705e5e + fe9d8a1a13, via
            // BoostV5AutoConfigApply): each open knob is applied unless the user tuned it (caps:
            // explicit `…UserSet` flag OR value off EVERY-era factory; others: value off factory
            // default); dose-cap RAISES are held back (suggestion-only) when TBR<70 exceeds the
            // guard threshold; the cumulative cap is recomputed inside from the final operative
            // per-shot caps. Either way each knob resolves exactly once and is never revisited.
            // Tuning one knob never blocks the others.
            var prefs = settingsManager.preferences
            func resolved(_ k: BoostAutoConfigKnob) -> Bool { prefs.boostV5AutoConfigResolved.contains(k.rawValue) }
            func markResolved(_ k: BoostAutoConfigKnob) {
                if !resolved(k) { prefs.boostV5AutoConfigResolved.append(k.rawValue) }
            }
            let resolutions = BoostV5AutoConfigApply.applyAutoConfig(
                suggestion: s,
                tbrBelow70Pct: tbr70,
                timeBelow54Pct: sev54,
                isResolved: resolved,
                storedValue: { Self.boostKnobValue($0, prefs) },
                currentDefault: { Self.boostKnobValue($0, stock) },
                isUserTuned: { Self.boostKnobUserTuned($0, prefs, stock: stock) },
                put: { knob, value in
                    switch knob {
                    case .aggression: prefs.boostV5Aggression = Decimal(value)
                    case .hypoCaution: prefs.boostV5HypoCaution = Decimal(value)
                    case .confirmedCapU: prefs.boostV5ConfirmedCapU = Decimal(value)
                    case .committedCapU: prefs.boostV5CommittedCapU = Decimal(value)
                    case .cumulativeSmbCap60Min: prefs.boostCumulativeSmbCap60Min = Decimal(value)
                    case .boostBolus: prefs.boostBolus = Decimal(value)
                    case .primerCapU: prefs.boostV5PrimerCapU = Decimal(value)
                    case .aggressiveEarlyConfirm,
                         .fastCarbConfirm,
                         .primerTbrFallback,
                         .velocityBudgetFloor: break // boolean knobs handled below
                    }
                },
                markResolved: markResolved,
                recordWritten: { BoostRedriveStore.recordWritten($0, $1) }
            )
            // Boolean knob (mirrors the Kotlin plugin): apply only while still at the factory
            // default, then resolve either way.
            var fastCarbApplied: String?
            if !resolved(.fastCarbConfirm) {
                if prefs.boostV5FastCarbConfirm != stock.boostV5FastCarbConfirm {
                    // Off its default before onboarding: the user's, so re-derivation never changes it.
                    BoostRedriveStore.recordWritten(.fastCarbConfirm, BoostV5AutoConfigApply.switchUserSetMark)
                }
                if prefs.boostV5FastCarbConfirm == stock.boostV5FastCarbConfirm {
                    prefs.boostV5FastCarbConfirm = s.fastCarbConfirm
                    BoostRedriveStore.recordWrittenBool(.fastCarbConfirm, s.fastCarbConfirm)
                    if s.fastCarbConfirm != stock.boostV5FastCarbConfirm {
                        fastCarbApplied = "fastCarbConfirm=\(s.fastCarbConfirm)"
                    }
                }
                markResolved(.fastCarbConfirm)
            }
            // 2026-07-17 (AAPS 3ea7479572): the two insulin-adding switches follow the same
            // once-only boolean resolution, applied while the preference still sits at its factory
            // default and marked resolved either way. They derive from the strict well-controlled
            // cut rather than the hypo-prone one, so a user the data does not clear gets neither.
            var booleanApplied: [String] = fastCarbApplied.map { [$0] } ?? []
            if !resolved(.aggressiveEarlyConfirm) {
                if prefs.boostV5AggressiveEarlyConfirm != stock.boostV5AggressiveEarlyConfirm {
                    BoostRedriveStore.recordWritten(.aggressiveEarlyConfirm, BoostV5AutoConfigApply.switchUserSetMark)
                }
                if prefs.boostV5AggressiveEarlyConfirm == stock.boostV5AggressiveEarlyConfirm {
                    prefs.boostV5AggressiveEarlyConfirm = s.aggressiveEarlyConfirm
                    BoostRedriveStore.recordWrittenBool(.aggressiveEarlyConfirm, s.aggressiveEarlyConfirm)
                    if s.aggressiveEarlyConfirm != stock.boostV5AggressiveEarlyConfirm {
                        booleanApplied.append("aggressiveEarlyConfirm=\(s.aggressiveEarlyConfirm)")
                    }
                }
                markResolved(.aggressiveEarlyConfirm)
            }
            if !resolved(.velocityBudgetFloor) {
                if prefs.boostV5VelocityBudgetActive == stock.boostV5VelocityBudgetActive {
                    prefs.boostV5VelocityBudgetActive = s.velocityBudgetFloor
                    BoostRedriveStore.recordWrittenBool(.velocityBudgetFloor, s.velocityBudgetFloor)
                    if s.velocityBudgetFloor != stock.boostV5VelocityBudgetActive {
                        booleanApplied.append("velocityBudgetFloor=\(s.velocityBudgetFloor)")
                    }
                }
                markResolved(.velocityBudgetFloor)
            }
            if !resolved(.primerTbrFallback) {
                if prefs.boostV5PrimerTbrFallback == stock.boostV5PrimerTbrFallback {
                    prefs.boostV5PrimerTbrFallback = s.primerTbrFallback
                    BoostRedriveStore.recordWrittenBool(.primerTbrFallback, s.primerTbrFallback)
                    if s.primerTbrFallback != stock.boostV5PrimerTbrFallback {
                        booleanApplied.append("primerTbrFallback=\(s.primerTbrFallback)")
                    }
                }
                markResolved(.primerTbrFallback)
            }
            settingsManager.preferences = prefs // persists + notifies via SettingsManager.didSet

            // Log every classification verbatim so field diagnosis never needs inference
            // (AAPS fe9d8a1a13).
            for r in resolutions {
                debug(.loop, "BoostV5 auto-config: \(r.knob.rawValue) → \(r.reason)")
            }
            let applied = resolutions.filter { $0.outcome == .applied }
                .map { "\($0.knob.rawValue)=\($0.suggestedValue)" } + booleanApplied
            debug(.loop, "BoostV5 auto-config applied \(applied) from \(daysWithData)d history: \(s.rationale)")

            // Surface a user notification only when something actually changed or a cap raise was
            // held back as a suggestion (AAPS fe9d8a1a13 — TBR raise-guard; Trio idiom:
            // router.alertMessage). Announcing "configured" while changing nothing would be the
            // confusing behaviour the AAPS banner logic avoids.
            let heldSuggestions = resolutions.filter { $0.outcome == .suggestedNotAppliedTbr }
                .map { r -> String in
                    // Name whichever guard(s) actually tripped (<70 raise-guard and/or the
                    // 2026-07-07 <54 severe co-guard) so the user sees why the raise was held.
                    var why: [String] = []
                    if tbr70 > BoostV5AutoConfigApply.tbrRaiseGuardPct {
                        why.append("time-below-70 is \((tbr70 * 10).rounded() / 10)%")
                    }
                    if sev54 >= BoostV5AutoConfigApply.tbr54RaiseGuardPct {
                        why.append("time-below-54 is \((sev54 * 10).rounded() / 10)%")
                    }
                    return "\(r.knob.rawValue): suggested \(r.suggestedValue) U from your history — not auto-applied " +
                        "because \(why.joined(separator: " and ")); set manually if desired"
                }
            if !applied.isEmpty || !heldSuggestions.isEmpty {
                let pretty = (applied + heldSuggestions).map { "• \($0)" }.joined(separator: "\n")
                // dev removed the lightweight `router.alertMessage`/`MessageContent`
                // banner system; surface this the same way dev migrated those info
                // banners — a one-shot info Alert through TrioAlertManager.
                let content = Alert.Content(
                    title: String(localized: "Boost V6 auto-config"),
                    body: "Boost V6 set \(applied.count) setting(s) from your last 14 days " +
                        "(your other settings were kept):\n\(pretty)",
                    acknowledgeActionButtonLabel: String(localized: "OK")
                )
                let alert = Alert(
                    identifier: Alert.Identifier(
                        managerIdentifier: "trio.boost",
                        alertIdentifier: "boost.autoconfig"
                    ),
                    foregroundContent: content,
                    backgroundContent: content,
                    trigger: .immediate,
                    interruptionLevel: .active,
                    sound: nil
                )
                trioAlertManager.issueAlert(alert)
            }
        } catch {
            debug(.loop, "BoostV5 auto-config failed (non-fatal): \(error)")
        }
    }

    /// Synchronously fetches glucose on the given context. Must be called from within a `perform`/`performAndWait` block of that context
    private func fetchGlucose(
        on context: NSManagedObjectContext,
        predicate: NSPredicate,
        fetchLimit: Int? = nil,
        batchSize: Int? = nil
    ) throws -> [GlucoseStored] {
        let results = try CoreDataStack.shared.fetchEntities(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: predicate,
            key: "date",
            ascending: false,
            fetchLimit: fetchLimit,
            batchSize: batchSize
        )
        guard let glucoseResults = results as? [GlucoseStored] else {
            throw CoreDataError.fetchError(function: #function, file: #file)
        }
        return glucoseResults
    }

    private func loopStats(loopStatRecord: LoopStats) {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "loopStats.save"
        context.perform {
            let nLS = LoopStatRecord(context: context)
            nLS.start = loopStatRecord.start
            nLS.end = loopStatRecord.end ?? Date()
            nLS.loopStatus = loopStatRecord.loopStatus
            nLS.duration = loopStatRecord.duration ?? 0.0
            nLS.interval = loopStatRecord.interval ?? 0.0

            do {
                guard context.hasChanges else { return }
                try context.save()
            } catch {
                warning(.storage, "Saving loop statistics failed", error: error)
            }
        }
    }

    private var transientCategoryFirstSeen: [String: Date] = [:]
    private var transientCategoryCount: [String: Int] = [:]
    private static let transientDwellThreshold: TimeInterval = 60
    private static let transientCountThreshold = 2

    /// Set by `markNextLoopUserInitiated()` (e.g. force-loop button), consumed
    /// on the next entry into `loop()` so that errors during a user-initiated
    /// loop surface immediately instead of being suppressed by dwell logic.
    @SyncAccess private var nextLoopUserInitiated: Bool = false
    private var currentLoopUserInitiated: Bool = false

    func markNextLoopUserInitiated() {
        nextLoopUserInitiated = true
    }

    private func processError(_ error: Error) {
        lastError.send(error)
        surfaceErrorIfNeeded(error)
    }

    private func surfaceErrorIfNeeded(_ error: Error) {
        let category = TrioAlertClassifier.categorize(error: error)
        let key = String(describing: category)

        if category.shouldFireImmediately || currentLoopUserInitiated {
            transientCategoryFirstSeen.removeValue(forKey: key)
            transientCategoryCount.removeValue(forKey: key)
            issueAlertForError(error, category: category)
            return
        }

        let now = Date()
        let firstSeen = transientCategoryFirstSeen[key] ?? now
        let count = (transientCategoryCount[key] ?? 0) + 1
        let dwellElapsed = now.timeIntervalSince(firstSeen)
        let dwellMet = dwellElapsed >= Self.transientDwellThreshold
        let countMet = count >= Self.transientCountThreshold

        if dwellMet || countMet {
            transientCategoryFirstSeen.removeValue(forKey: key)
            transientCategoryCount.removeValue(forKey: key)
            issueAlertForError(error, category: category)
        } else {
            transientCategoryFirstSeen[key] = firstSeen
            transientCategoryCount[key] = count
            debug(
                .alerts,
                "Alert for transient \(category) held back: \(count) of \(Self.transientCountThreshold) occurrences, \(Int(dwellElapsed)) of \(Int(Self.transientDwellThreshold)) s"
            )
        }
    }

    private func issueAlertForCategory(_ category: TrioAlertCategory, title: String, body: String) {
        let content = Alert.Content(
            title: title,
            body: body,
            acknowledgeActionButtonLabel: String(localized: "OK")
        )
        let alert = Alert(
            identifier: Alert.Identifier(managerIdentifier: "trio.aps", alertIdentifier: category.alertIdentifier),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: category.interruptionLevel
        )
        trioAlertManager?.issueAlert(alert)
    }

    private func issueAlertForError(_ error: Error, category: TrioAlertCategory) {
        let (title, body) = describeForAlert(error)
        let content = Alert.Content(
            title: title,
            body: body,
            acknowledgeActionButtonLabel: "OK"
        )
        let alert = Alert(
            identifier: Alert.Identifier(managerIdentifier: "trio.aps", alertIdentifier: category.alertIdentifier),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: category.interruptionLevel
        )
        trioAlertManager?.issueAlert(alert)
    }

    private func describeForAlert(_ error: Error) -> (title: String, body: String) {
        if let apsError = error as? APSError {
            switch apsError {
            case let .pumpError(inner):
                return (
                    String(localized: "Pump Error"),
                    String(localized: "Trio could not communicate with the pump. Check the pump and try again.")
                        + "\n\n\(inner.localizedDescription)"
                )
            case let .invalidPumpState(message): return (String(localized: "Pump State Error"), message)
            case let .glucoseError(message): return (String(localized: "Glucose Error"), message)
            case let .apsError(message): return (String(localized: "Algorithm Error"), message)
            case let .manualBasalTemp(message): return (String(localized: "Manual Temp Basal Active"), message)
            }
        }
        return ("Trio", error.localizedDescription)
    }

    /// Called from the `bolusTrigger` Combine sink (already on
    /// `processQueue`) and from `doseProgressReporterDidUpdate` (the
    /// pump manager schedules the callback on `processQueue` too).
    /// Mutations are dispatched onto the queue regardless, so a future
    /// caller from another context (e.g. `cancelBolus`) stays safe.
    private func createBolusReporter() {
        if bolusReporter != nil {
            return
        }

        processQueue.async {
            self.bolusReporter = self.pumpManager?.createBolusProgressReporter(reportingOn: self.processQueue)
            self.bolusReporter?.addObserver(self)
        }
    }

    private func clearBolusReporter() {
        processQueue.async {
            self.bolusReporter?.removeObserver(self)
            self.bolusReporter = nil
            self.bolusProgress.send(nil)
        }
    }
}

private extension PumpManager {
    func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.enactTempBasal(decisionId: nil, unitsPerHour: unitsPerHour, for: duration) { error in
                if let error = error {
                    debug(.pump, "Temp basal command failed: \(unitsPerHour) U/h for \(Int(duration / 60)) min")
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func enactBolus(units: Double, automatic: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let automaticValue = automatic ? BolusActivationType.automatic : BolusActivationType.manualRecommendationAccepted

            self.enactBolus(decisionId: nil, units: units, activationType: automaticValue) { error in
                if let error = error {
                    debug(.pump, "Bolus command failed: \(units) U")
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func cancelBolus() async throws -> DoseEntry? {
        try await withCheckedThrowingContinuation { continuation in
            self.cancelBolus { result in
                switch result {
                case let .success(dose):
                    continuation.resume(returning: dose)
                case let .failure(error):
                    continuation.resume(throwing: APSError.pumpError(error))
                }
            }
        }
    }
}

extension BaseAPSManager: SettingsObserver {
    func settingsDidChange(_ settings: TrioSettings) {
        let previous = lastDosingMode
        lastDosingMode = settings.dosingMode

        // Only basal testing clears a running temp. Elsewhere it may be protecting against a low,
        // and dropping back to scheduled basal would remove that protection.
        guard settings.dosingMode == .basalTesting, previous != .basalTesting else { return }

        Task { await cancelAutomaticTempBasal() }
    }

    /// Clears a Trio-set temp so a basal test starts from the scheduled rate.
    private func cancelAutomaticTempBasal() async {
        guard let pump = pumpManager else { return }

        // A temp the user set on the pump is theirs to cancel.
        guard !isManualTempBasal else { return }
        guard case let .tempBasal(dose) = pump.status.basalDeliveryState, dose.automatic ?? true else { return }

        do {
            try await pump.enactTempBasal(unitsPerHour: 0, for: 0)
            info(.pump, "Temp basal cancelled for basal testing")
        } catch {
            warning(.pump, "Cancelling temp basal for basal testing failed", error: error)
            processError(APSError.pumpError(error))
        }
    }
}

extension BaseAPSManager: DoseProgressObserver {
    func doseProgressReporterDidUpdate(_ doseProgressReporter: DoseProgressReporter) {
        bolusProgress.send(Decimal(doseProgressReporter.progress.percentComplete))
        if doseProgressReporter.progress.isComplete {
            clearBolusReporter()
        }
    }
}

extension PumpManagerStatus {
    var pumpStatus: PumpStatus {
        let bolusing = bolusState != .noBolus
        // A halted patch or faulted pod reports .pumpInoperable; never loop against it.
        let suspended = basalDeliveryState.map { $0.isSuspended || $0 == .pumpInoperable } ?? true
        let type = suspended ? StatusType.suspended : (bolusing ? .bolusing : .normal)
        return PumpStatus(status: type, bolusing: bolusing, suspended: suspended, timestamp: Date())
    }
}
