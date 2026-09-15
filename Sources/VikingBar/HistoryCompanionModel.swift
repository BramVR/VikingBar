import AppKit
import VikingBarCore

enum HistoryMainDayStatus {
    static func text(for day: HistoryDayPresentation) -> String {
        if day.isMissing {
            return "Missing"
        }
        let qualifiers = [(day.isStale, "Stale"), (day.isPartial, "Partial")].compactMap { included, label in
            included ? label : nil
        }
        if !qualifiers.isEmpty {
            return qualifiers.joined(separator: " · ")
        }
        return day.bytes == 0 ? "Confirmed zero" : "Confirmed"
    }
}

struct HistoryPlotSelection: Equatable {
    let index: Int
    let dayStart: Date

    static func at(horizontalPosition: CGFloat, width: CGFloat, dayStarts: [Date]) -> Self? {
        guard width > 0, !dayStarts.isEmpty else { return nil }
        let fraction = min(max(horizontalPosition / width, 0), 0.999_999)
        let index = min(Int(fraction * CGFloat(dayStarts.count)), dayStarts.count - 1)
        return Self(index: index, dayStart: dayStarts[index])
    }
}

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
    private(set) var isDetailOpen = false

    mutating func openDetail() {
        self.isDetailOpen = true
    }

    mutating func closeDetail() {
        self.isDetailOpen = false
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
        self.closeDetail()
    }

    mutating func reset() {
        self.closeDetail()
    }
}
