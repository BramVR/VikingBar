import CoreGraphics
import Foundation
import Testing
@testable import VikingBarApp

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
        let detachedActive = state.detach(active)
        #expect(detachedActive)
        #expect(state.activeAnchor == nil)
        let reclaimed = state.attach(measurement)
        #expect(reclaimed)
        #expect(state.activeAnchor == measurement)
    }

    @Test func `context change closes interaction until pointer leaves and deliberately returns`() {
        let token = UUID()
        var state = HistoryCompanionInteractionState()
        _ = state.attach(token)
        let enteredSource = state.sourceHoverChanged(true, token: token)
        #expect(enteredSource)
        state.panelHoverChanged(true)
        state.activate(keyboard: true)
        #expect(state.shouldRemainOpen)

        state.contextChanged()
        #expect(!state.shouldRemainOpen)
        #expect(state.waitsForSourceExit)
        let suppressedReentry = state.sourceHoverChanged(true, token: token)
        let exitedSource = state.sourceHoverChanged(false, token: token)
        let deliberateReentry = state.sourceHoverChanged(true, token: token)
        #expect(!suppressedReentry)
        #expect(exitedSource)
        #expect(deliberateReentry)
        #expect(state.shouldRemainOpen)
    }

    @Test func `panel traversal and keyboard activation keep details open only for their lifetimes`() {
        let token = UUID()
        var state = HistoryCompanionInteractionState()
        _ = state.attach(token)
        let staleEntered = state.sourceHoverChanged(true, token: UUID())
        #expect(!staleEntered)
        #expect(!state.shouldRemainOpen)

        let enteredSource = state.sourceHoverChanged(true, token: token)
        let exitedSource = state.sourceHoverChanged(false, token: token)
        #expect(enteredSource)
        #expect(exitedSource)
        state.panelHoverChanged(true)
        #expect(state.shouldRemainOpen)
        state.panelHoverChanged(false)
        #expect(!state.shouldRemainOpen)

        state.activate(keyboard: true)
        #expect(state.shouldRemainOpen)
        state.keyboardFocusChanged(false)
        #expect(!state.shouldRemainOpen)
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
}
