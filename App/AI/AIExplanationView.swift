import AppKit
import CLIStateAI
import CLIStateDomain
import Observation
import SwiftUI

/// One explanation: consent → streaming → finished / stopped / failed.
@Observable
@MainActor
final class AIExplanationSession {
    enum Phase: Equatable {
        case idle
        /// No provider, or the chosen one isn't ready (missing key, Apple Intelligence off …).
        case needsSetup(AIError)
        case awaitingConsent
        case streaming
        case finished
        case stopped
        case failed(AIError)
    }

    private(set) var phase: Phase = .idle
    private(set) var text = ""
    private(set) var configuration: AIConfiguration?
    private(set) var payloadPreview = ""
    private var request: AIRequest?
    private var task: Task<Void, Never>?
    private var subject: AIExplanationSubject?
    private var homeDirectory = ""
    /// Providers the user already agreed to send to from this window.
    private var consented: Set<AIProviderKind> = []

    var isStreaming: Bool { phase == .streaming }

    /// Builds the request and either asks for consent or starts right away.
    func prepare(subject: AIExplanationSubject, ai: AIModel, homeDirectory: String) {
        self.subject = subject
        self.homeDirectory = homeDirectory
        restart(ai: ai)
    }

    /// Regenerate / Try Again: re-reads Settings, so a fixed key or new provider applies.
    func restart(ai: AIModel) {
        guard let subject else { return }
        cancel()
        ai.refreshAvailability()
        let builder = ai.promptBuilder(homeDirectory: homeDirectory)
        request = builder.request(for: subject)
        payloadPreview = builder.payloadPreview(for: subject)
        configuration = ai.selectedConfiguration
        text = ""
        if let problem = ai.setupProblem(for: configuration) {
            phase = .needsSetup(AIError(problem))
            return
        }
        guard let configuration else { return }
        if ai.needsConsent(for: configuration), !consented.contains(configuration.provider) {
            phase = .awaitingConsent
        } else {
            send(ai: ai)
        }
    }

    func consent(ai: AIModel, dontAskAgain: Bool) {
        guard let provider = configuration?.provider else { return }
        consented.insert(provider)
        if dontAskAgain { ai.setAsksBeforeSending(false, for: provider) }
        send(ai: ai)
    }

    private func send(ai: AIModel) {
        guard let request, let configuration else { return }
        let client = ai.makeClient(for: configuration)
        task?.cancel()
        text = ""
        phase = .streaming
        task = Task { [weak self] in
            do {
                for try await delta in client.streamAnswer(request) {
                    guard let self, !Task.isCancelled else { return }
                    self.text += delta
                }
                guard let self, !Task.isCancelled else { return }
                self.phase = .finished
            } catch {
                guard let self, !Task.isCancelled else { return }
                let failure = AIError.from(error)
                self.phase = failure.kind == .cancelled ? .stopped : .failed(failure)
            }
        }
    }

    func stop() {
        guard phase == .streaming else { return }
        cancel()
        phase = .stopped
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Window content for `WindowGroup(for: AIExplanationTarget.self)`.
struct AIExplanationWindow: View {
    let target: AIExplanationTarget?
    @Environment(AppModel.self) private var model
    @Environment(AIModel.self) private var ai

    var body: some View {
        Group {
            if let target, let subject = subject(for: target) {
                AIExplanationView(subject: subject, target: target)
            } else if model.snapshot == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label { Text("Nothing to explain", tableName: "AI") } icon: { Image(systemName: AISymbol.explain) }
                } description: {
                    Text("This item isn't in the latest scan anymore.", tableName: "AI")
                }
            }
        }
        .frame(minWidth: AILayout.windowMinWidth, minHeight: AILayout.windowMinHeight)
        .background(DS.Palette.background)
        .environment(\.homeDirectory, model.homeDirectory)
    }

    private func subject(for target: AIExplanationTarget) -> AIExplanationSubject? {
        switch target {
        case let .tool(id):
            return model.snapshot?.tool(id).map { .tool($0) }
        case let .issue(id):
            guard let issue = model.snapshot?.issues.first(where: { $0.id == id }) else { return nil }
            return .issue(issue, relatedTool: issue.toolID.flatMap { model.snapshot?.tool($0) })
        }
    }
}

struct AIExplanationView: View {
    let subject: AIExplanationSubject
    let target: AIExplanationTarget
    @Environment(AppModel.self) private var model
    @Environment(AIModel.self) private var ai
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.appearsActive) private var appearsActive
    @State private var session = AIExplanationSession()
    @State private var skipConsentNextTime = false
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(Text(verbatim: title))
        .navigationSubtitle(Text("Explain with AI", tableName: "AI"))
        .buttonStyle(.dsSecondary)
        .tint(DS.Palette.primary)
        .task(id: target) {
            session.prepare(subject: subject, ai: ai, homeDirectory: model.homeDirectory)
        }
        .onDisappear { session.cancel() }
    }

    private var title: String {
        switch subject {
        case let .tool(tool): tool.identity.displayName
        case let .issue(issue, _): issue.text(in: model.snapshot).title
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.s3) {
            if let configuration = session.configuration {
                IconText(symbol: configuration.provider.symbol, text: configuration.label, tint: DS.Palette.textSecondary, textColor: DS.Palette.textSecondary, font: DS.Font.caption)
                    .help(configuration.sendsDataOffDevice
                        ? Text("Answers come from \(configuration.provider.shortName). Only the facts shown before sending leave this Mac.", tableName: "AI")
                        : Text("Answers are generated on this Mac. Nothing leaves it.", tableName: "AI"))
            }
            Spacer(minLength: DS.Space.s2)
            if session.isStreaming {
                Button(role: .cancel) {
                    session.stop()
                } label: {
                    Label { Text("Stop", tableName: "AI") } icon: { Image(systemName: AISymbol.stop) }
                }
                .keyboardShortcut(".", modifiers: .command)
            }
            if !session.text.isEmpty {
                Button {
                    session.copy()
                    didCopy = true
                } label: {
                    Label {
                        didCopy ? Text("Copied", tableName: "AI") : Text("Copy", tableName: "AI")
                    } icon: {
                        Image(systemName: didCopy ? Symbol.latest : AISymbol.copy)
                    }
                }
                .disabled(session.isStreaming)
            }
            if canRegenerate {
                Button {
                    didCopy = false
                    session.restart(ai: ai)
                } label: {
                    Label { Text("Regenerate", tableName: "AI") } icon: { Image(systemName: AISymbol.regenerate) }
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s2)
        .background(DS.Palette.panelPrimary)
    }

    private var canRegenerate: Bool {
        switch session.phase {
        case .finished, .stopped, .failed: true
        default: false
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle:
            Color.clear
        case let .needsSetup(error):
            setupView(error)
        case .awaitingConsent:
            consentView
        case .streaming, .finished, .stopped:
            answerView
        case let .failed(error):
            if session.text.isEmpty {
                failureView(error)
            } else {
                answerView
            }
        }
    }

    private var answerView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s4) {
                    if session.text.isEmpty, session.isStreaming {
                        HStack(spacing: DS.Space.s2) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…", tableName: "AI")
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    AIMarkdownView(text: session.text)
                    if session.phase == .stopped {
                        IconText(symbol: Symbol.cancelled, text: String(localized: "Stopped before the answer was complete.", table: "AI"), font: DS.Font.caption)
                    }
                    if case let .failed(error) = session.phase {
                        errorBanner(error)
                    }
                    if session.phase == .finished {
                        Text("AI answers can be wrong. Check commands before you run them.", tableName: "AI")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                    Color.clear.frame(height: DS.Space.s1).id(bottomID)
                }
                .frame(maxWidth: AILayout.contentMaxWidth, alignment: .leading)
                .padding(DS.Space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .dsScrollBackground()
            .onChange(of: session.text) {
                if session.isStreaming { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    private let bottomID = "bottom"

    private func errorBanner(_ error: AIError) -> some View {
        let text = error.text(provider: session.configuration?.provider)
        return VStack(alignment: .leading, spacing: DS.Space.s1) {
            IconText(symbol: Symbol.needsAttention, text: text.message, tint: DS.Palette.warning, textColor: DS.Palette.textPrimary, font: DS.Font.bodyEmphasis)
            if let hint = text.hint {
                Text(hint)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .dsCard(padding: DS.Space.s3, nested: true)
    }

    private func failureView(_ error: AIError) -> some View {
        let text = error.text(provider: session.configuration?.provider)
        return ScrollView {
            VStack(spacing: DS.Space.s3) {
                Image(systemName: Symbol.needsAttention)
                    .font(DS.Font.largeTitle)
                    .foregroundStyle(DS.Palette.warning)
                    .accessibilityHidden(true)
                Text(text.message)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                if let hint = text.hint {
                    Text(hint)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                if let message = error.providerMessage, !message.isEmpty {
                    Text(verbatim: message)
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .textSelection(.enabled)
                        .dsWell(padding: DS.Space.s2)
                }
                HStack(spacing: DS.Space.s2) {
                    if text.fix == .openSettings {
                        settingsButton
                    }
                    Button {
                        session.restart(ai: ai)
                    } label: {
                        Label { Text("Try Again", tableName: "AI") } icon: { Image(systemName: AISymbol.regenerate) }
                    }
                    .buttonStyle(text.fix == .retry ? .dsPrimary : .dsSecondary)
                }
                .padding(.top, DS.Space.s2)
            }
            .frame(maxWidth: AILayout.windowMinWidth)
            .padding(DS.Space.s8)
            .frame(maxWidth: .infinity)
        }
        .dsScrollBackground()
    }

    private func setupView(_ error: AIError) -> some View {
        let text = error.text(provider: session.configuration?.provider)
        return VStack(spacing: DS.Space.s3) {
            Image(systemName: AISymbol.explain)
                .font(DS.Font.largeTitle)
                .foregroundStyle(DS.Palette.highlight)
                .accessibilityHidden(true)
            Text(error.kind == .notConfigured ? String(localized: "Set up AI explanations", table: "AI") : text.message)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(error.kind == .notConfigured
                ? String(localized: "Use Apple Intelligence on this Mac, or add an API key for OpenAI, DeepSeek or another OpenAI-compatible provider.", table: "AI")
                : (text.hint ?? ""))
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                ai.openSettings(openSettings)
            } label: {
                Label { Text("Set Up AI…", tableName: "AI") } icon: { Image(systemName: AISymbol.settings) }
            }
            .buttonStyle(.dsPrimary)
            .padding(.top, DS.Space.s2)
        }
        .frame(maxWidth: AILayout.windowMinWidth)
        .padding(DS.Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Coming back from Settings re-checks the key, provider and Apple Intelligence.
        .onChange(of: ai.settings) { retryIfSetupChanged() }
        .onChange(of: ai.providersWithKeys) { retryIfSetupChanged() }
        .onChange(of: appearsActive) { retryIfSetupChanged() }
    }

    private func retryIfSetupChanged() {
        if case .needsSetup = session.phase { session.restart(ai: ai) }
    }

    private var settingsButton: some View {
        Button {
            ai.openSettings(openSettings)
        } label: {
            Label { Text("Open AI Settings", tableName: "AI") } icon: { Image(systemName: AISymbol.settings) }
        }
        .buttonStyle(.dsPrimary)
    }

    // MARK: Consent

    private var consentView: some View {
        let provider = session.configuration?.provider ?? .openAI
        return VStack(alignment: .leading, spacing: DS.Space.s4) {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                IconText(symbol: AISymbol.privacy, text: String(localized: "Send to \(provider.shortName)?", table: "AI"), tint: DS.Palette.highlight, textColor: DS.Palette.textPrimary, font: DS.Font.headline)
                Text("CLI State will send exactly the text below. Your home folder and account name are replaced, and it never includes environment variables, shell history, aliases or file contents.", tableName: "AI")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Text(verbatim: session.payloadPreview)
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .dsWell(padding: DS.Space.s3)

            HStack(spacing: DS.Space.s2) {
                Toggle(isOn: $skipConsentNextTime) {
                    Text("Don't ask again for \(provider.shortName)", tableName: "AI")
                        .font(DS.Font.body)
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: DS.Space.s2)
                Button {
                    dismissWindow()
                } label: {
                    Text("Cancel", tableName: "AI")
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    session.consent(ai: ai, dontAskAgain: skipConsentNextTime)
                } label: {
                    Label { Text("Send", tableName: "AI") } icon: { Image(systemName: AISymbol.send) }
                }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.s6)
    }
}
