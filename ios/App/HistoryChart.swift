import Charts
import SwiftUI

/// One point of one line in a history chart.
struct HistorySample: Identifiable {
    let id: Int
    let time: Date
    let value: Double
    let series: String
}

/// A small line chart of one or more series over time.
struct HistoryChart: View {
    let samples: [HistorySample]
    /// Series names in legend order.
    let seriesNames: [String]
    /// One colour per series name.
    let seriesColours: [Color]
    /// What VoiceOver reads instead of the marks.
    let summary: String

    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 170

    var body: some View {
        Chart(samples) { sample in
            LineMark(
                x: .value("Time", sample.time),
                y: .value("Value", sample.value)
            )
            .foregroundStyle(by: .value("Series", sample.series))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(domain: seriesNames, range: seriesColours)
        .frame(height: chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }
}
