import SwiftUI

/// A plain icon and title, shared by every primary navigation destination.
private struct DSPageTitle: ViewModifier {
    let title: Text
    let symbol: String
    let count: Int?

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
                if let count {
                    Text(count, format: .number)
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
    }
}

extension View {
    func dsPageTitle(_ title: Text, symbol: String, count: Int? = nil) -> some View {
        modifier(DSPageTitle(title: title, symbol: symbol, count: count))
    }
}
