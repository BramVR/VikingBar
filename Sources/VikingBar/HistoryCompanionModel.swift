import AppKit

enum HistoryCompanionPlacement {
    static func frame(parent: CGRect, contentSize: CGSize, visibleFrames: [CGRect]) -> CGRect {
        guard let visible = visibleFrames.max(by: {
            Self.area($0.intersection(parent)) < Self.area($1.intersection(parent))
        }) else { return CGRect(origin: parent.origin, size: contentSize) }
        let gap: CGFloat = 8
        let minimumReadableWidth: CGFloat = 300
        let leftSpace = parent.minX - visible.minX - gap
        let rightSpace = visible.maxX - parent.maxX - gap
        if max(leftSpace, rightSpace) < minimumReadableWidth {
            let size = CGSize(
                width: min(contentSize.width, visible.width),
                height: min(contentSize.height, visible.height),
            )
            let originX = min(max(parent.midX - size.width / 2, visible.minX), visible.maxX - size.width)
            let originY = min(max(parent.midY - size.height / 2, visible.minY), visible.maxY - size.height)
            return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
        }
        let useLeft = leftSpace >= contentSize.width || leftSpace >= rightSpace
        let sideSpace = max(0, useLeft ? leftSpace : rightSpace)
        let size = CGSize(
            width: min(contentSize.width, sideSpace),
            height: min(contentSize.height, visible.height),
        )
        let originX = useLeft ? parent.minX - gap - size.width : parent.maxX + gap
        let originY = min(max(parent.maxY - size.height, visible.minY), visible.maxY - size.height)
        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}

struct HistoryCompanionInteractionState {
    private(set) var activeAnchor: UUID?
    private(set) var sourceHovered = false
    private(set) var panelHovered = false
    private(set) var keyboardOpen = false
    private(set) var waitsForSourceExit = false

    var shouldRemainOpen: Bool {
        self.sourceHovered || self.panelHovered || self.keyboardOpen
    }

    mutating func attach(_ token: UUID) -> Bool {
        guard self.activeAnchor == nil else { return false }
        self.reset()
        self.activeAnchor = token
        return true
    }

    mutating func detach(_ token: UUID) -> Bool {
        guard self.activeAnchor == token else { return false }
        self.activeAnchor = nil
        self.reset()
        return true
    }

    mutating func contextChanged() {
        self.waitsForSourceExit = self.sourceHovered
        self.sourceHovered = false
        self.panelHovered = false
        self.keyboardOpen = false
    }

    mutating func sourceHoverChanged(_ inside: Bool, token: UUID) -> Bool {
        guard self.activeAnchor == token else { return false }
        if !inside {
            self.sourceHovered = false
            self.waitsForSourceExit = false
            return true
        }
        guard !self.waitsForSourceExit else { return false }
        self.sourceHovered = true
        return true
    }

    mutating func panelHoverChanged(_ inside: Bool) {
        self.panelHovered = inside
    }

    mutating func activate(keyboard: Bool) {
        self.waitsForSourceExit = false
        self.keyboardOpen = keyboard
    }

    mutating func keyboardFocusChanged(_ focused: Bool) {
        if !focused {
            self.keyboardOpen = false
        }
    }

    mutating func panelDismissed() {
        self.panelHovered = false
    }

    mutating func reset() {
        self.sourceHovered = false
        self.panelHovered = false
        self.keyboardOpen = false
        self.waitsForSourceExit = false
    }
}
