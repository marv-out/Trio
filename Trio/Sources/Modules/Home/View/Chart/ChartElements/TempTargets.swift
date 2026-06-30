import Charts
import Foundation
import SwiftUI

struct TempTargetView: ChartContent {
    let tempTargetStored: [TempTargetRecord]
    let tempTargetRunStored: [TempTargetRunRecord]
    let units: GlucoseUnits

    var body: some ChartContent {
        drawActiveTempTargets()
        drawTempTargetRunStored()
    }

    private func drawActiveTempTargets() -> some ChartContent {
        ForEach(tempTargetStored) { tt in
            // `duration` is in minutes; convert to seconds. A 0/nil duration or target is skipped,
            // mirroring the former `MainChartHelper.calculateDuration/Target` (which returned nil).
            if let durationMinutes = tt.duration, durationMinutes != 0,
               let target = tt.target, target != 0
            {
                let start: Date = tt.date ?? .distantPast
                let end: Date = start.addingTimeInterval(TimeInterval(truncating: (durationMinutes * 60) as NSNumber))

                RuleMark(
                    xStart: .value("Start", start, unit: .second),
                    xEnd: .value("End", end, unit: .second),
                    y: .value("Value", units == .mgdL ? target : target.asMmolL)
                )
                .foregroundStyle(Color.green.opacity(0.4))
                .lineStyle(.init(lineWidth: 8))
            }
        }
    }

    private func drawTempTargetRunStored() -> some ChartContent {
        ForEach(tempTargetRunStored) { tt in
            let start: Date = tt.startDate ?? .distantPast
            let end: Date = tt.endDate ?? Date()
            let target = tt.target ?? 100
            RuleMark(
                xStart: .value("Start", start, unit: .second),
                xEnd: .value("End", end, unit: .second),
                y: .value("Value", units == .mgdL ? target : target.asMmolL)
            )
            .foregroundStyle(Color.green.opacity(0.25))
            .lineStyle(.init(lineWidth: 8))
        }
    }
}
