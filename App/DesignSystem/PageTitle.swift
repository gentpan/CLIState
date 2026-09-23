import SwiftUI

/// A plain icon and title, shared by every primary navigation destination.
private struct DSPageTitle: ViewModifier {
    let title: Text
    let symbol: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Spacer().frame(maxWidth: .infinity)
                }
                if #available(macOS 26.0, *) {
                    titleItem.sharedBackgroundVisibility(.hidden)
                } else {
                    titleItem
                }
            }
    }

    private var titleItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: symbol)
                    .font(DS.Font.standaloneIcon)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityHidden(true)
                title.font(DS.Font.title)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            .lineLimit(1)
            .fixedSize()
        }
    }
}

extension View {
    func dsPageTitle(_ title: Text, symbol: String) -> some View {
        modifier(DSPageTitle(title: title, symbol: symbol))
    }
}
