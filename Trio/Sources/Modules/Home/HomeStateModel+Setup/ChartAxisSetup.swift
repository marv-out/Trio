import Foundation

extension Home.StateModel {
    @MainActor func yAxisChartDataCobChart(determinations: [OrefDetermination]) {
        let cobMapped = determinations.map { Decimal($0.cob) }
        let maxCob = cobMapped.max()

        if let maxCob = maxCob {
            let calculatedMax = maxCob == 0 ? 20 : maxCob + 20
            minValueCobChart = 0
            maxValueCobChart = calculatedMax
        } else {
            minValueCobChart = 0
            maxValueCobChart = 20
        }
    }

    @MainActor func yAxisChartDataIobChart(determinations: [OrefDetermination]) {
        let iobMapped = determinations.compactMap { $0.iob?.decimalValue }
        let minIob = iobMapped.min()
        let maxIob = iobMapped.max()

        if let minIob = minIob, let maxIob = maxIob {
            minValueIobChart = minIob
            maxValueIobChart = maxIob
        } else {
            minValueIobChart = 0
            maxValueIobChart = 5
        }
    }
}
