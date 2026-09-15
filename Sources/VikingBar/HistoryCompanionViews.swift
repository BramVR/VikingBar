import AppKit
import SwiftUI

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
        private var trackingArea: NSTrackingArea?

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

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                self.removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil,
            )
            self.addTrackingArea(area)
            self.trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            self.attachIfPossible()
            self.companion?.sourceHoverChanged(true, token: self.token)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            self.companion?.sourceHoverChanged(false, token: self.token)
        }

        func attachIfPossible() {
            guard self.window != nil, !self.isHiddenOrHasHiddenAncestor, !self.visibleRect.isEmpty else { return }
            self.companion?.attach(anchorView: self, token: self.token, content: self.content)
        }
    }
}

struct HistoryPanelHoverReader: NSViewRepresentable {
    let companion: HistoryCompanionController
    let token: UUID

    func makeNSView(context _: Context) -> TrackingView {
        TrackingView(companion: self.companion, token: self.token)
    }

    func updateNSView(_ view: TrackingView, context _: Context) {
        view.companion = self.companion
        view.token = self.token
    }

    final class TrackingView: NSView {
        weak var companion: HistoryCompanionController?
        var token: UUID
        private var trackingArea: NSTrackingArea?

        init(companion: HistoryCompanionController, token: UUID) {
            self.companion = companion
            self.token = token
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                self.removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil,
            )
            self.addTrackingArea(area)
            self.trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            self.companion?.panelHoverChanged(true, token: self.token)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            self.companion?.panelHoverChanged(false, token: self.token)
        }
    }
}
