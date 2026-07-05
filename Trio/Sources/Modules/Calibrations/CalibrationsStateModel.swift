import Observation
import SwiftDate
import SwiftUI

extension Calibrations {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!
        @ObservationIgnored @Injected() var calibrationService: CalibrationService!

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
                    info(.service, "Glucose is stale for calibration")
                    return
                }
            } catch {
                debug(.default, "\(DebuggingIdentifiers.failed) Failed to add calibration: \(error)")
            }
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
