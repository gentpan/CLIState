import AppKit
import CLIStateAI
import CLIStateApplication
import CLIStateDomain
import SwiftUI

// MARK: - Import from file

struct RestoreImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(RestoreModel.self) private var restore

    var body: some View {
        if let source = restore.importedSource {
            RestoreSourcePage(source: source) {
                header(source)
            }
        } else {
            EmptyStateView(LocalizedStringKey(String(localized: "Open an Environment Profile", table: "Restore")), symbol: RestoreSymbol.importFile, message: String(localized: "Choose a .clistate-profile.json file saved on another Mac. CLI State compares it with this Mac before anything is installed.", table: "Restore")) {
                Button {
                    restore.openProfile(model: model)
                } label: {
                    Text("Open Profile…", tableName: "Restore")
                }
                .buttonStyle(.dsPrimary)
            }
        }
    }

    private func header(_ source: RestoreSource) -> some View {
        let profile = source.profile
        return HStack(alignment: .top, spacing: DS.Space.s3) {
            Image(systemName: RestoreSymbol.file)
                .font(DS.Font.standaloneIcon)
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: DS.IconSize.standalone, height: DS.IconSize.standalone)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(verbatim: profile.name ?? fileName(source))
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Palette.textPrimary)
                if let note = profile.note {
                    Text(verbatim: note)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Text(verbatim: details(source))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                if profile.isNewerSchema {
                    IconText(symbol: Symbol.needsAttention, text: String(localized: "Saved by a newer CLI State. Items this version doesn't understand are shown as Can't Install.", table: "Restore"), tint: DS.Palette.warning, textColor: DS.Palette.textPrimary, font: DS.Font.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                restore.openProfile(model: model)
            } label: {
                Text("Open Another…", tableName: "Restore")
            }
            .controlSize(.small)
        }
        .dsCard()
    }

    private func fileName(_ source: RestoreSource) -> String {
        if case let .file(name) = source.kind { return name }
        return ""
    }

    private func details(_ source: RestoreSource) -> String {
        let profile = source.profile
        var parts = [fileName(source)]
        if let summary = profile.source?.summary { parts.append(summary) }
        if profile.createdAt.timeIntervalSince1970 > 0 {
            parts.append(profile.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        let count = profile.items.count
        parts.append(String(localized: "\(count) packages", table: "Restore"))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Templates and AI

struct RestoreTemplatesView: View {
    @Environment(AppModel.self) private var model
    @Environment(RestoreModel.self) private var restore

    var body: some View {
        let source = restore.activeTemplatesSource
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s4) {
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        Text("Start from a template", tableName: "Restore")
                            .font(DS.Font.title)
                            .foregroundStyle(DS.Palette.textPrimary)
                        Text("Curated sets of well-known tools. Pick one, review the checklist, then install what's missing.", tableName: "Restore")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: RestoreLayout.templateCardMinWidth), spacing: DS.Space.s3, alignment: .top)], alignment: .leading, spacing: DS.Space.s3) {
                        ForEach(EnvironmentRestore.templates) { template in
                            TemplateCard(template: template, isSelected: source?.kind == .template(template.id))
                        }
                    }
                    RestoreSuggestionCard()
                        .id(Self.suggestionAnchor)
                    if let source {
                        RestoreDiffSections(source: source)
                    }
                }
                .padding(DS.Space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: restore.suggestion.phase) { _, phase in
                guard phase == .finished else { return }
                restore.showsSuggestion = true
                // The checklist appears below the templates; bring it into view.
                withAnimation(DS.Motion.standard) { proxy.scrollTo(Self.suggestionAnchor, anchor: .top) }
            }
            }
            if let source {
                Divider()
                RestoreInstallBar(source: source)
            }
        }
    }

    private static let suggestionAnchor = "suggestion"
}

private struct TemplateCard: View {
    let template: EnvironmentTemplate
    let isSelected: Bool
    @Environment(RestoreModel.self) private var restore

    var body: some View {
        Button {
            restore.selectedTemplateID = template.id
            restore.showsSuggestion = false
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: RestoreSymbol.template(template.id))
                        .font(DS.Font.standaloneIcon)
                        .foregroundStyle(isSelected ? DS.Palette.highlight : DS.Palette.textSecondary)
                        .frame(width: DS.IconSize.standalone, height: DS.IconSize.standalone)
                        .accessibilityHidden(true)
                    Text(verbatim: RestoreText.templateTitle(template.id))
                        .font(DS.Font.headline)
                        .foregroundStyle(DS.Palette.textPrimary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: Symbol.latest)
                            .font(DS.Font.inlineIcon)
                            .foregroundStyle(DS.Palette.highlight)
                            .accessibilityHidden(true)
                    }
                }
                Text(verbatim: RestoreText.templateSummary(template.id))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let count = template.items.count
                Text("\(count) packages", tableName: "Restore")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(DS.Space.s4)
            .background(isSelected ? DS.Palette.panelSecondary : DS.Palette.panelPrimary, in: RoundedRectangle(cornerRadius: DS.Radius.large))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.large).strokeBorder(isSelected ? DS.Palette.primary : DS.Palette.border, lineWidth: DS.Stroke.hairline))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.large))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct RestoreSuggestionCard: View {
    @Environment(RestoreModel.self) private var restore
    @Environment(AIModel.self) private var ai
    @Environment(\.openSettings) private var openSettings
    @State private var dontAskAgain = false

    var body: some View {
        @Bindable var session = restore.suggestion
        let problem = ai.setupProblem(for: ai.selectedConfiguration)
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s2) {
                IconText(symbol: RestoreSymbol.ai, text: String(localized: "AI Suggestion", table: "Restore"), tint: DS.Palette.highlight, textColor: DS.Palette.textPrimary, font: DS.Font.headline)
                Spacer()
                if problem == nil, let configuration = ai.selectedConfiguration {
                    IconText(symbol: configuration.provider.symbol, text: configuration.label, font: DS.Font.caption)
                }
            }
            Text("What do you mainly develop?", tableName: "Restore")
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.textPrimary)
            HStack(alignment: .top, spacing: DS.Space.s2) {
                TextField(text: $session.description, prompt: Text("For example: a React front end and a Go API with PostgreSQL", tableName: "Restore"), axis: .vertical) {
                    Text("What do you mainly develop?", tableName: "Restore")
                }
                .lineLimit(2...4)
                .textFieldStyle(.dsField)
                .disabled(problem != nil)
                .onSubmit { session.suggest(ai: ai) }
                if session.phase == .thinking {
                    Button {
                        session.stop()
                    } label: {
                        Text("Stop", tableName: "Restore")
                    }
                } else {
                    Button {
                        session.suggest(ai: ai)
                    } label: {
                        Label {
                            Text("Suggest", tableName: "Restore")
                        } icon: {
                            Image(systemName: RestoreSymbol.ai)
                        }
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(problem != nil || !session.canSend)
                }
            }

            if problem != nil {
                HStack(spacing: DS.Space.s2) {
                    IconText(symbol: Symbol.info, text: String(localized: "Set up AI in Settings › AI to get suggestions.", table: "Restore"), font: DS.Font.caption)
                    Spacer()
                    Button {
                        ai.openSettings(openSettings)
                    } label: {
                        Text("Open AI Settings…", tableName: "Restore")
                    }
                    .controlSize(.small)
                }
            } else {
                phaseView(session)
            }

            Text("AI only picks from CLI State's list of known tools. It never writes commands, and nothing is installed until you review the checklist and confirm.", tableName: "Restore")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsCard()
    }

    @ViewBuilder
    private func phaseView(_ session: RestoreSuggestionSession) -> some View {
        switch session.phase {
        case .idle:
            EmptyView()
        case .thinking:
            HStack(spacing: DS.Space.s2) {
                ProgressView().controlSize(.small)
                Text("Thinking…", tableName: "Restore")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        case .awaitingConsent:
            consent(session)
        case .empty:
            IconText(symbol: Symbol.needsAttention, text: String(localized: "The answer didn't name any tool CLI State can install. Try describing your work differently.", table: "Restore"), tint: DS.Palette.warning, textColor: DS.Palette.textPrimary, font: DS.Font.caption)
        case .finished:
            let count = session.toolIDs.count
            HStack(spacing: DS.Space.s2) {
                IconText(symbol: Symbol.latest, text: String(localized: "Suggested \(count) tools. Review the checklist below.", table: "Restore"), tint: DS.Palette.success, textColor: DS.Palette.textPrimary, font: DS.Font.caption)
                Spacer()
                if !restore.showsSuggestion {
                    Button {
                        restore.showsSuggestion = true
                    } label: {
                        Text("Show Suggestion", tableName: "Restore")
                    }
                    .controlSize(.small)
                }
            }
        case let .failed(error):
            let text = error.text(provider: session.configuration?.provider)
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                IconText(symbol: Symbol.needsAttention, text: text.message, tint: DS.Palette.warning, textColor: DS.Palette.textPrimary, font: DS.Font.caption)
                if let hint = text.hint {
                    Text(verbatim: hint)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
    }

    private func consent(_ session: RestoreSuggestionSession) -> some View {
        let name = session.configuration?.provider.shortName ?? ""
        return VStack(alignment: .leading, spacing: DS.Space.s2) {
            IconText(symbol: AISymbol.privacy, text: String(localized: "Send to \(name)?", table: "Restore"), tint: DS.Palette.highlight, textColor: DS.Palette.textPrimary, font: DS.Font.bodyEmphasis)
            Text("Only your description and CLI State's list of known tools are sent. Nothing about this Mac is included.", tableName: "Restore")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
            DisclosureGroup {
                ScrollView {
                    Text(verbatim: session.payloadPreview)
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: RestoreLayout.payloadMaxHeight)
                .dsWell(padding: DS.Space.s2)
            } label: {
                Text("Show exactly what's sent", tableName: "Restore")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            HStack(spacing: DS.Space.s2) {
                Toggle(isOn: $dontAskAgain) {
                    Text("Don't ask again for \(name)", tableName: "Restore")
                        .font(DS.Font.caption)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Button {
                    session.cancelConsent()
                } label: {
                    Text("Cancel", tableName: "Restore")
                }
                .controlSize(.small)
                Button {
                    session.consent(ai: ai, dontAskAgain: dontAskAgain)
                } label: {
                    Text("Send", tableName: "Restore")
                }
                .buttonStyle(.dsPrimary)
                .controlSize(.small)
            }
        }
        .dsCard(padding: DS.Space.s3, nested: true)
    }
}
