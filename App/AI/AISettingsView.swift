import CLIStateAI
import SwiftUI

/// Settings › AI.
struct AISettingsView: View {
    @Environment(AIModel.self) private var ai

    var body: some View {
        DSForm {
            Section {
                Picker(selection: providerBinding) {
                    Text("Off", tableName: "AI").tag(AIProviderKind?.none)
                    Divider()
                    ForEach(AIProviderKind.allCases, id: \.self) { provider in
                        Text(provider.title).tag(AIProviderKind?.some(provider))
                    }
                } label: {
                    Text("Provider", tableName: "AI")
                }
            } footer: {
                Text("Right-click a tool, or use Explain with AI in its details, to ask what it is and whether you need it.", tableName: "AI")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }

            switch ai.settings.selectedProvider {
            case .appleOnDevice:
                AppleOnDeviceSection()
            case let provider?:
                CloudProviderSections(provider: provider)
                    .id(provider)
            case nil:
                EmptyView()
            }

            Section {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    IconText(symbol: AISymbol.privacy, text: String(localized: "What is sent", table: "AI"), tint: DS.Palette.textSecondary, textColor: DS.Palette.textPrimary, font: DS.Font.bodyEmphasis)
                    Text("Only the tool's name, category, versions, how each copy was installed, package and command names, and paths with your home folder and account name replaced. Never environment variables, shell history, aliases or file contents.", tableName: "AI")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .dsScrollBackground()
        .onAppear { ai.refreshAvailability() }
    }

    private var providerBinding: Binding<AIProviderKind?> {
        Binding(
            get: { ai.settings.selectedProvider },
            set: { value in ai.update { $0.selectedProvider = value } }
        )
    }
}

// MARK: - Apple Intelligence

private struct AppleOnDeviceSection: View {
    @Environment(AIModel.self) private var ai

    var body: some View {
        Section {
            LabeledContent {
                availabilityLabel
            } label: {
                Text("Status", tableName: "AI")
            }
            switch ai.onDeviceAvailability {
            case .available:
                Text("Answers are generated on this Mac. Nothing leaves it, and no API key is needed.", tableName: "AI")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case let .unavailable(reason):
                Text(reason.explanation)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var availabilityLabel: some View {
        let availability = ai.onDeviceAvailability
        return IconText(
            symbol: availability.isAvailable ? Symbol.latest : Symbol.needsAttention,
            text: availability.title,
            tint: availability.isAvailable ? DS.Palette.success : DS.Palette.warning,
            textColor: DS.Palette.textPrimary
        )
    }
}

// MARK: - Cloud and custom providers

private struct CloudProviderSections: View {
    let provider: AIProviderKind
    @Environment(AIModel.self) private var ai
    @State private var keyDraft = ""
    @State private var keyError: AIError?
    @State private var models: [String] = []
    @State private var isFetchingModels = false
    @State private var modelsError: AIError?
    @State private var isTesting = false
    @State private var testResult: Result<Void, AIError>?

    private var configuration: AIConfiguration { ai.settings.configuration(for: provider) }

    var body: some View {
        Section {
            apiKeyRow
            if provider == .openAICompatible {
                baseURLRow
            }
            modelRow
        } header: {
            Text("Connection", tableName: "AI")
        } footer: {
            footer
        }

        Section {
            HStack(spacing: DS.Space.s3) {
                Button {
                    testConnection()
                } label: {
                    Label { Text("Test Connection", tableName: "AI") } icon: { Image(systemName: AISymbol.test) }
                }
                .disabled(isTesting || ai.setupProblem(for: configuration) != nil)
                if isTesting {
                    ProgressView().controlSize(.small)
                }
                testResultLabel
                Spacer(minLength: 0)
            }
            Toggle(isOn: askBinding) {
                Text("Show what will be sent before each explanation", tableName: "AI")
                if !configuration.sendsDataOffDevice {
                    Text("This endpoint runs on this Mac, so CLI State doesn't ask.", tableName: "AI")
                }
            }
            .disabled(!configuration.sendsDataOffDevice)
        }
    }

    // MARK: API key

    @ViewBuilder
    private var apiKeyRow: some View {
        if ai.hasAPIKey(provider) {
            LabeledContent {
                HStack(spacing: DS.Space.s2) {
                    IconText(symbol: Symbol.systemManaged, text: String(localized: "Saved in Keychain", table: "AI"), tint: DS.Palette.success, textColor: DS.Palette.textPrimary)
                    Button(role: .destructive) {
                        do {
                            try ai.removeAPIKey(for: provider)
                            keyError = nil
                            testResult = nil
                        } catch {
                            keyError = AIError.from(error)
                        }
                    } label: {
                        Text("Remove", tableName: "AI")
                    }
                    .controlSize(.small)
                }
            } label: {
                Text("API Key", tableName: "AI")
            }
        } else {
            LabeledContent {
                HStack(spacing: DS.Space.s2) {
                    SecureField(text: $keyDraft, prompt: keyPrompt) {
                        Text("API Key", tableName: "AI")
                    }
                    .labelsHidden()
                    .onSubmit(saveKey)
                    Button(action: saveKey) {
                        Text("Save", tableName: "AI")
                    }
                    .controlSize(.small)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } label: {
                Text("API Key", tableName: "AI")
                if !provider.requiresAPIKey {
                    Text("Optional for local servers", tableName: "AI")
                }
            }
        }
        if let keyError {
            errorText(keyError)
        }
    }

    private var keyPrompt: Text {
        switch provider {
        case .openAI, .deepSeek: Text(verbatim: "sk-…")
        default: Text("Paste your API key", tableName: "AI")
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try ai.saveAPIKey(key, for: provider)
            keyError = nil
            testResult = nil
        } catch {
            keyError = AIError.from(error)
        }
        // The draft never outlives the save attempt.
        keyDraft = ""
    }

    // MARK: Base URL and model

    private var baseURLRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            TextField(text: configurationBinding(\.customBaseURL), prompt: Text(verbatim: "http://localhost:11434/v1")) {
                Text("Base URL", tableName: "AI")
            }
            .autocorrectionDisabled()
            if !configuration.customBaseURL.isEmpty, configuration.baseURL == nil {
                IconText(symbol: Symbol.needsAttention, text: String(localized: "Enter a full URL starting with http:// or https://", table: "AI"), tint: DS.Palette.warning, textColor: DS.Palette.textSecondary, font: DS.Font.caption)
            }
        }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                TextField(text: configurationBinding(\.model), prompt: Text(verbatim: modelPlaceholder)) {
                    Text("Model", tableName: "AI")
                }
                .autocorrectionDisabled()
                if models.isEmpty {
                    Button(action: fetchModels) {
                        Label { Text("Fetch Models", tableName: "AI") } icon: { Image(systemName: AISymbol.models) }
                    }
                    .controlSize(.small)
                    .disabled(isFetchingModels || configuration.baseURL == nil || (provider.requiresAPIKey && !ai.hasAPIKey(provider)))
                } else {
                    Menu {
                        ForEach(models, id: \.self) { model in
                            Button {
                                ai.updateConfiguration(for: provider) { $0.model = model }
                                testResult = nil
                            } label: {
                                Text(verbatim: model)
                            }
                        }
                        Divider()
                        Button(action: fetchModels) {
                            Text("Refresh List", tableName: "AI")
                        }
                    } label: {
                        Label { Text("Models", tableName: "AI") } icon: { Image(systemName: AISymbol.models) }
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                    .fixedSize()
                }
                if isFetchingModels {
                    ProgressView().controlSize(.small)
                }
            }
            if let modelsError {
                errorText(modelsError)
            } else if !models.isEmpty {
                Text("\(models.count) models available", tableName: "AI")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }

    private var modelPlaceholder: String {
        provider.defaultModel.isEmpty ? "llama3.2" : provider.defaultModel
    }

    @ViewBuilder
    private var footer: some View {
        switch provider {
        case .openAI:
            Text("Create a key at platform.openai.com. It's stored in your Keychain and only sent to OpenAI.", tableName: "AI")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
        case .deepSeek:
            Text("Create a key at platform.deepseek.com. It's stored in your Keychain and only sent to DeepSeek.", tableName: "AI")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
        case .openAICompatible:
            Text("Works with any OpenAI-compatible API, such as Ollama, LM Studio, OpenRouter, Kimi or Qwen. The key, if any, is stored in your Keychain.", tableName: "AI")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
        case .appleOnDevice:
            EmptyView()
        }
    }

    // MARK: Actions

    private func fetchModels() {
        isFetchingModels = true
        modelsError = nil
        let client = OpenAICompatibleClient(configuration: configuration, secrets: ai.secrets)
        Task {
            defer { isFetchingModels = false }
            do {
                models = try await client.listModels()
                if models.isEmpty { modelsError = AIError(.emptyResponse) }
            } catch {
                models = []
                modelsError = AIError.from(error)
            }
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let client = ai.makeClient(for: configuration)
        let request = AIRequest.connectionTest(language: ai.answerLanguage)
        Task {
            defer { isTesting = false }
            do {
                _ = try await client.answer(request, limit: 64)
                testResult = .success(())
            } catch {
                testResult = .failure(AIError.from(error))
            }
        }
    }

    @ViewBuilder
    private var testResultLabel: some View {
        switch testResult {
        case .success:
            IconText(symbol: Symbol.latest, text: String(localized: "Connected. The model replied.", table: "AI"), tint: DS.Palette.success, textColor: DS.Palette.textPrimary)
        case let .failure(error):
            IconText(symbol: Symbol.failed, text: error.text(provider: provider).message, tint: DS.Palette.error, textColor: DS.Palette.textPrimary)
                .help(error.text(provider: provider).hint ?? "")
        case nil:
            EmptyView()
        }
    }

    private func errorText(_ error: AIError) -> some View {
        let text = error.text(provider: provider)
        return VStack(alignment: .leading, spacing: 0) {
            IconText(symbol: Symbol.needsAttention, text: text.message, tint: DS.Palette.warning, textColor: DS.Palette.textSecondary, font: DS.Font.caption)
            if let hint = text.hint {
                Text(hint)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Bindings

    private func configurationBinding(_ keyPath: WritableKeyPath<AIConfiguration, String>) -> Binding<String> {
        Binding(
            get: { configuration[keyPath: keyPath] },
            set: { value in
                ai.updateConfiguration(for: provider) { $0[keyPath: keyPath] = value }
                testResult = nil
            }
        )
    }

    private var askBinding: Binding<Bool> {
        Binding(
            get: { configuration.sendsDataOffDevice && ai.asksBeforeSending(provider) },
            set: { ai.setAsksBeforeSending($0, for: provider) }
        )
    }
}
