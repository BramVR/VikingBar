import AppKit
import Observation
import SwiftUI
import VikingBarCore

@MainActor
struct HistoryCompanionContent: Equatable {
    let identity: HistoryContext
    let subscriptionName: String
    let presentation: HistoryPresentation
    let isLoading: Bool
    let error: String?
    let reportedUsedText: String

    init?(session: AppSession) {
        guard let identity = session.liveState.historyContext else { return nil }
        self.identity = identity
        self.subscriptionName = session.liveState.subscriptions
            .first(where: { $0.id == identity.subscriptionID })?.displayName ?? session.snapshot.subscriptionName
        self.presentation = session.historyPresentation
        self.isLoading = session.isHistoryLoading
        self.error = session.historyError
        self.reportedUsedText = session.menu.usedText
    }
}

@MainActor
@Observable
final class HistoryCompanionController {
    private(set) var content: HistoryCompanionContent?
    private(set) var selectedDayStart: Date?

    @ObservationIgnored private weak var anchorView: NSView?
    @ObservationIgnored private weak var parentWindow: NSWindow?
    @ObservationIgnored private var anchorCandidates: [UUID: AnchorCandidate] = [:]
    @ObservationIgnored private var panel: HistoryCompanionPanel?
    @ObservationIgnored private var panelToken: UUID?
    @ObservationIgnored private var hostingController: NSHostingController<HistoryDetailView>?
    @ObservationIgnored private var dismissalTask: Task<Void, Never>?
    @ObservationIgnored private var parentObservers: [NSObjectProtocol] = []
    @ObservationIgnored private(set) var interaction = HistoryCompanionInteractionState()

    func attach(anchorView: NSView, token: UUID, content: HistoryCompanionContent?) {
        guard let parentWindow = anchorView.window else { return }
        self.anchorCandidates[token] = AnchorCandidate(view: anchorView, content: content)
        if self.interaction.activeAnchor != nil, self.interaction.activeAnchor != token {
            guard !Self.isEligible(self.anchorView) else { return }
            self.releaseActiveAnchor()
        }
        if self.interaction.attach(token) {
            self.hidePanel()
        }
        self.anchorView = anchorView
        self.observe(parentWindow)
        self.update(content: content, token: token)
        if self.panel != nil {
            self.attachPanel(to: parentWindow)
            self.positionPanel()
        }
    }

    func update(content: HistoryCompanionContent?, token: UUID) {
        guard self.interaction.activeAnchor == token else { return }
        if self.content?.identity != content?.identity {
            self.interaction.contextChanged()
            self.hidePanel()
            self.selectedDayStart = Self.defaultSelection(in: content)
        } else if let selectedDayStart, content?.presentation.days.contains(where: {
            $0.dayStart == selectedDayStart
        }) != true {
            self.selectedDayStart = Self.defaultSelection(in: content)
        }
        if self.content != content {
            self.content = content
        }
        if content == nil {
            self.hidePanel()
        }
    }

    func detach(token: UUID) {
        self.anchorCandidates[token] = nil
        guard self.interaction.detach(token) else { return }
        self.releaseActiveAnchorState()
        self.attachNextCandidate()
    }

    private func releaseActiveAnchor() {
        if let token = self.interaction.activeAnchor {
            _ = self.interaction.detach(token)
        }
        self.releaseActiveAnchorState()
    }

    private func releaseActiveAnchorState() {
        self.anchorView = nil
        self.content = nil
        self.removeParentObservers()
        self.parentWindow = nil
        self.hidePanel()
    }

    func sourceHoverChanged(_ inside: Bool, token: UUID) {
        guard self.interaction.sourceHoverChanged(inside, token: token) else { return }
        self.hoverChanged(inside: inside)
    }

    func panelHoverChanged(_ inside: Bool, token: UUID) {
        guard self.panelToken == token else { return }
        self.interaction.panelHoverChanged(inside)
        self.hoverChanged(inside: inside)
    }

    func activate() {
        let type = NSApp.currentEvent?.type
        self.interaction.activate(keyboard: type != .leftMouseDown && type != .leftMouseUp)
        self.showPanel()
    }

    func keyboardFocusChanged(_ focused: Bool) {
        if !focused, self.interaction.keyboardOpen {
            self.interaction.keyboardFocusChanged(focused)
            self.scheduleDismissal()
        }
    }

    func moveSelection(_ direction: MoveCommandDirection) {
        guard self.panel != nil, let content else { return }
        let offset = direction == .left ? -1 : (direction == .right ? 1 : 0)
        guard offset != 0, !content.presentation.days.isEmpty else { return }
        let index = content.presentation.days.firstIndex(where: { $0.dayStart == self.selectedDayStart })
            ?? content.presentation.days.count - 1
        let next = min(max(index + offset, 0), content.presentation.days.count - 1)
        self.selectedDayStart = content.presentation.days[next].dayStart
    }

    func select(dayStart: Date?) {
        guard let dayStart, self.content?.presentation.days.contains(where: { $0.dayStart == dayStart }) == true else {
            return
        }
        self.selectedDayStart = dayStart
    }

    func dismiss() {
        self.interaction.reset()
        self.hidePanel()
    }

    static func defaultSelection(in content: HistoryCompanionContent?) -> Date? {
        guard let days = content?.presentation.days else { return nil }
        return days.first(where: \ .isToday)?.dayStart ?? days.last?.dayStart
    }

    private func hoverChanged(inside: Bool) {
        if inside {
            self.dismissalTask?.cancel()
            self.dismissalTask = nil
            self.showPanel()
        } else {
            self.scheduleDismissal()
        }
    }

    private func showPanel() {
        guard let content, let parentWindow = self.anchorView?.window, parentWindow.isVisible else { return }
        if self.selectedDayStart == nil {
            self.selectedDayStart = Self.defaultSelection(in: content)
        }
        if self.panel == nil {
            let panel = HistoryCompanionPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
            panel.setAccessibilityIdentifier("vikingbar.historyPanel")
            let token = UUID()
            let hosting = NSHostingController(rootView: HistoryDetailView(companion: self, panelToken: token))
            panel.contentViewController = hosting
            self.panel = panel
            self.panelToken = token
            self.hostingController = hosting
        }
        self.attachPanel(to: parentWindow)
        self.positionPanel()
        self.panel?.orderFront(nil)
    }

    private func attachPanel(to parentWindow: NSWindow) {
        guard let panel else { return }
        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
    }

    private func positionPanel() {
        guard let panel, let parentWindow, let hostingController else { return }
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        let desired = CGSize(width: 336, height: min(400, max(360, fitting.height)))
        let frame = HistoryCompanionPlacement.frame(
            parent: parentWindow.frame,
            contentSize: desired,
            visibleFrames: NSScreen.screens.map(\ .visibleFrame),
        )
        panel.setFrame(frame, display: true)
    }

    private func scheduleDismissal() {
        guard !self.interaction.shouldRemainOpen else { return }
        self.dismissalTask?.cancel()
        self.dismissalTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !self.interaction.shouldRemainOpen else { return }
            let pointer = NSEvent.mouseLocation
            let pointerOverSource = self.anchorView.map { Self.screenFrame(of: $0).contains(pointer) } == true
            let pointerOverPanel = self.panel?.frame.contains(pointer) == true
            if pointerOverSource || pointerOverPanel {
                return
            }
            self.hidePanel()
        }
    }

    private func hidePanel() {
        self.dismissalTask?.cancel()
        self.dismissalTask = nil
        self.interaction.panelDismissed()
        self.panelToken = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentViewController = nil
        self.hostingController = nil
        self.panel = nil
    }

    private func observe(_ parentWindow: NSWindow) {
        guard self.parentWindow !== parentWindow else { return }
        self.removeParentObservers()
        self.parentWindow = parentWindow
        let center = NotificationCenter.default
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
        ] {
            self.parentObservers.append(center.addObserver(
                forName: name,
                object: parentWindow,
                queue: .main,
            ) { [weak self] _ in
                Task { @MainActor in self?.positionPanel() }
            })
        }
        for name in [NSWindow.willCloseNotification] {
            self.parentObservers.append(center.addObserver(
                forName: name,
                object: parentWindow,
                queue: .main,
            ) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            })
        }
    }

    private func removeParentObservers() {
        for observer in self.parentObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.parentObservers.removeAll()
    }

    private func attachNextCandidate() {
        for (token, candidate) in self.anchorCandidates {
            guard let view = candidate.view else {
                self.anchorCandidates[token] = nil
                continue
            }
            guard Self.isEligible(view) else { continue }
            self.attach(anchorView: view, token: token, content: candidate.content)
            return
        }
    }

    private static func isEligible(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view.window != nil && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
    }

    private static func screenFrame(of view: NSView) -> CGRect {
        guard let window = view.window else { return .null }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private final class AnchorCandidate {
    weak var view: NSView?
    let content: HistoryCompanionContent?

    init(view: NSView, content: HistoryCompanionContent?) {
        self.view = view
        self.content = content
    }
}
