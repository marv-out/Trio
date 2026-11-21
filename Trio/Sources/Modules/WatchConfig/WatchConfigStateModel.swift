import Combine
import ConnectIQ
import HealthKit
import LoopKit
import SwiftUI

extension WatchConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var garmin: GarminManager!
        @Injected() private var fetchGlucoseManager: FetchGlucoseManager!
        @Injected() private var watchActivityStorage: WatchActivityStorage!

        @Published var units: GlucoseUnits = .mgdL
        @Published var devices: [IQDevice] = []
        @Published var confirmBolusFaster = false
        @Published var showForecastWatch = false
        @Published var useCriticalAlertsWatch = false
        /// The CGM can pass its configuration to the watch, which then reads it itself.
        @Published var cgmSharesWithWatch = false
        @Published var cgmName = ""
        @Published var watchReadsSensor = false
        @Published var watchActivityEnabled = false
        @Published var watchActivityPreciseMode = false

        /// Latest values received directly from the Apple Watch (not via HealthKit)
        @Published var latestHeartRate: WatchHeartRateSample?
        /// nil when the step data is outdated or has gaps
        @Published var recentSteps: WatchRecentSteps?
        @Published var watchStatus: WatchActivityStatus?
        @Published var stepsToday: Int = 0
        @Published var lastStepUpdate: Date?
        @Published var liveSessionStartError: String?

        private lazy var healthStore = HKHealthStore()
        /// nil until the first value; the subscription also delivers the stored value when the screen opens
        private var lastWatchActivityEnabled: Bool?
        private var lastWatchActivityPreciseMode: Bool?

        /// Garmin watch settings containing all watch-related configuration
        @Published var garminSettings = GarminWatchSettings()

        private(set) var preferences = Preferences()

        override func subscribe() {
            preferences = provider.preferences
            units = settingsManager.settings.units

            // Subscribe to the entire garminSettings struct from TrioSettings
            subscribeSetting(\.garminSettings, on: $garminSettings) { garminSettings = $0 }
            subscribeSetting(\.confirmBolusFaster, on: $confirmBolusFaster) { confirmBolusFaster = $0 }
            subscribeSetting(\.showForecastWatch, on: $showForecastWatch) { showForecastWatch = $0 }
            subscribeSetting(\.useCriticalAlertsWatch, on: $useCriticalAlertsWatch) { useCriticalAlertsWatch = $0 }
            subscribeSetting(\.watchActivityEnabled, on: $watchActivityEnabled) { watchActivityEnabled = $0 } didSet: {
                [weak self] enabled in
                guard let self else { return }
                let previous = self.lastWatchActivityEnabled
                self.lastWatchActivityEnabled = enabled
                // React only to a real change by the user
                guard let previous, previous != enabled else { return }
                if enabled {
                    // Without precise mode the watch sends on the sensor's wakes; nothing to start
                    if self.watchActivityPreciseMode { self.startLiveSessionOnWatch() }
                } else {
                    // Turning the feature off deletes what the watch sent
                    self.watchActivityStorage.removeAll()
                }
            }

            subscribeSetting(\.watchActivityPreciseMode, on: $watchActivityPreciseMode) { watchActivityPreciseMode = $0 } didSet: {
                [weak self] precise in
                guard let self else { return }
                let previous = self.lastWatchActivityPreciseMode
                self.lastWatchActivityPreciseMode = precise
                guard let previous, previous != precise else { return }
                // Turning it off reaches the watch with the next watch state, which ends the session there
                if precise, self.watchActivityEnabled { self.startLiveSessionOnWatch() }
            }

            watchActivityStorage.updatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.refreshWatchActivity() }
                .store(in: &lifetime)
            refreshWatchActivity()

            devices = garmin.devices
            refreshWatchSensor()
        }

        /// The CGM manager's own Read on Apple Watch is the source; this only shows it.
        func refreshWatchSensor() {
            let cgm = fetchGlucoseManager.cgmManager
            cgmSharesWithWatch = cgm is DeviceConfigurationSharing
            cgmName = cgm?.localizedTitle ?? ""
            watchReadsSensor = (cgm as? DeviceConfigurationSharing)?.isConfigurationSharingEnabled ?? false
        }

        func refreshWatchActivity() {
            let now = Date()
            latestHeartRate = watchActivityStorage.latestHeartRate()
            recentSteps = watchActivityStorage.recentSteps(now: now, maxAge: BaseWatchActivityStorage.maxAge)
            stepsToday = watchActivityStorage.stepCount(since: Calendar.current.startOfDay(for: now))
            lastStepUpdate = watchActivityStorage.lastStepUpdate()
            watchStatus = watchActivityStorage.latestStatus()
        }

        /// Data older than 5 minutes is shown as outdated.
        func isOutdated(_ date: Date?, now: Date = Date()) -> Bool {
            guard let date else { return true }
            return now.timeIntervalSince(date) > BaseWatchActivityStorage.maxAge
        }

        /// Opens the Trio watch app and starts the live (workout) session there. watchOS does not let the
        /// watch app start it from the background, so this is the way to (re)start it without touching the watch.
        func startLiveSessionOnWatch() {
            guard HKHealthStore.isHealthDataAvailable() else { return }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other
            configuration.locationType = .unknown
            healthStore.startWatchApp(with: configuration) { [weak self] success, error in
                DispatchQueue.main.async {
                    if let error {
                        warning(.watch, "Starting the live session on the watch failed", error: error)
                        self?.liveSessionStartError = error.localizedDescription
                    } else {
                        info(.watch, "Live session on the watch requested: \(success)")
                        self?.liveSessionStartError = nil
                    }
                }
            }
        }

        /// Prompts the user to select Garmin devices and updates the device list
        func selectGarminDevices() {
            garmin.selectDevices()
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.devices, on: self)
                .store(in: &lifetime)
        }

        /// Updates the Garmin manager with the current device list
        func deleteGarminDevice() {
            garmin.updateDeviceList(devices)
        }

        /// Handles watchface selection changes by automatically disabling data transmission
        /// to allow the user to switch watchfaces on their Garmin device without data conflicts
        func handleWatchfaceChange() {
            garminSettings.isWatchfaceDataEnabled = false
        }

        /// Resumes data transmission after user confirms they have switched watchface on their device
        func resumeDataTransmission() {
            garminSettings.isWatchfaceDataEnabled = true
        }
    }
}

extension WatchConfig.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
