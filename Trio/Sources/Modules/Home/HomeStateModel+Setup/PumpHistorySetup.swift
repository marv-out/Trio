import CoreData
import Foundation

extension Home.StateModel {
    // MARK: - Insulin / Pump History

    @MainActor func setupInsulinController() {
        insulinControllerDelegate.onContentChange = { [weak self] in
            Task { @MainActor in
                self?.updateInsulinFromController()
                self?.displayPumpStatusHighlightMessage()
                self?.displayPumpStatusBadge()
            }
        }

        do {
            try insulinController.performFetch()
            updateInsulinFromController()
        } catch {
            debug(.default, "\(DebuggingIdentifiers.failed) Failed to perform insulin fetch: \(error)")
        }
    }

    @MainActor private func updateInsulinFromController() {
        guard let objects = insulinController.fetchedObjects else { return }
        insulinFromPersistence = objects
        manualTempBasal = apsManager.isManualTempBasal
        tempBasals = objects.filter { $0.tempBasal != nil }
        suspendAndResumeEvents = objects.filter {
            $0.type == EventType.pumpSuspend.rawValue || $0.type == EventType.pumpResume.rawValue
        }
    }

    // MARK: - Last Bolus

    @MainActor func setupLastBolusController() {
        lastBolusControllerDelegate.onContentChange = { [weak self] in
            Task { @MainActor in
                self?.updateLastBolusFromController()
            }
        }

        do {
            try lastBolusController.performFetch()
            updateLastBolusFromController()
        } catch {
            debug(.default, "\(DebuggingIdentifiers.failed) Failed to perform last bolus fetch: \(error)")
        }
    }

    @MainActor private func updateLastBolusFromController() {
        lastPumpBolus = lastBolusController.fetchedObjects?.first
    }
}
