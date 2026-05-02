import AppKit
import Charts
import SwiftUI

struct TrafficSparklineView: View {
    let series: TrafficTrendSeries
    let tint: Color
    var height: CGFloat = 32

    var body: some View {
        Group {
            if series.samples.isEmpty {
                emptySparkline
            } else {
                Chart {
                    ForEach(series.samples) { sample in
                        LineMark(
                            x: .value("Time", sample.capturedAt),
                            y: .value("Rate", sample.normalizedValue)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(tint)

                        if series.samples.count == 1 {
                            PointMark(
                                x: .value("Time", sample.capturedAt),
                                y: .value("Rate", sample.normalizedValue)
                            )
                            .foregroundStyle(tint)
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: -0.05...1)
            }
        }
        .frame(height: height)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.25))
                .frame(height: 1)
        }
        .accessibilityLabel("Traffic trend \(series.direction.title)")
    }

    private var emptySparkline: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
