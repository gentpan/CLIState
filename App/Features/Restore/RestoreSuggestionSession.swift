import CLIStateAI
import CLIStateApplication
import CLIStateDomain
import Observation
import SwiftUI

/// "What do you mainly develop?" → a checklist of registry tools (Lane N, layer 3).
/// The model only sees the whitelist and the user's own words; its answer is
/// reduced to whitelisted tool IDs, never commands.
@Observable
@MainActor
final class RestoreSuggestionSession {
    enum Phase: Equatable {
        case idle
        case awaitingConsent
        case thinking
        /// The answer named no tool from the whitelist.
        case empty
        case finished
        case failed(AIError)
    }

    var description = ""
    private(set) var phase: Phase = .idle
    private(set) var toolIDs: [ToolID] = []
    private(set) var payloadPreview = ""
    private(set) var configuration: AIConfiguration?
    private var task: Task<Void, Never>?
    private var consented: Set<AIProviderKind> = []

    var profile: EnvironmentProfile? {
        guard phase == .finished, !toolIDs.isEmpty else { return nil }
        return EnvironmentRestore.profile(forTools: toolIDs, name: "AI")
    }

    var canSend: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .thinking
    }

    func suggest(ai: AIModel) {
        guard canSend else { return }
        ai.refreshAvailability()
        let configuration = ai.selectedConfiguration
        self.configuration = configuration
        if let problem = ai.setupProblem(for: configuration) {
            phase = .failed(AIError(problem))
            return
        }
        guard let configuration else { return }
        payloadPreview = RestoreSuggestionPrompt(language: ai.answerLanguage).payloadPreview(description: description, candidates: EnvironmentRestore.candidates)
        if ai.needsConsent(for: configuration), !consented.contains(configuration.provider) {
            phase = .awaitingConsent
        } else {
            send(ai: ai, configuration: configuration)
        }
    }

    func consent(ai: AIModel, dontAskAgain: Bool) {
        guard let configuration else { return }
        consented.insert(configuration.provider)
        if dontAskAgain { ai.setAsksBeforeSending(false, for: configuration.provider) }
        send(ai: ai, configuration: configuration)
    }

    func cancelConsent() {
        if phase == .awaitingConsent { phase = .idle }
    }

    private func send(ai: AIModel, configuration: AIConfiguration) {
        let candidates = EnvironmentRestore.candidates
        let request = RestoreSuggestionPrompt(language: ai.answerLanguage).request(description: description, candidates: candidates)
        let whitelist = Set(candidates.map(\.toolID))
        let client = ai.makeClient(for: configuration)
        task?.cancel()
        phase = .thinking
        task = Task { [weak self] in
            do {
                let answer = try await client.answer(request, limit: 4_000)
                guard let self, !Task.isCancelled else { return }
                let ids = RestoreSuggestionParser.toolIDs(from: answer, whitelist: whitelist)
                self.toolIDs = ids
                self.phase = ids.isEmpty ? .empty : .finished
            } catch {
                guard let self, !Task.isCancelled else { return }
                let failure = AIError.from(error)
                self.phase = failure.kind == .cancelled ? .idle : .failed(failure)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if phase == .thinking { phase = .idle }
    }

    func clear() {
        stop()
        toolIDs = []
        phase = .idle
    }
}
