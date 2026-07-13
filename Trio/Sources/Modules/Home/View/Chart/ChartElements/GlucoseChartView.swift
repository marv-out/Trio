import Charts
import Foundation
import SwiftUI

struct GlucoseChartView: ChartContent {
    let glucoseData: [GlucoseRecord]
    let units: GlucoseUnits
    let highGlucose: Decimal
    let lowGlucose: Decimal
    let currentGlucoseTarget: Decimal
    let isSmoothingEnabled: Bool
    let glucoseColorScheme: GlucoseColorScheme

    var body: some ChartContent {
        drawGlucoseChart()
    }

    /// Dynamic point color for a CGM reading. Manual readings render red and skip this.
    private func pointColor(for item: GlucoseRecord) -> Color {
        // TODO: workaround for now: set low value to 55, to have dynamic color shades between 55 and user-set low (approx. 70); same for high glucose
        let hardCodedLow = Decimal(55)
        let hardCodedHigh = Decimal(220)
        let isDynamicColorScheme = glucoseColorScheme == .dynamicColor

        return Trio.getDynamicGlucoseColor(
            glucoseValue: Decimal(item.glucose),
            highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
            lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }

    private func drawGlucoseChart() -> some ChartContent {
        ForEach(glucoseData) { item in
            let glucoseToDisplay = units == .mgdL ? Decimal(item.glucose) : Decimal(item.glucose).asMmolL

            if item.isManual {
                PointMark(
                    x: .value("Time", item.date ?? Date(), unit: .second),
                    y: .value("Value", glucoseToDisplay)
                )
                .symbolSize(20)
                // Explicit `symbol:` label: with the bare trailing closure the type checker can
                // drift to the unlabeled iOS 26 `symbol(_: some Chart3DSymbolShape)` overload.
                .symbol(symbol: {
                    Image(systemName: "drop.fill")
                        .font(.caption2)
                        .symbolRenderingMode(.monochrome)
                        .bold()
                        .foregroundStyle(.red)
                })
            } else {
                PointMark(
                    x: .value("Time", item.date ?? Date(), unit: .second),
                    y: .value("Value", glucoseToDisplay)
                )
                .foregroundStyle(pointColor(for: item))
                .symbolSize(20)
                .symbol(.circle)
            }

            if isSmoothingEnabled, let smoothedGlucose = item.smoothedGlucose, smoothedGlucose != 0 {
                let smoothedGlucoseForDisplay: Decimal = units == .mgdL ? smoothedGlucose : smoothedGlucose.asMmolL
                LineMark(
                    x: .value("Time", item.date ?? Date(), unit: .second),
                    y: .value("Value", smoothedGlucoseForDisplay),
                    series: .value("Type", "Smoothed")
                )
                .foregroundStyle(Color.secondary)
            }
        }
    }
}

#Preview {
    // Synthetic GRDB records for the preview (every 5 minutes, varying 120–140). Built in an explicit
    // loop so the compiler doesn't have to type-check a large single expression.
    func makePreviewGlucose() -> [GlucoseRecord] {
        var records: [GlucoseRecord] = []
        for index in 0 ..< 24 {
            let value = Int16(120 + (index % 3) * 10)
            let date = Date.now.addingTimeInterval(Double(index) * -300)
            records.append(GlucoseRecord(
                pk: Int64(index),
                id: UUID(),
                date: date,
                glucose: value,
                direction: BloodGlucose.Direction.flat.rawValue,
                isManual: false
            ))
        }
        return records
    }

    struct PreviewWrapper: View {
        let glucoseData: [GlucoseRecord]

        var body: some View {
            NavigationView {
                VStack {
                    Chart {
                        GlucoseChartView(
                            glucoseData: glucoseData,
                            units: .mgdL,
                            highGlucose: 180,
                            lowGlucose: 70,
                            currentGlucoseTarget: 100,
                            isSmoothingEnabled: false,
                            glucoseColorScheme: .dynamicColor
                        )
                    }
                    .frame(height: 200)
                    .padding()
                }
                .navigationTitle("Glucose Chart")
            }
        }
    }

    return PreviewWrapper(glucoseData: makePreviewGlucose())
}
