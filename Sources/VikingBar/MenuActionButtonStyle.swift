import AppKit
import SwiftUI

struct MenuActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        MenuActionSurface(
            isEnabled: self.isEnabled,
            isPressed: configuration.isPressed,
            content: configuration.label,
        )
    }
}

extension ButtonStyle where Self == MenuActionButtonStyle {
    static var menuAction: MenuActionButtonStyle {
        MenuActionButtonStyle()
    }
}

private struct MenuActionSurface<Content: View>: View {
    let isEnabled: Bool
    let isPressed: Bool
    let content: Content
    @State private var isPointerInside = false

    private var isHighlighted: Bool {
        self.isEnabled && (self.isPointerInside || self.isPressed)
    }

    var body: some View {
        self.content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(self.foregroundColor)
            .background(self.backgroundColor, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onHover { self.isPointerInside = $0 }
    }

    private var foregroundColor: Color {
        if !self.isEnabled {
            return Color(nsColor: .disabledControlTextColor)
        }
        return Color(nsColor: self.isHighlighted ? .selectedMenuItemTextColor : .controlTextColor)
    }

    private var backgroundColor: Color {
        self.isHighlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear
    }
}
