import SwiftUI

/// Shared selection control for page tabs and short, mutually exclusive choices.
struct DSTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: String
    let label: (Value) -> String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            segments
            ScrollView(.horizontal) { segments }
                .scrollIndicators(.hidden)
        }
        .padding(DS.Space.s1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
    }

    private var segments: some View {
        HStack(spacing: DS.Space.s1) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(verbatim: label(option))
                        .font(DS.Font.body)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, DS.Space.s3)
                        .frame(maxWidth: .infinity, minHeight: DS.ControlHeight.regular)
                }
                .buttonStyle(selection == option ? .dsPrimary : .dsSecondary)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
    }
}

@MainActor
struct DSFieldStyle: @preconcurrency TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        Field(content: configuration)
    }

    private struct Field<Content: View>: View {
        let content: Content
        @FocusState private var focused: Bool
        @Environment(\.isEnabled) private var enabled


        var body: some View {
            content
                .textFieldStyle(.plain)
                .focused($focused)
                .font(DS.Font.body)
                .padding(.horizontal, DS.Space.s3)
                .padding(.vertical, DS.Space.s2)
                .frame(minHeight: DS.ControlHeight.regular)
                .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.base))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.base).strokeBorder(focused ? DS.Palette.highlight : DS.Palette.border, lineWidth: DS.Stroke.hairline))
                .opacity(enabled ? 1 : DS.Opacity.disabled)
        }
    }
}

extension TextFieldStyle where Self == DSFieldStyle {
    @MainActor static var dsField: DSFieldStyle { DSFieldStyle() }
}

/// Settings sections use the same cards and spacing as the main window.
struct DSForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                ForEach(sections: content) { section in
                    VStack(alignment: .leading, spacing: DS.Space.s2) {
                        section.header.font(DS.Font.headline)
                        Form { section.content }
                            .formStyle(.columns)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dsCard()
                        section.footer
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(DS.Space.s4)
        }
        .textFieldStyle(.dsField)
    }
}
