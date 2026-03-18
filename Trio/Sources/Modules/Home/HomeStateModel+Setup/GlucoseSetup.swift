import CoreData
import Foundation

extension Home.StateModel {
    @MainActor func setupGlucoseController() {
        glucoseControllerDelegate.onContentChange = { [weak self] in
            Task { @MainActor in
                self?.updateGlucoseFromController()
            }
        }

        do {
            try glucoseController.performFetch()
            updateGlucoseFromController()
        } catch {
            debug(.default, "\(DebuggingIdentifiers.failed) Failed to perform glucose fetch: \(error)")
        }
    }

    @MainActor func updateGlucoseFromController() {
        guard let objects = glucoseController.fetchedObjects else { return }

        glucoseFromPersistence = objects
        latestTwoGlucoseValues = Array(objects.suffix(2))
        updateGlucoseChartYAxis(glucoseValues: objects)
    }

    @MainActor private func updateGlucoseChartYAxis(glucoseValues: [GlucoseStored]) {
        let glucoseMapped = glucoseValues.map { Decimal($0.glucose) }
        let forecastValues = preprocessedData.map { Decimal($0.forecastValue.value) }

        guard let minGlucose = glucoseMapped.min(), let maxGlucose = glucoseMapped.max() else {
            minYAxisValue = 39
            maxYAxisValue = 200
            return
        }

        let minForecast = forecastValues.min()
        let maxForecast = forecastValues.max()

        let adjustedMaxForecast = min(maxForecast ?? maxGlucose + 50, maxGlucose + 50)
        let minOverall = min(minGlucose, minForecast ?? minGlucose)
        let maxOverall = max(maxGlucose, adjustedMaxForecast)

        var maxYValue: Decimal = 200
        if maxOverall > 200, maxOverall <= 225 {
            maxYValue = 250
        } else if maxOverall > 225, maxOverall <= 275 {
            maxYValue = 300
        } else if maxOverall > 275, maxOverall <= 325 {
            maxYValue = 350
        } else if maxOverall > 325 {
            maxYValue = 400
        }

        minYAxisValue = minOverall
        maxYAxisValue = maxYValue
    }

    // Called from MainChartView .onChange(of: units)
    func setupGlucoseArray() {
        guard let objects = glucoseController.fetchedObjects else { return }
        Task { @MainActor in
            self.updateGlucoseChartYAxis(glucoseValues: objects)
        }
    }
}
