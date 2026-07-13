import LoopKit
import Observation
import SwiftDate
import SwiftUI

extension Calibrations {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!
        @ObservationIgnored @Injected() var calibrationService: CalibrationService!
        @ObservationIgnored @Injected() var trioAlertManager: TrioAlertManager!

        var slope: Double = 1
        var intercept: Double = 1
        var newCalibration: Decimal = 0
        var calibrations: [Calibration] = []
        var calibrate: (Int) -> Double = { Double($0) }
        var items: [Item] = []

        var units: GlucoseUnits = .mgdL

        override func subscribe() {
            units = settingsManager.settings.units
            calibrate = calibrationService.calibrate
            setupCalibrations()
        }

        private func setupCalibrations() {
            slope = calibrationService.slope
            intercept = calibrationService.intercept
            calibrations = calibrationService.calibrations
            items = calibrations.map {
                Item(calibration: $0)
            }
        }

        @MainActor func addCalibration() async {
            do {
                defer {
                    UIApplication.shared.endEditing()
                    setupCalibrations()
                }

                var glucose = newCalibration
                if units == .mmolL {
                    glucose = newCalibration.asMgdL
                }

                // Fetch the single most-recent non-stale reading from GRDB (within 20 minutes)
                let records = try await GlucoseStore.fetch(from: Date.twentyMinutesAgo, ascending: false, limit: 1)

                if let lastGlucose = records.first {
                    let unfiltered = lastGlucose.glucose
                    let calibration = Calibration(x: Double(unfiltered), y: Double(glucose))

                    calibrationService.addCalibration(calibration)
                } else {
                    debug(.service, "Glucose is stale for calibration")
                    issueStaleGlucoseAlert()
                    return
                }
            } catch {
                debug(.default, "\(DebuggingIdentifiers.failed) Failed to add calibration: \(error)")
            }
        }

        /// Surfaces the "glucose too stale to calibrate against" condition as
        /// a one-shot info alert through `TrioAlertManager`. Mirrors the old
        /// `info(.service, …)` banner path that ran via `router.alertMessage`.
        private func issueStaleGlucoseAlert() {
            let content = Alert.Content(
                title: String(localized: "Calibration unavailable"),
                body: String(localized: "Glucose is stale for calibration"),
                acknowledgeActionButtonLabel: String(localized: "OK")
            )
            let alert = Alert(
                identifier: Alert.Identifier(
                    managerIdentifier: "trio.calibration",
                    alertIdentifier: "glucose.stale"
                ),
                foregroundContent: content,
                backgroundContent: content,
                trigger: .immediate,
                interruptionLevel: .active,
                sound: nil
            )
            trioAlertManager?.issueAlert(alert)
        }

        func removeLast() {
            calibrationService.removeLast()
            setupCalibrations()
        }

        func removeAll() {
            calibrationService.removeAllCalibrations()
            setupCalibrations()
        }

        func removeAtIndex(_ index: Int) {
            let calibration = calibrations[index]
            calibrationService.removeCalibration(calibration)
            setupCalibrations()
        }
    }
}
