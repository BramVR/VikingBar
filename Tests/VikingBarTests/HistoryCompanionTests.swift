import CoreGraphics
import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

struct HistoryCompanionTests {
    @Test func `measurement anchor cannot steal active ownership and stale detach is ignored`() {
        let active = UUID()
        let measurement = UUID()
        var state = HistoryCompanionInteractionState()

        let attachedActive = state.attach(active)
        let attachedMeasurement = state.attach(measurement)
        let detachedMeasurement = state.detach(measurement)
        #expect(attachedActive)
        #expect(!attachedMeasurement)
        #expect(!detachedMeasurement)
        #expect(state.activeAnchor == active)
        state.openDetail()
        let detachedActive = state.detach(active)
        #expect(detachedActive)
        #expect(state.activeAnchor == nil)
        #expect(!state.isDetailOpen)
        let reclaimed = state.attach(measurement)
        #expect(reclaimed)
        #expect(state.activeAnchor == measurement)
    }

    @Test func `context change closes a persistent detail presentation`() {
        let token = UUID()
        var state = HistoryCompanionInteractionState()
        _ = state.attach(token)
        state.openDetail()
        #expect(state.isDetailOpen)

        state.contextChanged()
        #expect(!state.isDetailOpen)
        #expect(state.activeAnchor == token)
    }

    @Test func `detail stays open until explicit dismissal`() {
        let token = UUID()
        var state = HistoryCompanionInteractionState()
        _ = state.attach(token)
        state.openDetail()
        #expect(state.isDetailOpen)
        state.closeDetail()
        #expect(!state.isDetailOpen)
    }

    @Test func `plot selection maps the full width to exactly thirty ordered slots`() throws {
        let days = (0 ..< 30).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        #expect(try #require(HistoryPlotSelection.at(horizontalPosition: -5, width: 300, dayStarts: days)).index == 0)
        #expect(try #require(HistoryPlotSelection.at(horizontalPosition: 0, width: 300, dayStarts: days)).index == 0)
        #expect(try #require(HistoryPlotSelection.at(horizontalPosition: 9.99, width: 300, dayStarts: days)).index == 0)
        #expect(try #require(HistoryPlotSelection.at(horizontalPosition: 10, width: 300, dayStarts: days)).index == 1)
        #expect(try #require(HistoryPlotSelection.at(horizontalPosition: 299.99, width: 300, dayStarts: days))
            .index == 29)
        #expect(try #require(HistoryPlotSelection.at(horizontalPosition: 400, width: 300, dayStarts: days)).index == 29)
        #expect(HistoryPlotSelection.at(horizontalPosition: 0, width: 0, dayStarts: days) == nil)
        #expect(HistoryPlotSelection.at(horizontalPosition: 0, width: 300, dayStarts: []) == nil)
    }

    @Test func `compact zero status retains stale and partial qualifiers`() {
        #expect(HistoryMainDayStatus.text(for: Self.day(bytes: 0, stale: false, partial: true)) == "Partial")
        #expect(HistoryMainDayStatus.text(for: Self.day(bytes: 0, stale: true, partial: false)) == "Stale")
        #expect(HistoryMainDayStatus.text(for: Self.day(bytes: 0, stale: true, partial: true)) == "Stale · Partial")
        #expect(HistoryMainDayStatus.text(for: Self.day(bytes: 0, stale: false, partial: false)) == "Confirmed zero")
    }

    @Test func `placement prefers left then right and stays beside the parent`() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let content = CGSize(width: 420, height: 620)
        let left = HistoryCompanionPlacement.frame(
            parent: CGRect(x: 700, y: 100, width: 360, height: 640),
            contentSize: content,
            visibleFrames: [screen],
        )
        #expect(left.maxX == 692)
        #expect(!left.intersects(CGRect(x: 700, y: 100, width: 360, height: 640)))

        let negativeScreen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let parent = CGRect(x: -1430, y: 100, width: 360, height: 640)
        let right = HistoryCompanionPlacement.frame(
            parent: parent,
            contentSize: content,
            visibleFrames: [negativeScreen],
        )
        #expect(right.minX == parent.maxX + 8)
        #expect(negativeScreen.contains(right))
        #expect(!right.intersects(parent))
    }

    @Test func `placement shrinks to readable side space and contains impossible fallback`() {
        let constrained = CGRect(x: 0, y: 0, width: 720, height: 700)
        let parent = CGRect(x: 352, y: 20, width: 360, height: 640)
        let side = HistoryCompanionPlacement.frame(
            parent: parent,
            contentSize: CGSize(width: 420, height: 620),
            visibleFrames: [constrained],
        )
        #expect(side.width == 344)
        #expect(constrained.contains(side))
        #expect(!side.intersects(parent))

        let tiny = CGRect(x: 40, y: -100, width: 500, height: 360)
        let fallback = HistoryCompanionPlacement.frame(
            parent: CGRect(x: 110, y: -80, width: 360, height: 320),
            contentSize: CGSize(width: 420, height: 620),
            visibleFrames: [tiny],
        )
        #expect(fallback.size == CGSize(width: 420, height: 360))
        #expect(tiny.contains(fallback))
    }

    private static func day(bytes: UInt64?, stale: Bool, partial: Bool) -> HistoryDayPresentation {
        HistoryDayPresentation(
            dayStart: Date(timeIntervalSince1970: 0),
            bytes: bytes,
            value: bytes.map(Double.init),
            isMissing: bytes == nil,
            isStale: stale,
            isToday: partial,
            isPartial: partial,
            label: "1 Jan",
            fullDateText: "1 January 1970",
            valueText: bytes.map(String.init) ?? "Missing",
            statusText: bytes == nil ? "No data (missing)" : "Data usage confirmed",
        )
    }
}
