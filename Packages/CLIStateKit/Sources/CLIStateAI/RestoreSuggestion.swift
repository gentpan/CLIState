import CLIStateDomain
import Foundation

/// "What do you mainly develop?" → registry tool IDs (Lane N, layer 3). The model
/// only picks from a whitelist it is given; the answer is parsed tolerantly and
/// anything outside the whitelist is dropped. AI never produces commands: the
/// App turns the IDs into a checklist the user edits, and installs go through
/// the normal plan and confirmation flow.
public struct RestoreSuggestionPrompt: Sendable {
    /// Keeps the answer small and the checklist reviewable.
    public static let maxSuggestions = 20
    /// Longest description accepted from the user, in characters.
    public static let maxDescriptionLength = 500

    public var language: AIAnswerLanguage

    public init(language: AIAnswerLanguage) {
        self.language = language
    }

    /// `description` is the user's own words; nothing about this Mac is added.
    public func request(description: String, candidates: [RestoreCandidate]) -> AIRequest {
        AIRequest(instructions: instructions(candidates: candidates), prompt: prompt(description: description), language: language)
    }

    /// Exactly the text that is sent, for the consent preview.
    public func payloadPreview(description: String, candidates: [RestoreCandidate]) -> String {
        let request = request(description: description, candidates: candidates)
        return request.instructions + "\n\n" + request.prompt
    }

    func instructions(candidates: [RestoreCandidate]) -> String {
        let catalog = candidates.map { "- \($0.toolID.rawValue): \($0.displayName) — \($0.summary)" }.joined(separator: "\n")
        return """
        You help a developer set up a new Mac inside CLIState, a Mac app that installs command-line tools with package managers.
        From the catalog below, choose the tools that fit what the developer describes.

        Rules:
        - Choose only IDs that appear in the catalog, spelled exactly as written. Never invent IDs, package names or commands.
        - Choose between 3 and \(Self.maxSuggestions) tools, most important first. Include the language runtime and package manager the work needs.
        - Answer with JSON only, no prose and no code fence: {"tools": ["id", "id"]}

        Catalog (id: name — description):
        \(catalog)
        """
    }

    func prompt(description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return "What I mainly develop: \(String(trimmed.prefix(Self.maxDescriptionLength)))"
    }
}

public enum RestoreSuggestionParser {
    /// Registry IDs from a model answer, in answer order, de-duplicated, limited to
    /// `whitelist`. Accepts `{"tools": [...]}`, a bare array, objects with an `id`,
    /// code fences and surrounding prose; falls back to quoted IDs in the text.
    public static func toolIDs(from answer: String, whitelist: Set<ToolID>, limit: Int = RestoreSuggestionPrompt.maxSuggestions) -> [ToolID] {
        let byLowercase = Dictionary(whitelist.map { ($0.rawValue.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let raw = jsonStrings(in: answer) ?? quotedStrings(in: answer)
        var seen = Set<ToolID>()
        var result: [ToolID] = []
        for value in raw {
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let id = byLowercase[key], seen.insert(id).inserted else { continue }
            result.append(id)
            if result.count == limit { break }
        }
        return result
    }

    /// Strings from the first JSON object or array found in the text.
    static func jsonStrings(in text: String) -> [String]? {
        for candidate in jsonCandidates(in: text) {
            guard let data = candidate.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { continue }
            let strings = extract(value)
            if !strings.isEmpty { return strings }
        }
        return nil
    }

    private static func jsonCandidates(in text: String) -> [String] {
        var candidates: [String] = []
        let unfenced = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        for (open, close) in [("{", "}"), ("[", "]")] {
            if let start = unfenced.firstIndex(of: Character(open)), let end = unfenced.lastIndex(of: Character(close)), start < end {
                candidates.append(String(unfenced[start...end]))
            }
        }
        return candidates
    }

    private static func extract(_ value: Any) -> [String] {
        switch value {
        case let string as String:
            return [string]
        case let array as [Any]:
            return array.flatMap(extract)
        case let object as [String: Any]:
            for key in ["tools", "toolIDs", "tool_ids", "ids", "items", "suggestions"] {
                if let nested = object[key] { return extract(nested) }
            }
            for key in ["id", "toolID", "tool"] {
                if let id = object[key] as? String { return [id] }
            }
            return []
        default:
            return []
        }
    }

    private static func quotedStrings(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"["'`]([A-Za-z0-9][A-Za-z0-9._-]*)["'`]"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
