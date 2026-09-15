import AppKit
import Charts
import SwiftUI
import VikingBarCore

@MainActor
struct HistoryCard: View {
    let content: HistoryCompanionContent
    let companion: HistoryCompanionController
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: self.companion.activate) { self.cardContent }
            .buttonStyle(.plain)
            .focused(self.$focused)
            .onChange(of: self.focused) { _, focused in self.companion.keyboardFocusChanged(focused) }
            .onMoveCommand { self.companion.moveSelection($0) }
            .onExitCommand { self.companion.dismiss() }
            .background(HistoryCompanionAnchor(companion: self.companion, content: self.content))
            .accessibilityLabel("Daily SIM data and estimate")
            .accessibilityValue(self.content.presentation.totalText)
            .accessibilityHint("Open details. Use Left and Right Arrow to select days, and Escape to close.")
            .accessibilityIdentifier("vikingbar.historyDisclosure")
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Daily SIM data").font(.caption.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                self.todayMetric
                Divider().frame(height: 27)
                self.metric(title: "Cycle so far", value: self.totalText)
            }
            if !self.content.presentation.days.isEmpty {
                self.sparkline
            }
        }
        .padding(8)
        .background(Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cyan.opacity(0.45)))
        .contentShape(Rectangle())
    }

    private var todayMetric: some View {
        let value = self.today.map(self.amountText) ?? "Unavailable"
        let note = self.today.flatMap(self.summaryStatus)
        return self.metric(title: "Today", value: value, note: note)
    }

    private var today: HistoryDayPresentation? {
        self.content.presentation.days.first(where: \ .isToday)
    }

    private var totalText: String {
        guard let total = self.content.presentation.totalObservedBytes,
              let unit = DataUnit(rawValue: self.content.presentation.unit) else { return "Unavailable" }
        return unit.format(bytes: total)
    }

    private func amountText(_ day: HistoryDayPresentation) -> String {
        guard let bytes = day.bytes, let unit = DataUnit(rawValue: self.content.presentation.unit) else {
            return "Unavailable"
        }
        return unit.format(bytes: bytes)
    }

    private func summaryStatus(_ day: HistoryDayPresentation) -> String? {
        let labels = [(day.isStale, "Stale"), (day.isPartial, "Partial")].compactMap { included, label in
            included ? label : nil
        }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }

    private func metric(title: String, value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value).font(.caption.weight(.semibold)).lineLimit(1)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
    }

    private var sparkline: some View {
        Chart(Array(self.content.presentation.days.enumerated()), id: \ .offset) { index, day in
            if let value = day.value {
                BarMark(x: .value("Day", index), y: .value(self.content.presentation.unit, value))
                    .foregroundStyle(day.isStale ? Color.orange : Color.cyan)
                    .opacity(day.isToday ? 0.5 : 0.9)
            } else {
                PointMark(x: .value("Day", index), y: .value(self.content.presentation.unit, 0))
                    .symbol(.cross)
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 24)
        .accessibilityHidden(true)
        .accessibilityIdentifier("vikingbar.historySparkline")
    }
}

@MainActor
struct HistoryDetailView: View {
    @Bindable var companion: HistoryCompanionController
    let panelToken: UUID

    var body: some View {
        if let content = self.companion.content {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily SIM data").font(.title2.weight(.semibold))
                        Text(self.rangeText(content)).foregroundStyle(.secondary)
                    }
                    Text(content.error ?? (content.isLoading ? "Loading history…" : content.presentation.statusText))
                        .font(.caption)
                        .accessibilityIdentifier("vikingbar.historyStatus")
                    if content.presentation.days.isEmpty {
                        Text("No daily observations available.")
                            .frame(maxWidth: .infinity, minHeight: 220)
                            .foregroundStyle(.secondary)
                    } else {
                        self.chart(content)
                        self.selectedDay(content)
                    }
                    Divider()
                    Text(content.presentation.totalText)
                        .font(.headline)
                        .accessibilityIdentifier("vikingbar.historyTotal")
                    Text(content.presentation.forecastText)
                        .fontWeight(.medium)
                        .accessibilityIdentifier("vikingbar.historyForecast")
                    Text(content.presentation.scopeText)
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("vikingbar.historyScope")
                    Text("Selected bundle reported \(content.reportedUsedText)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .frame(minWidth: 300, idealWidth: 420, maxWidth: 420, minHeight: 420, idealHeight: 620, maxHeight: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .background(HistoryPanelHoverReader(companion: self.companion, token: self.panelToken))
        }
    }

    private func chart(_ content: HistoryCompanionContent) -> some View {
        let days = content.presentation.days
        return Chart(Array(days.enumerated()), id: \ .offset) { index, day in
            self.marks(index: index, day: day, unit: content.presentation.unit)
        }
        .chartXScale(domain: -0.5 ... Double(max(0, days.count - 1)) + 0.5)
        .chartXAxis {
            AxisMarks(values: self.axisIndexes(days.count)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(collisionResolution: .greedy) {
                    if let index = value.as(Double.self).map(Int.init), days.indices.contains(index) {
                        Text(days[index].label).fixedSize()
                    }
                }
            }
        }
        .chartYAxisLabel(content.presentation.unit)
        .frame(height: 230)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    HistoryPlotReader { location in
                        guard let location else { return }
                        let fraction = min(max(location.x / max(frame.width, 1), 0), 0.999_999)
                        let index = min(Int(fraction * Double(days.count)), days.count - 1)
                        self.companion.select(dayStart: days[index].dayStart)
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily SIM data chart")
        .accessibilityValue(days.map { "\($0.label): \($0.valueText)" }
            .joined(separator: "; "))
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
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.fullDateText).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vikingbar.historySelectedDate")
                Text(day.valueText).font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityIdentifier("vikingbar.historySelectedValue")
                Text(day.statusText).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vikingbar.historySelectedStatus")
            }
            Spacer()
            if let today = content.presentation.days.first(where: \ .isToday), today.dayStart != day.dayStart {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today").foregroundStyle(.secondary)
                    Text(today.valueText).font(.headline).lineLimit(1).minimumScaleFactor(0.75)
                }
            }
        }
        .frame(height: 76, alignment: .top)
    }

    private func rangeText(_ content: HistoryCompanionContent) -> String {
        guard let first = content.presentation.days.first, let last = content.presentation.days.last else {
            return content.subscriptionName
        }
        return "\(first.label) – \(last.fullDateText) · \(content.subscriptionName)"
    }

    private func axisIndexes(_ count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let step = max(1, count / 4)
        var indexes = stride(from: 0, to: count, by: step).map(Double.init)
        if indexes.last != Double(count - 1) {
            indexes.append(Double(count - 1))
        }
        return indexes
    }
}

struct HistoryPlotReader: NSViewRepresentable {
    let onMoved: (CGPoint?) -> Void

    func makeNSView(context _: Context) -> TrackingView {
        TrackingView(onMoved: self.onMoved)
    }

    func updateNSView(_ view: TrackingView, context _: Context) {
        view.onMoved = self.onMoved
    }

    final class TrackingView: NSView {
        var onMoved: (CGPoint?) -> Void
        private var trackingArea: NSTrackingArea?

        init(onMoved: @escaping (CGPoint?) -> Void) {
            self.onMoved = onMoved
            super.init(frame: .zero)
            self.setAccessibilityElement(true)
            self.setAccessibilityRole(.group)
            self.setAccessibilityLabel("Daily SIM data plot")
            self.setAccessibilityIdentifier("vikingbar.historyPlot")
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        override var isFlipped: Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.window?.acceptsMouseMovedEvents = true
            self.updateTrackingAreas()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                self.removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil,
            )
            self.addTrackingArea(area)
            self.trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            self.onMoved(self.convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            self.onMoved(self.convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            self.onMoved(nil)
        }
    }
}
