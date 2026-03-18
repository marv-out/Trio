import Foundation

extension Home.StateModel {
    func yAxisChartDataCobChart(determinations: [[String: Any]]) {
        determinationFetchContext.perform {
            // Map the COB values from the dictionary results
            let cobMapped = determinations.compactMap { entry in
                // First cast to Int16, then convert to Decimal
                if let cobValue = entry["cob"] as? Int16 {
                    return Decimal(cobValue)
                }
                return nil
            }
            let maxCob = cobMapped.max()

            // Ensure the result exists or set default values
            if let maxCob = maxCob {
                let calculatedMax = maxCob == 0 ? 20 : maxCob + 20
                Task {
                    await self.updateCobChartBounds(minValue: 0, maxValue: calculatedMax)
                }
            } else {
                Task {
                    await self.updateCobChartBounds(minValue: 0, maxValue: 20)
                }
            }
        }
    }

    @MainActor private func updateCobChartBounds(minValue: Decimal, maxValue: Decimal) {
        minValueCobChart = minValue
        maxValueCobChart = maxValue
    }

    func yAxisChartDataIobChart(determinations: [[String: Any]]) {
        determinationFetchContext.perform {
            // Map the IOB values from the fetched dictionaries
            let iobMapped = determinations.compactMap { ($0["iob"] as? NSDecimalNumber)?.decimalValue }
            let minIob = iobMapped.min()
            let maxIob = iobMapped.max()

            // Ensure min and max IOB values exist, or set defaults
            if let minIob = minIob, let maxIob = maxIob {
                Task {
                    await self.updateIobChartBounds(minValue: minIob, maxValue: maxIob)
                }
            } else {
                Task {
                    await self.updateIobChartBounds(minValue: 0, maxValue: 5)
                }
            }
        }
    }

    @MainActor private func updateIobChartBounds(minValue: Decimal, maxValue: Decimal) async {
        minValueIobChart = minValue
        maxValueIobChart = maxValue
    }
}
