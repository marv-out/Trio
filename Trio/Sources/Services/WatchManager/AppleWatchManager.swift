import Combine
import CoreData
import Foundation
import Swinject
import UIKit
import WatchConnectivity

/// Protocol defining the base functionality for Watch communication
protocol WatchManager {
    func setupWatchState() async -> WatchState
}

/// Main implementation of the Watch communication manager
/// Handles bidirectional communication between iPhone and Apple Watch
final class BaseWatchManager: NSObject, WCSessionDelegate, Injectable, WatchManager {
    private var session: WCSession?

    @Injected() var broadcaster: Broadcaster!
    @Injected() private var apsManager: APSManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var fileStorage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var determinationStorage: DeterminationStorage!
    @Injected() private var overrideStorage: OverrideStorage!
    @Injected() private var tempTargetStorage: TempTargetsStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var bolusCalculationManager: BolusCalculationManager!
    @Injected() private var iobService: IOBService!
    @Injected() private var notificationsManager: UserNotificationsManager!

    private var units: GlucoseUnits = .mgdL
    private var glucoseColorScheme: GlucoseColorScheme = .staticColor
    private var lowGlucose: Decimal = 70.0
    private var highGlucose: Decimal = 180.0
    private var currentGlucoseTarget: Decimal = 100.0
    private var activeBolusAmount: Double = 0.0

    private var subscriptions = Set<AnyCancellable>()

    typealias PumpEvent = PumpEventStored.EventType

    let viewContext = CoreDataStack.shared.persistentContainer.viewContext

    init(resolver: Resolver) {
        super.init()
        injectServices(resolver)
        setupWatchSession()

        units = settingsManager.settings.units
        glucoseColorScheme = settingsManager.settings.glucoseColorScheme
        lowGlucose = settingsManager.settings.low
        highGlucose = settingsManager.settings.high
        Task {
            currentGlucoseTarget = await getCurrentGlucoseTarget() ?? Decimal(100)
        }
        broadcaster.register(SettingsObserver.self, observer: self)
        broadcaster.register(PumpSettingsObserver.self, observer: self)

        // Observer for glucose and manual glucose (fires on every glucose store/delete)
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Skip if no watch is paired or app not installed
                guard let session = self.session, session.isPaired, session.isReachable,
                      session.isWatchAppInstalled else { return }
                Task {
                    let state = await self.setupWatchState()
                    await self.sendDataToWatch(state)
                }
            }
            .store(in: &subscriptions)

        iobService.iobPublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task {
                    let state = await self.setupWatchState()
                    await self.sendDataToWatch(state)
                }
            }
            .store(in: &subscriptions)

        registerHandlers()
    }

    private func registerHandlers() {
        // GRDB observation replaces the Core Data `filteredByEntityName("OrefDetermination")` sink.
        OrefDeterminationStore.observeLatest()
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] _ in
                    guard let self = self else { return }
                    // Skip if no watch is paired or app not installed
                    guard let session = self.session, session.isPaired, session.isReachable,
                          session.isWatchAppInstalled else { return }
                    Task {
                        let state = await self.setupWatchState()
                        await self.sendDataToWatch(state)
                    }
                }
            )
            .store(in: &subscriptions)

        // Glucose store/delete now fire `glucoseStorage.updatePublisher` (subscribed above), so the
        // former Core Data `filteredByEntityName("GlucoseStored")` deletion sink is redundant and gone.

        // Pump events moved to GRDB; observe the latest non-external bolus instead of the Core Data
        // save notification.
        PumpEventStore.observeLastBolus()
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                guard let self = self else { return }
                Task {
                    await self.getActiveBolusAmount()
                }
            }).store(in: &subscriptions)

        // Overrides moved to GRDB; observe the store instead of the Core Data save notification.
        OverrideStore.observeLatest()
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                guard let self = self else { return }
                // Skip if no watch is paired or app not installed
                guard let session = self.session, session.isPaired, session.isReachable, session.isWatchAppInstalled
                else { return }
                Task {
                    let state = await self.setupWatchState()
                    await self.sendDataToWatch(state)
                }
            }).store(in: &subscriptions)

        // Temp targets moved to GRDB; observe the store instead of the Core Data save notification.
        TempTargetStore.observeLatest()
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                guard let self = self else { return }
                // Skip if no watch is paired or app not installed
                guard let session = self.session, session.isPaired, session.isReachable, session.isWatchAppInstalled
                else { return }
                Task {
                    let state = await self.setupWatchState()
                    await self.sendDataToWatch(state)
                }
            }).store(in: &subscriptions)
    }

    /// Sets up the WatchConnectivity session if the device supports it
    private func setupWatchSession() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session

            debug(.watchManager, "📱 Phone session setup - isPaired: \(session.isPaired)")
        } else {
            debug(.watchManager, "📱 WCSession is not supported on this device")
        }
    }

    /// Attempts to reestablish the Watch connection if it becomes unreachable
    private func retryConnection() {
        guard let session = session else { return }

        if !session.isReachable {
            debug(.watchManager, "📱 Attempting to reactivate session...")
            session.activate()
        }
    }

    /// Prepares the current state data to be sent to the Watch
    /// - Returns: WatchState containing current glucose readings and trends and determination infos for displaying cob and iob in the view
    func setupWatchState() async -> WatchState {
        // Check if a watch is paired and reachable before doing expensive calculations
        guard let session = session, session.isPaired, session.isReachable, session.isWatchAppInstalled else {
            debug(.watchManager, "⌚️❌ Skipping setupWatchState - No Watch is paired or app not installed")
            return WatchState(date: Date())
        }

        // Skip if watch session is not activated
        guard session.activationState == .activated else {
            debug(.watchManager, "⌚️❌ Skipping setupWatchState - Watch session not activated")
            return WatchState(date: Date())
        }
        do {
            // Glucose + determination + override + temp target are all GRDB value types now — no
            // NSManagedObjectID round-trip and no Core Data context / perform block.
            let glucoseObjects = try await fetchGlucose()
            let latestDetermination = try await determinationStorage.fetchLastDetermination(
                within: 30,
                enactedOnly: false
            )
            let overridePresets = try await overrideStorage.fetchForOverridePresets()
            let tempTargetPresets = try await tempTargetStorage.fetchForTempTargetPresets()

            var watchState = WatchState(date: Date())

            // Set lastLoopDate
            let lastLoopMinutes = Int((Date().timeIntervalSince(apsManager.lastLoopDate) - 30) / 60) + 1
            if lastLoopMinutes > 1440 {
                watchState.lastLoopTime = "--"
            } else {
                watchState.lastLoopTime = "\(lastLoopMinutes) min"
            }

            // Set IOB and COB from latest determination
            let iob = iobService.currentIOB ?? 0
            watchState.iob = Formatter.decimalFormatterWithTwoFractionDigits.string(from: iob as NSNumber)

            if let latestDetermination {
                let cob = NSNumber(value: latestDetermination.cob)
                watchState.cob = Formatter.integerFormatter.string(from: cob)
            }

            // Set override presets with their enabled status
            watchState.overridePresets = overridePresets.map { override in
                OverridePresetWatch(
                    name: override.name ?? "",
                    isEnabled: override.enabled
                )
            }

            guard let latestGlucose = glucoseObjects.first else {
                return watchState
            }

            // Assign currentGlucose and its color
            /// Set current glucose with proper formatting
            if units == .mgdL {
                watchState.currentGlucose = "\(latestGlucose.glucose)"
            } else {
                let mgdlValue = Decimal(latestGlucose.glucose)
                let latestGlucoseValue = mgdlValue.formattedAsMmolL
                watchState.currentGlucose = "\(latestGlucoseValue)"
            }

            /// Calculate latest color
            let hardCodedLow = Decimal(55)
            let hardCodedHigh = Decimal(220)
            let isDynamicColorScheme = glucoseColorScheme == .dynamicColor

            let highGlucoseValue = isDynamicColorScheme ? hardCodedHigh : highGlucose
            let lowGlucoseValue = isDynamicColorScheme ? hardCodedLow : lowGlucose
            let highGlucoseColorValue = highGlucoseValue
            let lowGlucoseColorValue = lowGlucoseValue
            let targetGlucose = currentGlucoseTarget

            let currentGlucoseColor = Trio.getDynamicGlucoseColor(
                glucoseValue: Decimal(latestGlucose.glucose),
                highGlucoseColorValue: highGlucoseColorValue,
                lowGlucoseColorValue: lowGlucoseColorValue,
                targetGlucose: targetGlucose,
                glucoseColorScheme: glucoseColorScheme
            )

            if Decimal(latestGlucose.glucose) <= lowGlucose || Decimal(latestGlucose.glucose) >= highGlucose {
                watchState.currentGlucoseColorString = currentGlucoseColor.toHexString()
            } else {
                watchState.currentGlucoseColorString = "#ffffff" // white when in range; colored when out of range
            }

            // Map glucose values
            watchState.glucoseValues = glucoseObjects.compactMap { glucose in
                let glucoseValue = self.units == .mgdL
                    ? Double(glucose.glucose)
                    : Double(truncating: Decimal(glucose.glucose).asMmolL as NSNumber)

                let glucoseColor = Trio.getDynamicGlucoseColor(
                    glucoseValue: Decimal(glucose.glucose),
                    highGlucoseColorValue: highGlucoseColorValue,
                    lowGlucoseColorValue: lowGlucoseColorValue,
                    targetGlucose: targetGlucose,
                    glucoseColorScheme: self.glucoseColorScheme
                )

                return WatchGlucoseObject(
                    date: glucose.date ?? Date(),
                    glucose: glucoseValue,
                    color: glucoseColor.toHexString()
                )
            }
            .sorted { $0.date < $1.date }

            // Set axis domain: min and max Y-axis values
            // Apply unit parsing conditionally, if user uses mmol/L
            let maxGlucoseValue = Decimal(glucoseObjects.map { Int($0.glucose) }.max() ?? 200)
            var maxYValue = Decimal(200)

            if maxGlucoseValue > maxYValue, maxGlucoseValue <= 225 {
                maxYValue = Decimal(250)
            } else if maxGlucoseValue > 225, maxGlucoseValue <= 275 {
                maxYValue = Decimal(300)
            } else if maxGlucoseValue > 275, maxGlucoseValue <= 325 {
                maxYValue = Decimal(350)
            } else if maxGlucoseValue > 325 {
                maxYValue = Decimal(400)
            }

            if units == .mmolL {
                maxYValue = Double(truncating: maxYValue as NSNumber).asMmolL
            }
            watchState.maxYAxisValue = maxYValue

            if units == .mmolL {
                let minYValue = Double(truncating: watchState.minYAxisValue as NSNumber).asMmolL
                watchState.minYAxisValue = minYValue
            }

            // Convert direction to trend string
            watchState.trend = latestGlucose.direction

            // Calculate delta if we have at least 2 readings
            if glucoseObjects.count >= 2 {
                var glucoseLast = Decimal(glucoseObjects[0].glucose)
                var glucoseSecondLast = Decimal(glucoseObjects[1].glucose)
                if units == .mmolL {
                    glucoseLast = glucoseLast.asMmolL
                    glucoseSecondLast = glucoseSecondLast.asMmolL
                }

                let deltaValue = glucoseLast - glucoseSecondLast
                let formattedDelta = Formatter.glucoseFormatter(for: units)
                    .string(from: deltaValue as NSNumber) ?? "0"
                watchState.delta = deltaValue < 0 ? "\(formattedDelta)" : "+\(formattedDelta)"
            }

            // Set temp target presets with their enabled status
            watchState.tempTargetPresets = tempTargetPresets.map { tempTarget in
                TempTargetPresetWatch(
                    name: tempTarget.name ?? "",
                    isEnabled: tempTarget.enabled
                )
            }

            // Set units
            watchState.units = units

            // Add limits and pump specific dosing increment settings values
            watchState.maxBolus = settingsManager.pumpSettings.maxBolus
            watchState.maxCarbs = settingsManager.settings.maxCarbs
            watchState.maxFat = settingsManager.settings.maxFat
            watchState.maxProtein = settingsManager.settings.maxProtein
            watchState.bolusIncrement = settingsManager.preferences.bolusIncrement
            watchState.confirmBolusFaster = settingsManager.settings.confirmBolusFaster

            debug(
                .watchManager,

                "📱 Setup WatchState - currentGlucose: \(watchState.currentGlucose ?? "nil"), trend: \(watchState.trend ?? "nil"), delta: \(watchState.delta ?? "nil"), values: \(watchState.glucoseValues.count)"
            )

            return watchState
        } catch {
            debug(
                .watchManager,
                "\(DebuggingIdentifiers.failed) Error setting up watch state: \(error)"
            )
            // Return empty state in case of error
            return WatchState(date: Date())
        }
    }

    /// Fetches recent glucose readings from GRDB (newest first, last 24h, capped at 288).
    /// - Returns: Array of `GlucoseRecord` value types
    private func fetchGlucose() async throws -> [GlucoseRecord] {
        try await GlucoseStore.fetch(from: Date.oneDayAgo, ascending: false, limit: 288)
    }

    /// Gets the active bolus amount by fetching the last (active) non-external bolus from GRDB. The
    /// store applies the 20-minute + non-external filter (formerly `NSPredicate.lastPumpBolus`).
    @MainActor func getActiveBolusAmount() async {
        do {
            if let details = try await PumpEventStore.fetchLastBolus() {
                activeBolusAmount = details.bolus?.amount.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0.0
            }
        } catch {
            debug(
                .default,
                "\(DebuggingIdentifiers.failed) Error getting active bolus amount: \(error)"
            )
        }
    }

    // MARK: - Send to Watch

    func watchStateToDictionary(from state: WatchState) -> [String: Any] {
        [
            WatchMessageKeys.date: state.date.timeIntervalSince1970,
            WatchMessageKeys.currentGlucose: state.currentGlucose ?? "--",
            WatchMessageKeys.currentGlucoseColorString: state.currentGlucoseColorString ?? "#ffffff",
            WatchMessageKeys.trend: state.trend ?? "",
            WatchMessageKeys.delta: state.delta ?? "",
            WatchMessageKeys.iob: state.iob ?? "",
            WatchMessageKeys.cob: state.cob ?? "",
            WatchMessageKeys.lastLoopTime: state.lastLoopTime ?? "",
            WatchMessageKeys.glucoseValues: state.glucoseValues.map { value in
                [
                    "glucose": value.glucose,
                    "date": value.date.timeIntervalSince1970,
                    "color": value.color
                ]
            },
            WatchMessageKeys.minYAxisValue: state.minYAxisValue,
            WatchMessageKeys.maxYAxisValue: state.maxYAxisValue,
            WatchMessageKeys.overridePresets: state.overridePresets.map { preset in
                [
                    "name": preset.name,
                    "isEnabled": preset.isEnabled
                ]
            },
            WatchMessageKeys.tempTargetPresets: state.tempTargetPresets.map { preset in
                [
                    "name": preset.name,
                    "isEnabled": preset.isEnabled
                ]
            },
            WatchMessageKeys.maxBolus: state.maxBolus,
            WatchMessageKeys.maxCarbs: state.maxCarbs,
            WatchMessageKeys.maxFat: state.maxFat,
            WatchMessageKeys.maxProtein: state.maxProtein,
            WatchMessageKeys.bolusIncrement: state.bolusIncrement,
            WatchMessageKeys.confirmBolusFaster: state.confirmBolusFaster,
            WatchMessageKeys.units: state.units.rawValue
        ]
    }

    /// Sends the state of type WatchState to the connected Watch
    /// - Parameter state: Current WatchState containing glucose data to be sent
    @MainActor func sendDataToWatch(_ state: WatchState) async {
        guard let session = session else { return }

        guard session.isPaired else {
            debug(.watchManager, "⌚️❌ No Watch is paired")
            return
        }

        guard session.isWatchAppInstalled else {
            debug(.watchManager, "⌚️❌ Trio Watch app is")
            return
        }

        guard session.activationState == .activated else {
            let activationStateString = "\(session.activationState)"
            debug(.watchManager, "⌚️ Watch session activationState = \(activationStateString). Reactivating...")
            session.activate()
            return
        }

        // Stamp the snapshot with send time. Each push gets a strictly newer
        // `date` than the previous one, which is what the watch's monotonicity
        // dedup relies on — including watch-requested re-pushes when no CGM
        // tick has bumped the build-time date.
        var state = state
        state.date = Date()

        let message: [String: Any] = watchStateToDictionary(from: state)

        // if session is reachable, it means watch App is in the foreground -> send watchState as message
        // if session is not reachable, it means it's in background -> send watchState as userInfo
        if session.isReachable {
            session.sendMessage([WatchMessageKeys.watchState: message], replyHandler: nil) { error in
                debug(.watchManager, "❌ Error sending watch state: \(error)")
            }
        } else {
            session.transferUserInfo([WatchMessageKeys.watchState: message])
            debug(.watchManager, "📤 Transferred new WatchState snapshot via userInfo")
        }
        WatchStateSnapshot.saveLatestDateToDisk(state.date)
    }

    func sendAcknowledgment(toWatch success: Bool, message: String = "", ackCode: AcknowledgmentCode) {
        guard let session = session, session.isReachable else {
            debug(.watchManager, "⌚️ Watch not reachable for acknowledgment")
            return
        }

        let ackMessage: [String: Any] = [
            WatchMessageKeys.acknowledged: success,
            WatchMessageKeys.message: message,
            WatchMessageKeys.ackCode: ackCode.rawValue
        ]

        session.sendMessage(ackMessage, replyHandler: nil) { error in
            debug(.watchManager, "❌ Error sending acknowledgment: \(error)")
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            debug(.watchManager, "📱 Phone session activation failed: \(error)")
            return
        }

        debug(.watchManager, "📱 Phone session activated with state: \(activationState.rawValue)")
        debug(.watchManager, "📱 Phone isReachable after activation: \(session.isReachable)")

        // Try to send initial data after activation
        Task {
            let state = await self.setupWatchState()
            await self.sendDataToWatch(state)
        }
    }

    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        // Handle logs first - doesn't need self, so it can run even during teardown
        if let logs = message["watchLogs"] as? String {
            SimpleLogReporter.appendToWatchLog(logs)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            if let requestWatchUpdate = message[WatchMessageKeys.requestWatchUpdate] as? String,
               requestWatchUpdate == WatchMessageKeys.watchState
            {
                debug(.watchManager, "📱 Watch requested watch state data update.")
                // Skip if no watch is paired or app not installed
                guard let session = self.session, session.isPaired, session.isReachable,
                      session.isWatchAppInstalled else { return }
                Task {
                    let state = await self.setupWatchState()
                    await self.sendDataToWatch(state)
                }
                return
            }

            if let snoozeMinutes = message[WatchMessageKeys.snoozeDuration] as? Int {
                debug(.watchManager, "📱 Received snooze request from watch: \(snoozeMinutes) minutes")
                await self.notificationsManager.applySnooze(for: TimeInterval(snoozeMinutes * 60))
                return
            } else if let bolusAmount = message[WatchMessageKeys.bolus] as? Double,
                      message[WatchMessageKeys.carbs] == nil,
                      message[WatchMessageKeys.date] == nil
            {
                debug(.watchManager, "📱 Received bolus request from watch: \(bolusAmount)U")
                self.handleBolusRequest(Decimal(bolusAmount))
            } else if let carbsAmount = message[WatchMessageKeys.carbs] as? Int,
                      let timestamp = message[WatchMessageKeys.date] as? TimeInterval,
                      message[WatchMessageKeys.bolus] == nil
            {
                let date = Date(timeIntervalSince1970: timestamp)
                debug(.watchManager, "📱 Received carbs request from watch: \(carbsAmount)g at \(date)")
                self.handleCarbsRequest(carbsAmount, date)
            } else if let bolusAmount = message[WatchMessageKeys.bolus] as? Double,
                      let carbsAmount = message[WatchMessageKeys.carbs] as? Int,
                      let timestamp = message[WatchMessageKeys.date] as? TimeInterval
            {
                let date = Date(timeIntervalSince1970: timestamp)
                debug(
                    .watchManager,
                    "📱 Received meal bolus combo request from watch: \(bolusAmount)U, \(carbsAmount)g at \(date)"
                )
                self.handleCombinedRequest(bolusAmount: Decimal(bolusAmount), carbsAmount: Decimal(carbsAmount), date: date)
            } else {
                debug(.watchManager, "📱 Invalid or incomplete data received from watch. Received:  \(message)")
                // Acknowledge failure
                self.sendAcknowledgment(
                    toWatch: false,
                    message: "Error! Invalid or incomplete data received from watch.",
                    ackCode: .genericFailure
                )
            }

            if message[WatchMessageKeys.cancelOverride] as? Bool == true {
                debug(.watchManager, "📱 Received cancel override request from watch")
                self.handleCancelOverride()
            }

            if let presetName = message[WatchMessageKeys.activateOverride] as? String {
                debug(.watchManager, "📱 Received activate override request from watch for preset: \(presetName)")
                self.handleActivateOverride(presetName)
            }

            if let presetName = message[WatchMessageKeys.activateTempTarget] as? String {
                debug(.watchManager, "📱 Received activate temp target request from watch for preset: \(presetName)")
                self.handleActivateTempTarget(presetName)
            }

            if message[WatchMessageKeys.cancelTempTarget] as? Bool == true {
                debug(.watchManager, "📱 Received cancel temp target request from watch")
                self.handleCancelTempTarget()
            }

            if message[WatchMessageKeys.requestBolusRecommendation] as? Bool == true {
                let carbs = message[WatchMessageKeys.carbs] as? Int ?? 0

                var minPredBG: Decimal = 54

                Task { [weak self] in
                    guard let self = self else { return }

                    do {
                        // Fetch determination data (GRDB value type)
                        let determination = try await determinationStorage.fetchLastDetermination(
                            within: 30,
                            enactedOnly: false
                        )

                        await MainActor.run {
                            minPredBG = determination?.minPredBGFromReason ?? 54
                        }

                    } catch let error as CoreDataError {
                        debug(.default, "Core Data error: \(error)")
                    } catch {
                        debug(.default, "Unexpected error: \(error)")
                    }

                    // Get recommendation from BolusCalculationManager
                    let result = await bolusCalculationManager.handleBolusCalculation(
                        carbs: Decimal(carbs),
                        useFattyMealCorrection: false,
                        useSuperBolus: false,
                        lastLoopDate: apsManager.lastLoopDate,
                        minPredBG: minPredBG,
                        simulatedCOB: nil,
                        isBackdated: false // we cannot backdate carbs via watch
                    )

                    // Send recommendation back to watch
                    let recommendationMessage: [String: Any] = [
                        WatchMessageKeys.recommendedBolus: NSDecimalNumber(decimal: result.insulinCalculated)
                    ]

                    if let session = self.session, session.isReachable {
                        debug(.watchManager, "📱 Sending recommendedBolus: \(result.insulinCalculated)")
                        session.sendMessage(recommendationMessage, replyHandler: nil)
                    }
                }
                return
            }
        }
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let logs = userInfo["watchLogs"] as? String {
            SimpleLogReporter.appendToWatchLog(logs)
        }

        if let snoozeMinutes = userInfo[WatchMessageKeys.snoozeDuration] as? Int {
            debug(.watchManager, "📱 Received snooze userInfo from watch: \(snoozeMinutes) minutes")
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.notificationsManager.applySnooze(for: TimeInterval(snoozeMinutes * 60))
            }
        }
    }

    #if os(iOS)
        func sessionDidBecomeInactive(_: WCSession) {}
        func sessionDidDeactivate(_ session: WCSession) {
            session.activate()
        }
    #endif

    func sessionReachabilityDidChange(_ session: WCSession) {
        debug(.watchManager, "📱 Phone reachability changed: \(session.isReachable)")

        if session.isReachable {
            // Try to send data when connection is established
            Task {
                let state = await self.setupWatchState()
                await self.sendDataToWatch(state)
            }
        } else {
            // Try to reconnect after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.retryConnection()
            }
        }
    }

    /// Processes bolus requests received from the Watch
    /// - Parameter amount: The requested bolus amount in units
    private func handleBolusRequest(_ amount: Decimal) {
        Task {
            await apsManager.enactBolus(amount: Double(amount), isSMB: false) { success, message in
                // Acknowledge success or error of bolus
                self.sendAcknowledgment(
                    toWatch: success,
                    message: message,
                    ackCode: success == true ? .genericSuccess : .genericFailure
                )
            }
            debug(.watchManager, "📱 Enacted bolus via APS Manager: \(amount)U")
        }
    }

    /// Handles carbs entry requests received from the Watch
    /// - Parameters:
    ///   - amount: The carbs amount in grams
    ///   - date: Timestamp for the carbs entry
    private func handleCarbsRequest(_ amount: Int, _ date: Date) {
        Task {
            do {
                let entry = CarbsEntry(
                    id: UUID().uuidString,
                    createdAt: date,
                    actualDate: nil,
                    carbs: Decimal(amount),
                    fat: nil,
                    protein: nil,
                    note: String(localized: "Via Watch", comment: "Note added to carb entry when entered via watch"),
                    enteredBy: CarbsEntry.local,
                    isFPU: false,
                    fpuID: nil
                )
                try await carbsStorage.storeCarbs([entry], areFetchedFromRemote: false)
                debug(.watchManager, "📱 Saved carbs from watch: \(amount)g at \(date)")

                // Acknowledge success
                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Carbs logged successfully.",
                        comment: "Success message sent to watch when carbs are logged successfully"
                    ),
                    ackCode: .carbsLogged
                )
            } catch {
                debug(.watchManager, "❌ Error saving carbs: \(error)")

                // Acknowledge failure
                self.sendAcknowledgment(toWatch: false, message: "Error logging carbs", ackCode: .genericFailure)
            }
        }
    }

    /// Handles combined bolus and carbs entry requests received from the Watch.
    /// - Parameters:
    ///   - bolusAmount: The bolus amount in units
    ///   - carbsAmount: The carbs amount in grams
    ///   - date: Timestamp for the carbs entry
    private func handleCombinedRequest(bolusAmount: Decimal, carbsAmount: Decimal, date: Date) {
        Task {
            do {
                // Notify Watch: "Saving carbs..."
                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Saving Carbs...",
                        comment: "Successful message sent to watch when saving carbs"
                    ),
                    ackCode: .savingCarbs
                )

                // Save carbs entry via GRDB
                let carbEntry = CarbsEntry(
                    id: UUID().uuidString,
                    createdAt: date,
                    actualDate: nil,
                    carbs: carbsAmount,
                    fat: nil,
                    protein: nil,
                    note: String(localized: "Via Watch", comment: "Note added to carb entry when entered via watch"),
                    enteredBy: CarbsEntry.local,
                    isFPU: false,
                    fpuID: nil
                )
                try await carbsStorage.storeCarbs([carbEntry], areFetchedFromRemote: false)
                debug(.watchManager, "📱 Saved carbs from watch: \(carbsAmount) g at \(date)")

                // Notify Watch: "Enacting bolus..."
                sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Enacting bolus...",
                        comment: "Successful message sent to watch when enacting bolus"
                    ),
                    ackCode: .enactingBolus
                )

                // Enact bolus via APS Manager
                let bolusDouble = NSDecimalNumber(decimal: bolusAmount).doubleValue
                await apsManager.enactBolus(amount: bolusDouble, isSMB: false) { success, message in
                    // Acknowledge success or error of bolus
                    self.sendAcknowledgment(
                        toWatch: success,
                        message: message,
                        ackCode: success == true ? .genericSuccess : .genericFailure
                    )
                }
                debug(.watchManager, "📱 Enacted bolus from watch via APS Manager: \(bolusDouble) U")
                // Notify Watch: "Carbs and bolus logged successfully"
                sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Carbs and Bolus logged successfully.",
                        comment: "Successful message sent to watch when logging carbs and bolus"
                    ),
                    ackCode: .comboComplete
                )

            } catch {
                debug(.watchManager, "❌ Error processing combined request: \(error)")
                sendAcknowledgment(toWatch: false, message: "Failed to log carbs and bolus", ackCode: .genericFailure)
            }
        }
    }

    private func handleCancelOverride() {
        Task {
            do {
                // Overrides live in GRDB; disable the active one (no run logged, matching the
                // prior watch behavior) and notify the Adjustments UI.
                guard let active = try await overrideStorage.fetchLatestActiveOverride(), let pk = active.pk else {
                    debug(.watchManager, "❌ No active override found.")
                    self.sendAcknowledgment(
                        toWatch: false,
                        message: "No active override found.",
                        ackCode: .genericFailure
                    )
                    return
                }

                try await OverrideStore.disable(pks: [pk])
                debug(.watchManager, "📱 Successfully stopped override")

                Foundation.NotificationCenter.default.post(name: .didUpdateOverrideConfiguration, object: nil)
                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Stopped Override successfully.",
                        comment: "Stopped Override successfully"
                    ),
                    ackCode: .overrideStopped
                )
            } catch {
                debug(.watchManager, "❌ Error cancelling override: \(error)")
                self.sendAcknowledgment(toWatch: false, message: "Error stopping Override.", ackCode: .genericFailure)
            }
        }
    }

    private func handleActivateOverride(_ presetName: String) {
        Task {
            do {
                debug(.watchManager, "📱 Fetching all override presets...")
                let presets = try await overrideStorage.fetchForOverridePresets()

                debug(.watchManager, "📱 Checking for active override...")
                // Deactivate any currently active override first (no run logged).
                if let active = try await overrideStorage.fetchLatestActiveOverride(), let activePk = active.pk {
                    try await OverrideStore.disable(pks: [activePk])
                } else {
                    debug(.watchManager, "📱 Currently no override is active... proceeding to activate override: \(presetName)")
                }

                guard let presetToActivate = presets
                    .first(where: { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) == presetName }),
                    let pk = presetToActivate.pk
                else {
                    debug(.watchManager, "❌ No matching preset found for name: \"\(presetName)\" in \(presets.map(\.name))")
                    self.sendAcknowledgment(
                        toWatch: false,
                        message: String(
                            localized: "Preset \"\(presetName)\" not found.",
                            comment: "Preset not found"
                        ),
                        ackCode: .genericFailure
                    )
                    return
                }

                try await overrideStorage.enactOverride(pk: pk)
                debug(.watchManager, "📱 Successfully activated override: \(presetName)")

                Foundation.NotificationCenter.default.post(name: .didUpdateOverrideConfiguration, object: nil)
                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Started Override \"\(presetName)\" successfully.",
                        comment: "Start override with override name"
                    ),
                    ackCode: .overrideStarted
                )
            } catch {
                debug(.watchManager, "❌ Error activating override: \(error)")
                self.sendAcknowledgment(
                    toWatch: false,
                    message: "Error activating Override \"\(presetName)\".",
                    ackCode: .genericFailure
                )
            }
        }
    }

    private func handleActivateTempTarget(_ presetName: String) {
        Task {
            do {
                // Temp targets live in GRDB; fetch the presets as value types.
                let presets = try await tempTargetStorage.fetchForTempTargetPresets()

                // Deactivate any currently active temp target first (no run logged, matching watch behavior).
                if let active = try await tempTargetStorage.fetchLatestActiveTempTarget(), let activePk = active.pk {
                    try await TempTargetStore.disable(pks: [activePk])
                }

                guard let presetToActivate = presets.first(where: { $0.name == presetName }), let pk = presetToActivate.pk
                else {
                    self.sendAcknowledgment(
                        toWatch: false,
                        message: "Error! Something went wrong when processing your request.",
                        ackCode: .genericFailure
                    )
                    return
                }

                try await tempTargetStorage.enactTempTarget(pk: pk)
                debug(.watchManager, "📱 Successfully activated temp target: \(presetName)")

                let settingsHalfBasalTarget = self.settingsManager.preferences.halfBasalExerciseTarget

                // To activate the temp target also in oref
                let tempTarget = TempTarget(
                    name: presetToActivate.name,
                    createdAt: Date(),
                    targetTop: presetToActivate.target,
                    targetBottom: presetToActivate.target,
                    duration: presetToActivate.duration ?? 0,
                    enteredBy: TempTarget.local,
                    reason: TempTarget.custom,
                    isPreset: true,
                    enabled: true,
                    halfBasalTarget: presetToActivate.halfBasalTarget ?? settingsHalfBasalTarget
                )

                self.tempTargetStorage.saveTempTargetsToStorage([tempTarget])

                // Send notification to update Adjustments UI
                Foundation.NotificationCenter.default.post(name: .didUpdateTempTargetConfiguration, object: nil)

                // Acknowledge activation success
                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Started Temp Target \"\(presetName)\" successfully.",
                        comment: "Started Temp Target successfully."
                    ),
                    ackCode: .tempTargetStarted
                )
            } catch {
                debug(.watchManager, "❌ Error activating temp target: \(error)")
                self.sendAcknowledgment(
                    toWatch: false,
                    message: "Error activating Temp Target \"\(presetName)\".",
                    ackCode: .genericFailure
                )
            }
        }
    }

    private func handleCancelTempTarget() {
        Task {
            do {
                guard let active = try await tempTargetStorage.fetchLatestActiveTempTarget(), let pk = active.pk else {
                    debug(.watchManager, "❌ No active temp target found.")
                    self.sendAcknowledgment(toWatch: false, message: "No active temp target found.", ackCode: .genericFailure)
                    return
                }

                try await TempTargetStore.disable(pks: [pk])
                debug(.watchManager, "📱 Successfully cancelled temp target")

                // To cancel the temp target also for oref
                self.tempTargetStorage.saveTempTargetsToStorage([TempTarget.cancel(at: Date())])

                // Send notification to update Adjustments UI
                Foundation.NotificationCenter.default.post(name: .didUpdateTempTargetConfiguration, object: nil)

                // Acknowledge cancellation success
                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Stopped Temp Target successfully.",
                        comment: "Stopped Temp Target successfully."
                    ),
                    ackCode: .tempTargetStopped
                )
            } catch {
                debug(.watchManager, "❌ Error stopping temp target: \(error)")
                self.sendAcknowledgment(toWatch: false, message: "Error stopping Temp Target.", ackCode: .genericFailure)
            }
        }
    }
}

// TODO: - is there a better approach than setting up the watch state every time a setting has changed?
extension BaseWatchManager: SettingsObserver, PumpSettingsObserver {
    // to update maxBolus
    func pumpSettingsDidChange(_: PumpSettings) {
        // Skip if no watch is paired or app not installed
        guard let session = self.session, session.isPaired, session.isReachable, session.isWatchAppInstalled else { return }
        Task {
            let state = await self.setupWatchState()
            await self.sendDataToWatch(state)
        }
    }

    // to update the rest
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
        glucoseColorScheme = settingsManager.settings.glucoseColorScheme
        lowGlucose = settingsManager.settings.low
        highGlucose = settingsManager.settings.high

        // Skip if no watch is paired or app not installed
        guard let session = self.session, session.isPaired, session.isReachable, session.isWatchAppInstalled else { return }

        Task {
            let state = await self.setupWatchState()
            await self.sendDataToWatch(state)
        }
    }
}

extension BaseWatchManager {
    /// Retrieves the current glucose target based on the time of day.
    private func getCurrentGlucoseTarget() async -> Decimal? {
        let now = Date()
        let calendar = Calendar.current

        let bgTargets = await fileStorage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self)
            ?? BGTargets(from: OpenAPS.defaults(for: OpenAPS.Settings.bgTargets))
            ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
        let entries: [(start: String, value: Decimal)] = bgTargets.targets.map { ($0.start, $0.low) }

        for (index, entry) in entries.enumerated() {
            guard let entryTime = TherapySettingsUtil.parseTime(entry.start) else {
                debug(.default, "Invalid entry start time: \(entry.start)")
                continue
            }

            let entryComponents = calendar.dateComponents([.hour, .minute, .second], from: entryTime)
            let entryStartTime = calendar.date(
                bySettingHour: entryComponents.hour!,
                minute: entryComponents.minute!,
                second: entryComponents.second!,
                of: now
            )!

            let entryEndTime: Date
            if index < entries.count - 1,
               let nextEntryTime = TherapySettingsUtil.parseTime(entries[index + 1].start)
            {
                let nextEntryComponents = calendar.dateComponents([.hour, .minute, .second], from: nextEntryTime)
                entryEndTime = calendar.date(
                    bySettingHour: nextEntryComponents.hour!,
                    minute: nextEntryComponents.minute!,
                    second: nextEntryComponents.second!,
                    of: now
                )!
            } else {
                entryEndTime = calendar.date(byAdding: .day, value: 1, to: entryStartTime)!
            }

            if now >= entryStartTime, now < entryEndTime {
                return entry.value
            }
        }

        return nil
    }
}

extension BaseWatchManager {
    enum AcknowledgmentCode: String, Codable {
        case savingCarbs = "saving_carbs"
        case enactingBolus = "enacting_bolus"
        case comboComplete = "combo_complete"
        case carbsLogged = "carbs_logged"
        case overrideStarted = "override_started"
        case overrideStopped = "override_stopped"
        case tempTargetStarted = "temp_target_started"
        case tempTargetStopped = "temp_target_stopped"
        case genericSuccess = "success"
        case genericFailure = "failure"
    }
}
