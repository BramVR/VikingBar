import AppKit
import Charts
import SwiftUI
import VikingBarCore

final class HistoryCompanionPanel: NSPanel {
    override var canBecomeMain: Bool {
        false
    }

    override var canBecomeKey: Bool {
        false
    }
}

struct HistoryCompanionAnchor: NSViewRepresentable {
    let companion: HistoryCompanionController
    let content: HistoryCompanionContent?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AnchorView {
        AnchorView(companion: self.companion, token: context.coordinator.token, content: self.content)
    }

    func updateNSView(_ view: AnchorView, context _: Context) {
        view.content = self.content
        view.attachIfPossible()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        view.companion?.detach(token: coordinator.token)
    }

    final class Coordinator {
        let token = UUID()
    }

    final class AnchorView: NSView {
        weak var companion: HistoryCompanionController?
        let token: UUID
        var content: HistoryCompanionContent?

        init(companion: HistoryCompanionController, token: UUID, content: HistoryCompanionContent?) {
            self.companion = companion
            self.token = token
            self.content = content
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if self.window == nil {
                self.companion?.detach(token: self.token)
            } else {
                self.attachIfPossible()
            }
        }

        override func layout() {
            super.layout()
            self.attachIfPossible()
        }

        func attachIfPossible() {
            guard self.window != nil, !self.isHiddenOrHasHiddenAncestor, !self.visibleRect.isEmpty else { return }
            self.companion?.attach(anchorView: self, token: self.token, content: self.content)
        }
    }
}

@MainActor
struct HistoryDetailView: View {
    @Bindable var companion: HistoryCompanionController

    var body: some View {
        if let content = self.companion.content {
            ViewThatFits(in: .vertical) {
                self.detailContent(content)
                ScrollView { self.detailContent(content) }
            }
            .frame(width: 360)
            .frame(maxHeight: 460)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .onExitCommand { self.companion.dismiss() }
        }
    }

    private func detailContent(_ content: HistoryCompanionContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            self.header(content)
            Text(self.rangeText(content)).font(.footnote).foregroundStyle(.secondary)
            Text(content.error ?? (content.isLoading ? "Loading history…" : content.presentation.statusText))
                .font(.caption)
                .accessibilityIdentifier("vikingbar.historyStatus")
            self.chartSection(content)
            Divider()
            self.currentCycle(content)
            Divider()
            self.about(content)
        }
        .padding(14)
    }

    private func header(_ content: HistoryCompanionContent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Daily SIM data").font(.headline.weight(.semibold))
                Text(content.subscriptionName)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: self.companion.dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close history details")
            .accessibilityIdentifier("vikingbar.historyClose")
        }
    }

    @ViewBuilder
    private func chartSection(_ content: HistoryCompanionContent) -> some View {
        if content.presentation.days.isEmpty {
            Text("No daily observations available.")
                .frame(maxWidth: .infinity, minHeight: 128)
                .foregroundStyle(.secondary)
        } else {
            self.chart(content)
            if let boundary = content.presentation.boundary {
                Text("\(boundary.label) · \(boundary.dateText)")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("vikingbar.historyBoundary")
            }
            self.selectedDay(content)
        }
    }

    @ViewBuilder
    private func currentCycle(_ content: HistoryCompanionContent) -> some View {
        Text("Current cycle").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        self.detailRow(
            title: "Observed so far",
            value: content.presentation.totalObservedBytes.map(content.unit.format(bytes:)) ?? "Unavailable",
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.presentation.totalText)
        .accessibilityIdentifier("vikingbar.historyTotal")
        self.detailRow(title: "Estimated at renewal", value: self.forecastAmount(content))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.presentation.forecastText)
            .accessibilityIdentifier("vikingbar.historyForecast")
    }

    @ViewBuilder
    private func about(_ content: HistoryCompanionContent) -> some View {
        Text("About this data").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Text(content.presentation.scopeText)
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("vikingbar.historyScope")
        self.detailRow(
            title: "Selected bundle reported",
            value: content.reportedUsedBytes.map(content.unit.format(bytes:)) ?? "Unavailable",
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Selected bundle reported \(content.reportedUsedText)")
        .accessibilityIdentifier("vikingbar.historyBundleReported")
    }

    private func chart(_ content: HistoryCompanionContent) -> some View {
        let days = content.presentation.days
        return Chart {
            ForEach(Array(days.enumerated()), id: \ .offset) { index, day in
                self.marks(index: index, day: day, unit: content.presentation.unit)
            }
            if let boundary = content.presentation.boundary {
                RuleMark(x: .value("Cycle started", boundary.position))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.orange)
            }
        }
        .chartXScale(domain: -0.5 ... Double(max(0, days.count)) - 0.5)
        .chartXAxis {
            AxisMarks(values: self.axisIndexes(days.count)) { value in
                AxisValueLabel(
                    anchor: value.as(Double.self) == 0 ? .topLeading : .topTrailing,
                    collisionResolution: .disabled,
                ) {
                    if let index = value.as(Double.self).map(Int.init), days.indices.contains(index) {
                        Text(days[index].label).fixedSize()
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 128)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    HistoryPlotReader(
                        identifier: "vikingbar.historyPlot",
                        label: "Daily SIM data plot",
                        onMoved: { location in self.select(at: location, width: frame.width, days: days) },
                        onExited: {},
                        onActivated: { location in self.select(at: location, width: frame.width, days: days) },
                    )
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(days.map { "\($0.label): \($0.valueText)" }.joined(separator: "; "))
        .accessibilityHint("Daily SIM data chart")
        .accessibilityIdentifier("vikingbar.historyChart")
    }

    @ChartContentBuilder
    private func marks(index: Int, day: HistoryDayPresentation, unit: String) -> some ChartContent {
        if let value = day.value {
            BarMark(x: .value("Day", Double(index)), y: .value(unit, value))
                .foregroundStyle(day.isStale ? Color.orange : Color.cyan)
                .opacity(day.isToday ? 0.55 : 0.9)
            if value == 0 {
                PointMark(x: .value("Day", Double(index)), y: .value(unit, 0))
                    .symbolSize(28)
                    .foregroundStyle(day.isStale ? Color.orange : Color.cyan)
            }
        } else {
            PointMark(x: .value("Day", Double(index)), y: .value(unit, 0))
                .symbol(.cross)
                .symbolSize(35)
                .foregroundStyle(.secondary)
        }
        if day.dayStart == self.companion.selectedDayStart {
            RuleMark(x: .value("Selected day", Double(index)))
                .foregroundStyle(.secondary)
        }
    }

    private func selectedDay(_ content: HistoryCompanionContent) -> some View {
        let day = content.presentation.days.first(where: { $0.dayStart == self.companion.selectedDayStart })
            ?? content.presentation.days.last!
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(day.fullDateText).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vikingbar.historySelectedDate")
                Spacer(minLength: 8)
                Text(day.valueText).font(.headline).lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityIdentifier("vikingbar.historySelectedValue")
            }
            HStack(spacing: 6) {
                Text(day.statusText)
                    .accessibilityIdentifier("vikingbar.historySelectedStatus")
                if let today = content.presentation.days.first(where: \ .isToday), today.dayStart != day.dayStart {
                    Text("Today \(today.valueText)")
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }

    private func forecastAmount(_ content: HistoryCompanionContent) -> String {
        guard let forecast = content.presentation.forecast else { return "Unavailable" }
        let divisor = content.unit == .gigabytes ? 1_000_000_000.0 : 1_073_741_824.0
        return String(
            format: "%.2f %@",
            locale: Locale(identifier: "en_US_POSIX"),
            forecast.estimatedCycleBytes / divisor,
            content.unit.rawValue,
        )
    }

    private func select(at location: CGPoint, width: CGFloat, days: [HistoryDayPresentation]) {
        guard let selection = HistoryPlotSelection.at(
            horizontalPosition: location.x,
            width: width,
            dayStarts: days.map(\.dayStart),
        ) else { return }
        self.companion.select(dayStart: selection.dayStart)
    }

    private func rangeText(_ content: HistoryCompanionContent) -> String {
        guard let first = content.presentation.days.first, let last = content.presentation.days.last else {
            return content.subscriptionName
        }
        return "\(first.label) – \(last.fullDateText)"
    }

    private func axisIndexes(_ count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return [0, Double(count - 1)]
    }
}
