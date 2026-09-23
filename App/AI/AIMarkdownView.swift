import SwiftUI

/// Small block renderer for model answers: headings, bullet and numbered lists,
/// fenced code and paragraphs, with inline Markdown (bold, italics, code, links).
/// Tolerates half-written Markdown while streaming.
struct AIMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            ForEach(Array(AIMarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .tint(DS.Palette.highlight)
    }

    @ViewBuilder
    private func view(for block: AIMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, content):
            Text(Self.inline(content))
                .font(level <= 2 ? DS.Font.headline : DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Palette.textPrimary)
                .padding(.top, level <= 2 ? DS.Space.s2 : 0)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(content):
            Text(Self.inline(content))
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case let .list(items):
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                        Text(verbatim: item.marker)
                            .font(item.marker == "•" ? DS.Font.body : DS.Font.monoBody)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .frame(minWidth: AILayout.bulletWidth, alignment: .trailing)
                            .accessibilityHidden(true)
                        Text(Self.inline(item.content))
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * DS.Space.s4)
                }
            }
        case let .code(content):
            Text(verbatim: content)
                .font(DS.Font.mono)
                .foregroundStyle(DS.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .dsWell(padding: DS.Space.s3)
        case .rule:
            Divider()
        }
    }

    static func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var attributed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = DS.Font.monoBody
            attributed[run.range].foregroundColor = DS.Palette.highlight
        }
        return attributed
    }
}

enum AIMarkdownBlock: Hashable {
    struct ListItem: Hashable {
        var marker: String
        var content: String
        var depth: Int
    }

    case heading(level: Int, String)
    case paragraph(String)
    case list([ListItem])
    case code(String)
    case rule

    static func parse(_ text: String) -> [AIMarkdownBlock] {
        var blocks: [AIMarkdownBlock] = []
        var paragraph: [String] = []
        var items: [ListItem] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph.removeAll()
        }
        func flushList() {
            if !items.isEmpty { blocks.append(.list(items)) }
            items.removeAll()
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    flushList()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                flushList()
                continue
            }
            if let heading = headingLevel(trimmed) {
                flushParagraph()
                flushList()
                blocks.append(.heading(level: heading.level, heading.content))
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                flushList()
                blocks.append(.rule)
                continue
            }
            let depth = (line.count - line.drop { $0 == " " }.count) / 2
            if let item = listItem(trimmed, depth: min(depth, 3)) {
                flushParagraph()
                items.append(item)
                continue
            }
            if !items.isEmpty, depth > 0 {
                // Continuation of the previous list item.
                items[items.count - 1].content += " " + trimmed
                continue
            }
            flushList()
            paragraph.append(trimmed)
        }
        if let open = code, !open.isEmpty { blocks.append(.code(open.joined(separator: "\n"))) }
        flushParagraph()
        flushList()
        return blocks
    }

    private static func headingLevel(_ line: String) -> (level: Int, content: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else {
            // `**Heading**` on its own line, common in small-model output.
            if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4, !line.dropFirst(2).dropLast(2).contains("**") {
                return (3, String(line.dropFirst(2).dropLast(2)))
            }
            return nil
        }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    private static let bullets = ["- ", "* ", "+ ", "• "]

    private static func listItem(_ line: String, depth: Int) -> ListItem? {
        for bullet in bullets where line.hasPrefix(bullet) {
            var content = line.dropFirst(bullet.count).drop { $0 == " " }
            // Small models sometimes write `- - item` or `• - item`.
            while let extra = bullets.first(where: { content.hasPrefix($0) }) {
                content = content.dropFirst(extra.count).drop { $0 == " " }
            }
            return ListItem(marker: "•", content: String(content), depth: depth)
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return ListItem(marker: "\(digits).", content: String(rest.dropFirst(2)), depth: depth)
            }
        }
        return nil
    }
}
