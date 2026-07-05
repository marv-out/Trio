import Charts
import Foundation
import SwiftUI

struct InsulinView: ChartContent {
    let glucoseData: [GlucoseRecord]
    let insulinData: [PumpEventDetails]
    let units: GlucoseUnits
    let bolusDisplayThreshold: BolusDisplayThreshold

    var body: some ChartContent {
        drawBoluses()
    }

    private func drawBoluses() -> some ChartContent {
        ForEach(insulinData) { insulin in
            let amount = insulin.bolus?.amount ?? 0
            let bolusDate = insulin.timestamp ?? Date()

            if amount != 0, let glucose = MainChartHelper.timeToNearestGlucose(
                glucoseValues: glucoseData,
                time: bolusDate.timeIntervalSince1970
            )?.glucose {
                let yPosition = (units == .mgdL ? Decimal(glucose) : Decimal(glucose).asMmolL) + MainChartHelper
                    .bolusOffset(units: units)
                let size = (
                    MainChartHelper.Config.bolusSize + CGFloat(truncating: amount as NSDecimalNumber) * MainChartHelper.Config
                        .bolusScale
                )

                PointMark(
                    x: .value("Time", bolusDate, unit: .second),
                    y: .value("Value", yPosition)
                )
                .symbol {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: size)).foregroundStyle(Color.insulin)
                }
                .annotation(position: .top) {
                    if amount >= bolusDisplayThreshold.rawValue {
                        Text(Formatter.bolusFormatter.string(from: amount as NSDecimalNumber) ?? "")
                            .font(.caption2)
                            .foregroundStyle(Color.primary)
                    }
                }
            }
        }
    }
}
