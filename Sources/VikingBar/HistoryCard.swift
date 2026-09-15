import Charts
import SwiftUI
import VikingBarCore

struct HistoryCard: View {
    let presentation: HistoryPresentation
    let isLoading: Bool
    let error: String?
    let reportedUsedText: String
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup("Daily SIM data and estimate", isExpanded: self.$expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(self.error ?? (self.isLoading ? "Loading history…" : self.presentation.statusText))
                    .accessibilityIdentifier("vikingbar.historyStatus")
                if !self.presentation.days.isEmpty {
                    self.chart
                    Text("Cross = missing · Dot = zero · Faded = today")
                        .foregroundStyle(.secondary)
                }
                Text(self.presentation.totalText)
                    .accessibilityIdentifier("vikingbar.historyTotal")
                Text("Selected bundle reported \(self.reportedUsedText.lowercased())")
                Text(self.presentation.forecastText)
                    .fontWeight(.medium)
                    .accessibilityIdentifier("vikingbar.historyForecast")
                Text(self.presentation.scopeText)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("vikingbar.historyScope")
            }
            .font(.caption2)
            .padding(.top, 5)
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vikingbar.historyDisclosure")
    }

    private var chart: some View {
        Chart(Array(self.presentation.days.enumerated()), id: \.offset) { _, day in
            if let value = day.value {
                BarMark(x: .value("Day", day.label), y: .value(self.presentation.unit, value))
                    .foregroundStyle(day.isStale ? Color.orange : Color.accentColor)
                    .opacity(day.isToday ? 0.5 : 1)
                if value == 0 {
                    PointMark(x: .value("Day", day.label), y: .value(self.presentation.unit, 0))
                        .symbolSize(12)
                        .foregroundStyle(day.isStale ? Color.orange : Color.accentColor)
                }
            } else {
                PointMark(x: .value("Day", day.label), y: .value(self.presentation.unit, 0))
                    .symbol(.cross)
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: self.presentation.days.enumerated().compactMap { index, day in
                index % max(1, self.presentation.days.count / 3) == 0
                    || index == self.presentation.days.count - 1 ? day.label : nil
            }) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(collisionResolution: .greedy) {
                    if let label = value.as(String.self) {
                        Text(label).fixedSize()
                    }
                }
            }
        }
        .chartYAxisLabel(self.presentation.unit)
        .frame(height: 90)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily SIM data chart")
        .accessibilityValue(self.presentation.days.map { "\($0.label): \($0.valueText)" }.joined(separator: "; "))
        .accessibilityIdentifier("vikingbar.historyChart")
    }
}
