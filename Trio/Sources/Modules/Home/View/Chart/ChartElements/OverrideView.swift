import Charts
import Foundation
import SwiftUI

struct OverrideView: ChartContent {
    var state: Home.StateModel
    let overrides: [OverrideRecord]
    let overrideRunStored: [OverrideRunRecord]
    let units: GlucoseUnits

    var body: some ChartContent {
        drawActiveOverrides()
        drawOverrideRunStored()
    }

    private func drawActiveOverrides() -> some ChartContent {
        ForEach(overrides) { override in
            let start: Date = override.date ?? .distantPast
            // `duration` is in minutes; convert to seconds (0 → treated as no duration).
            let duration: TimeInterval = {
                let minutes = override.duration ?? 0
                return minutes != 0 ? TimeInterval(truncating: (minutes * 60) as NSNumber) : 0
            }()
            let end: Date = {
                if override.indefinite {
                    return start.addingTimeInterval(60 * 60 * 24 * 30)
                } else if duration != 0 {
                    return start.addingTimeInterval(duration)
                } else {
                    return start.addingTimeInterval(60 * 60 * 24 * 30)
                }
            }()

            let target = getOverrideTarget(override: override)

            RuleMark(
                xStart: .value("Start", start, unit: .second),
                xEnd: .value("End", end, unit: .second),
                y: .value("Value", units == .mgdL ? target : target.asMmolL)
            )
            .foregroundStyle(Color.purple.opacity(0.4))
            .lineStyle(.init(lineWidth: 8))
        }
    }

    private func drawOverrideRunStored() -> some ChartContent {
        ForEach(overrideRunStored) { overrideRunStored in
            let start: Date = overrideRunStored.startDate ?? .distantPast
            let end: Date = overrideRunStored.endDate ?? Date()
            let target = (overrideRunStored.target ?? 100) == 0 ? 100 : (overrideRunStored.target ?? 100)
            RuleMark(
                xStart: .value("Start", start, unit: .second),
                xEnd: .value("End", end, unit: .second),
                y: .value("Value", units == .mgdL ? target : target.asMmolL)
            )
            .foregroundStyle(Color.purple.opacity(0.25))
            .lineStyle(.init(lineWidth: 8))
        }
    }

    // Handle Overrides where no Target is provided
    private func getOverrideTarget(override: OverrideRecord) -> Decimal {
        if let target = override.target, target != 0 {
            return target
        } else {
            return state.currentGlucoseTarget // Default target
        }
    }
}
