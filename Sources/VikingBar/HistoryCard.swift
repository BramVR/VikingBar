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
        self.cardContent
            .background(HistoryCompanionAnchor(companion: self.companion, content: self.content))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: self.companion.activate) {
                Text("Last 30 days").font(.body.weight(.medium))
            }
            .buttonStyle(.menuAction)
            .focused(self.$focused)
            .onMoveCommand { self.companion.moveSelection($0) }
            .onExitCommand { self.companion.dismiss() }
            .accessibilityLabel("Daily SIM data and estimate")
            .accessibilityValue(self.content.presentation.totalText)
            .accessibilityHint("Open details. Use Left and Right Arrow to select days, and Escape to close.")
            .accessibilityIdentifier("vikingbar.historyDisclosure")
            HStack(alignment: .top) {
                self.selectedMetric
                self.metric(title: "Cycle so far", value: self.totalText)
            }
            if !self.content.presentation.days.isEmpty {
                self.sparkline
            } else {
                Text("No daily observations available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var selectedMetric: some View {
        let day = self.selectedDay
        return VStack(alignment: .leading, spacing: 1) {
            Text(day?.label ?? "Today")
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityLabel(day?.fullDateText ?? "Today")
                .accessibilityIdentifier("vikingbar.historyMainSelectedDate")
            HStack(spacing: 4) {
                Text(day.map(self.amountText) ?? "Unavailable")
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    .accessibilityLabel(day?.valueText ?? "Unavailable")
                    .accessibilityIdentifier("vikingbar.historyMainSelectedValue")
                Text(day.map(HistoryMainDayStatus.text(for:)) ?? "No data")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel(day?.statusText ?? "No data")
                    .accessibilityIdentifier("vikingbar.historyMainSelectedStatus")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
    }

    private var selectedDay: HistoryDayPresentation? {
        self.content.presentation.days.first(where: { $0.dayStart == self.companion.selectedDayStart })
            ?? self.content.presentation.days.first(where: \ .isToday)
            ?? self.content.presentation.days.last
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
        Chart {
            ForEach(Array(self.content.presentation.days.enumerated()), id: \ .offset) { index, day in
                if let value = day.value {
                    BarMark(x: .value("Day", Double(index)), y: .value(self.content.presentation.unit, value))
                        .foregroundStyle(day.isStale ? Color.orange : Color.cyan)
                        .opacity(day.isToday ? 0.5 : 0.9)
                } else {
                    PointMark(x: .value("Day", Double(index)), y: .value(self.content.presentation.unit, 0))
                        .symbol(.cross).symbolSize(8).foregroundStyle(.secondary)
                }
            }
            if let boundary = self.content.presentation.boundary {
                RuleMark(x: .value("Cycle started", boundary.position))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.orange)
            }
            if let selectedDay, let index = self.content.presentation.days.firstIndex(of: selectedDay) {
                RuleMark(x: .value("Selected day", Double(index)))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .chartXScale(domain: -0.5 ... Double(self.content.presentation.days.count) - 0.5)
        .chartXAxis {
            AxisMarks(values: [0, Double(self.content.presentation.days.count - 1)]) { value in
                let index = value.as(Double.self).map(Int.init) ?? 0
                AxisValueLabel(anchor: index == 0 ? .topLeading : .topTrailing, collisionResolution: .disabled) {
                    if self.content.presentation.days.indices.contains(index) {
                        Text(self.content.presentation.days[index].label).font(.caption2)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 72)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    HistoryPlotReader(
                        identifier: "vikingbar.historyMainPlot",
                        label: "Last 30 days plot",
                        onMoved: { location in self.selectMain(at: location, width: frame.width) },
                        onExited: {},
                        onActivated: { location in
                            guard let selection = self.selection(at: location, width: frame.width) else { return }
                            self.companion.activate(dayStart: selection.dayStart)
                        },
                    )
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.content.presentation.days.map {
            "\($0.label): \($0.valueText)"
        }.joined(separator: "; "))
        .accessibilityHint("Hover a day for details. Click to open the detailed chart.")
        .accessibilityIdentifier("vikingbar.historySparkline")
    }

    private func selectMain(at location: CGPoint, width: CGFloat) {
        guard let selection = self.selection(at: location, width: width) else { return }
        self.companion.select(dayStart: selection.dayStart)
    }

    private func selection(at location: CGPoint, width: CGFloat) -> HistoryPlotSelection? {
        HistoryPlotSelection.at(
            horizontalPosition: location.x,
            width: width,
            dayStarts: self.content.presentation.days.map(\.dayStart),
        )
    }
}

struct HistoryPlotReader: NSViewRepresentable {
    let identifier: String
    let label: String
    let onMoved: (CGPoint) -> Void
    let onExited: () -> Void
    let onActivated: (CGPoint) -> Void

    func makeNSView(context _: Context) -> TrackingView {
        TrackingView(
            identifier: self.identifier,
            label: self.label,
            onMoved: self.onMoved,
            onExited: self.onExited,
            onActivated: self.onActivated,
        )
    }

    func updateNSView(_ view: TrackingView, context _: Context) {
        view.setAccessibilityLabel(self.label)
        view.setAccessibilityIdentifier(self.identifier)
        view.onMoved = self.onMoved
        view.onExited = self.onExited
        view.onActivated = self.onActivated
    }

    final class TrackingView: NSView {
        var onMoved: (CGPoint) -> Void
        var onExited: () -> Void
        var onActivated: (CGPoint) -> Void
        private var trackingArea: NSTrackingArea?

        init(
            identifier: String,
            label: String,
            onMoved: @escaping (CGPoint) -> Void,
            onExited: @escaping () -> Void,
            onActivated: @escaping (CGPoint) -> Void,
        ) {
            self.onMoved = onMoved
            self.onExited = onExited
            self.onActivated = onActivated
            super.init(frame: .zero)
            self.setAccessibilityElement(true)
            self.setAccessibilityRole(.group)
            self.setAccessibilityLabel(label)
            self.setAccessibilityIdentifier(identifier)
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
            self.onExited()
        }

        override func mouseDown(with event: NSEvent) {
            let location = self.convert(event.locationInWindow, from: nil)
            self.onMoved(location)
            self.onActivated(location)
        }

        override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
            true
        }

        override func accessibilityPerformPress() -> Bool {
            let location = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
            self.onMoved(location)
            self.onActivated(location)
            return true
        }
    }
}
