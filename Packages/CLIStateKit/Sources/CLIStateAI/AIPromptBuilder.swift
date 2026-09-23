import CLIStateDomain
import Foundation

/// What the user asked to explain.
public enum AIExplanationSubject: Hashable, Sendable {
    case tool(Tool)
    case issue(HealthIssue, relatedTool: Tool?)
}

/// Headings and terms in the answer language, supplied by the App so answers use
/// the same words as the UI (small on-device models otherwise copy English headings).
public struct AIPromptVocabulary: Hashable, Sendable {
    public var whatItIs: String
    public var whatItsUsedFor: String
    public var whatsInstalled: String
    public var canIRemoveIt: String
    public var nextSteps: String
    public var whatsGoingOn: String
    public var whyItMatters: String
    public var howToFixIt: String
    /// English term → UI term, e.g. `active` → `生效中`.
    public var terms: [String: String]

    public init(whatItIs: String, whatItsUsedFor: String, whatsInstalled: String, canIRemoveIt: String, nextSteps: String, whatsGoingOn: String, whyItMatters: String, howToFixIt: String, terms: [String: String] = [:]) {
        self.whatItIs = whatItIs
        self.whatItsUsedFor = whatItsUsedFor
        self.whatsInstalled = whatsInstalled
        self.canIRemoveIt = canIRemoveIt
        self.nextSteps = nextSteps
        self.whatsGoingOn = whatsGoingOn
        self.whyItMatters = whyItMatters
        self.howToFixIt = howToFixIt
        self.terms = terms
    }

    public static let english = AIPromptVocabulary(
        whatItIs: "What it is",
        whatItsUsedFor: "What it's used for",
        whatsInstalled: "What's installed on this Mac",
        canIRemoveIt: "Can I remove it?",
        nextSteps: "Next steps",
        whatsGoingOn: "What's going on",
        whyItMatters: "Why it matters",
        howToFixIt: "How to fix it"
    )
}

/// Builds the request for an explanation. Privacy (plan §9): only names, categories,
/// versions, providers, confidence, link state, package and command names, and
/// paths with the home folder and account name removed. Never environment or
/// shell variables, aliases, history, command output or file contents.
public struct AIPromptBuilder: Sendable {
    /// Keeps prompts inside the on-device model's small context window.
    static let maxInstallations = 6
    static let maxExecutablesPerInstallation = 4
    static let maxListItems = 8
    static let maxPaths = 6
    /// Issue detail keys whose values are safe facts. `reason` (command output) and
    /// `detail` (alias/function bodies) are deliberately left out.
    static let issueDetailAllowlist: Set<String> = ["providers", "provider", "versions", "architectures", "host", "runtime", "exitCode", "status", "destination"]

    public var homeDirectory: String
    public var userName: String
    public var language: AIAnswerLanguage
    public var vocabulary: AIPromptVocabulary

    public init(homeDirectory: String, userName: String, language: AIAnswerLanguage, vocabulary: AIPromptVocabulary = .english) {
        self.homeDirectory = homeDirectory
        self.userName = userName
        self.language = language
        self.vocabulary = vocabulary
    }

    public func request(for subject: AIExplanationSubject) -> AIRequest {
        AIRequest(instructions: instructions(for: subject), prompt: prompt(for: subject), language: language)
    }

    /// Exactly the text that is sent: instructions, a blank line, then the message.
    public func payloadPreview(for subject: AIExplanationSubject) -> String {
        let request = request(for: subject)
        return request.instructions + "\n\n" + request.prompt
    }

    // MARK: Instructions

    func instructions(for subject: AIExplanationSubject) -> String {
        let words = vocabulary
        let sections: [(heading: String, guidance: String)] = switch subject {
        case .tool: [
            (words.whatItIs, "one or two sentences"),
            (words.whatItsUsedFor, "typical uses, as a short bullet list"),
            (words.whatsInstalled, "one bullet per installation: how it was installed, its version, and whether it is the one Terminal runs (active) or hidden behind another one (shadowed)"),
            (words.canIRemoveIt, "whether removing it is safe, which installation to keep, and what depends on it"),
            (words.nextSteps, "at most three concrete actions"),
        ]
        case .issue: [
            (words.whatsGoingOn, "explain the problem in plain words"),
            (words.whyItMatters, "what the user might notice"),
            (words.howToFixIt, "at most three concrete steps, safest first"),
        ]
        }
        let outline = sections.map { "## \($0.heading)\n(\($0.guidance))" }.joined(separator: "\n")
        var rules = [
            "Write the whole answer in \(language.promptName). Keep commands, package names and paths as they are.",
            "Use exactly the headings below, in this order, without numbers. Under them use short paragraphs and simple bullet lists (one \"- \" per line). No tables. Put commands and paths in `code spans`.",
            "Keep it under 300 words.",
            "Rely on the facts given plus well-known public knowledge. If you're not sure what the tool is, say so instead of guessing.",
            "Prefer the package manager that owns an installation (for example `brew uninstall`, `npm uninstall -g`). Never suggest sudo, deleting system files, or editing files under /System or /usr.",
            "\"~\" is the user's home folder and \"<user>\" is their account name; don't ask about them.",
        ]
        if !words.terms.isEmpty {
            rules.append("When a fact names a term used \"in the app\", use the app's word instead of the English one.")
        }
        return """
        You are the assistant inside CLIState, a Mac app that shows which command-line tools are installed, how they were installed, and which binary Terminal actually runs.
        Explain the item below to a developer who doesn't recognise it.

        Rules:
        \(rules.map { "- " + $0 }.joined(separator: "\n"))

        Answer outline:
        \(outline)
        """
    }

    // MARK: Messages

    func prompt(for subject: AIExplanationSubject) -> String {
        let text = switch subject {
        case let .tool(tool): toolFacts(tool, heading: "Tool")
        case let .issue(issue, relatedTool): issueFacts(issue, relatedTool: relatedTool)
        }
        return redact(text)
    }

    private func toolFacts(_ tool: Tool, heading: String) -> String {
        var lines: [String] = []
        lines.append("\(heading): \(tool.identity.displayName)")
        if tool.identity.name != tool.identity.displayName {
            lines.append("Name: \(tool.identity.name)")
        }
        lines.append("Category: \(Self.categoryName(tool.identity.category))")
        if let summary = tool.identity.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("Known description: \(summary)")
        }
        if let host = tool.identity.homepage?.host() {
            lines.append("Homepage: \(host)")
        }
        if let resolution = tool.resolution {
            lines.append("Command: \(resolution.command)")
            if let first = resolution.chain.first {
                lines.append("Terminal runs: \(first.path)")
            }
            if resolution.chain.count > 1 {
                lines.append("Other matches in PATH: " + resolution.chain.dropFirst().prefix(Self.maxPaths).map(\.path).joined(separator: ", "))
            }
            if !resolution.shadows.isEmpty {
                // Kinds only: alias and function bodies can contain anything.
                let kinds = Set(resolution.shadows.map(\.kind.rawValue)).sorted()
                lines.append("Shell definitions with the same name run first: " + kinds.joined(separator: ", "))
            }
        }

        let installations = tool.installations.prefix(Self.maxInstallations)
        lines.append("")
        lines.append("Installations (\(tool.installations.count)):")
        for (index, installation) in installations.enumerated() {
            lines.append(contentsOf: installationFacts(installation, number: index + 1, isActive: installation.id == tool.activeInstallationID))
        }
        if tool.installations.count > installations.count {
            lines.append("- … \(tool.installations.count - installations.count) more not listed")
        }
        return lines.joined(separator: "\n")
    }

    private func installationFacts(_ installation: ToolInstallation, number: Int, isActive: Bool) -> [String] {
        var lines = ["\(number). Installed via \(installation.ownership.provider.rawValue)"]
        func add(_ key: String, _ value: String) { lines.append("   - \(key): \(value)") }
        if let package = installation.ownership.packageName { add("Package", package) }
        add("Version", installation.version?.value.rawValue ?? "unknown")
        if installation.hasUpdate, let latest = installation.latest?.value.rawValue {
            add("Newer version available", latest)
        }
        add("How sure CLI State is about the installer", installation.ownership.confidence.rawValue)
        add("Link state", term(Self.linkStateKey(installation.linkState), description: Self.linkStateName(installation.linkState)) + (isActive ? ", this is the one Terminal runs" : ""))
        if installation.isSystemManaged { add("Ships with macOS", "yes") }
        if let isDirect = installation.isDirect { add("Installed on request", isDirect ? "yes" : "no, as a dependency") }
        let commands = installation.executables.map(\.name).uniqued()
        if !commands.isEmpty { add("Commands", commands.prefix(Self.maxListItems).joined(separator: ", ")) }
        for executable in installation.executables.prefix(Self.maxExecutablesPerInstallation) {
            var path = executable.path
            if let resolved = executable.resolvedPath, resolved != executable.path { path += " -> \(resolved)" }
            if let architecture = executable.architecture { path += " (\(architecture.rawValue))" }
            add("Executable", path)
        }
        if let prefix = installation.installPrefix { add("Install location", prefix) }
        if !installation.dependents.isEmpty {
            add("Needed by", Self.list(installation.dependents))
        }
        if !installation.dependencies.isEmpty {
            add("Depends on", Self.list(installation.dependencies))
        }
        return lines
    }

    private func issueFacts(_ issue: HealthIssue, relatedTool: Tool?) -> String {
        var lines: [String] = []
        lines.append("Issue type: \(issue.type.rawValue) (\(Self.issueTypeDescription(issue.type)))")
        lines.append("Severity: \(issue.severity.rawValue)")
        lines.append("Subject: \(issue.subject)")
        for key in issue.details.keys.sorted() where Self.issueDetailAllowlist.contains(key) {
            if let value = issue.details[key], !value.isEmpty { lines.append("\(key): \(value)") }
        }
        if !issue.paths.isEmpty {
            lines.append("Paths: " + issue.paths.prefix(Self.maxPaths).joined(separator: ", "))
        }
        if let relatedTool {
            lines.append("")
            lines.append(toolFacts(relatedTool, heading: "Related tool"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Redaction

    /// Home folder → `~`, account name → `<user>`, other `/Users/<name>` → `/Users/<user>`.
    func redact(_ text: String) -> String {
        var output = text
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if !home.isEmpty {
            // Whole path component only: `/Users/pete` must not eat `/Users/peter`.
            output = Self.replace("\(NSRegularExpression.escapedPattern(for: home))(?![^/\\s,)])", in: output, with: "~")
        }
        output = Self.replace("/Users/(?!Shared(?![^/\\s,)]))[^/\\s,)]+", in: output, with: "/Users/<user>")
        let user = userName.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty {
            output = Self.replace("(?<![A-Za-z0-9._-])\(NSRegularExpression.escapedPattern(for: user))(?![A-Za-z0-9._-])", in: output, with: "<user>")
        }
        return output
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    // MARK: Vocabulary (English, for the model only)

    static func list(_ items: [String]) -> String {
        let shown = items.prefix(maxListItems).joined(separator: ", ")
        return items.count > maxListItems ? shown + " and \(items.count - maxListItems) more" : shown
    }

    static func categoryName(_ category: ToolCategory) -> String {
        switch category {
        case .runtime: "language runtime"
        case .aiCLI: "AI command-line tool"
        case .developerTool: "developer tool"
        case .database: "database"
        case .packageManager: "package manager"
        case .dependency: "library installed as a dependency"
        case .unrecognized: "unrecognized executable (no package manager claims it)"
        }
    }

    /// Glossary key for a link state.
    static func linkStateKey(_ state: LinkState) -> String {
        switch state {
        case .active: "active"
        case .shadowed: "shadowed"
        case .notOnPath: "not on PATH"
        case .broken: "broken"
        }
    }

    static func linkStateName(_ state: LinkState) -> String? {
        switch state {
        case .active: nil
        case .shadowed: "an earlier PATH entry wins"
        case .notOnPath: nil
        case .broken: "executable or link target missing"
        }
    }

    /// `shadowed` → `shadowed ("被遮蔽" in the app; an earlier PATH entry wins)`, so small
    /// models pick up the UI's word right where the fact is.
    private func term(_ key: String, description: String? = nil) -> String {
        let notes = [vocabulary.terms[key].map { "\"\($0)\" in the app" }, description].compactMap { $0 }
        return notes.isEmpty ? key : "\(key) (\(notes.joined(separator: "; ")))"
    }

    static func issueTypeDescription(_ type: HealthIssueType) -> String {
        switch type {
        case .pathConflict: "different package managers provide the same command; only the first in PATH runs"
        case .duplicateInstallation: "the same tool is installed more than once"
        case .missingPathEntry: "a PATH entry points to a folder that doesn't exist"
        case .duplicatePathEntry: "the same folder appears in PATH more than once"
        case .relativePathEntry: "a PATH entry is a relative path"
        case .missingRuntime: "a tool is installed but the runtime it needs isn't found"
        case .brokenSymlink: "a link in PATH points to a file that no longer exists"
        case .brokenActiveExecutable: "the command Terminal runs is broken"
        case .failedService: "a background service failed"
        case .providerUnavailable: "a package manager couldn't be found"
        case .providerScanFailed: "a package manager couldn't be read"
        case .mixedArchitecture: "installations use different CPU architectures"
        case .shellShadowing: "a shell alias or function with the same name runs instead of the executable"
        case .runtimeEndOfLife: "the installed release line no longer gets (or will soon stop getting) security fixes"
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
