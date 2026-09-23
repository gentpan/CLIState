import CLIStateApplication
import CLIStateDomain
import SwiftUI
import UniformTypeIdentifiers

// All environment restore strings live in `Restore.xcstrings` (table "Restore")
// so they merge independently of `Localizable.xcstrings`.

enum RestoreSymbol {
    static let page = "laptopcomputer.and.arrow.down"
    static let export = "square.and.arrow.up"
    static let importFile = "square.and.arrow.down"
    static let templates = "square.grid.2x2"
    static let install = "arrow.down.circle"
    static let pending = "circle.dashed"
    static let waiting = "hourglass"
    static let unavailable = "nosign"
    static let versionDiffers = "arrow.left.arrow.right.circle"
    static let brewfile = "doc.plaintext"
    static let file = "doc.text"
    static let ai = "sparkles"
    static let pin = "pin"

    static func template(_ id: String) -> String {
        switch id {
        case "frontend-web": "globe"
        case "node-fullstack": "server.rack"
        case "python-data": "chart.bar.xaxis"
        case "php-laravel": "chevron.left.forwardslash.chevron.right"
        case "go-backend": "bolt.horizontal"
        case "rust": "gearshape.2"
        case "apple-platforms": "apple.logo"
        case "ai-cli": "sparkles"
        case "devops-cloud": "cloud"
        default: "square.dashed"
        }
    }
}

/// Fixed sizes for the restore page, on the 4 pt grid.
enum RestoreLayout {
    static let templateCardMinWidth: CGFloat = 224
    static let aiFieldMinHeight: CGFloat = 64
    static let payloadMaxHeight: CGFloat = 240
}

extension UTType {
    /// Declared in Info.plist as an exported type conforming to `public.json`.
    static let clistateProfile = UTType(exportedAs: "com.clistate.environment-profile", conformingTo: .json)
}

enum RestoreText {
    static var pageTitle: String { String(localized: "Environment Restore", table: "Restore") }

    // MARK: Items

    private static let candidateNames: [ToolID: String] = Dictionary(
        EnvironmentRestore.candidates.map { ($0.toolID, $0.displayName) },
        uniquingKeysWith: { first, _ in first }
    )

    /// Registry name when the item is a known tool, otherwise the package name.
    static func displayName(_ item: ProfileItem, snapshot: EnvironmentSnapshot?) -> String {
        guard let toolID = item.toolID else { return item.packageName }
        return candidateNames[toolID] ?? snapshot?.tool(toolID)?.identity.displayName ?? item.packageName
    }

    /// `Homebrew`, `Homebrew Cask`, `npm` …; unknown providers as written.
    static func providerTitle(_ provider: ProfileProvider) -> String {
        switch provider {
        case .homebrewCask: String(localized: "Homebrew Cask", table: "Restore")
        default: provider.providerID?.displayName ?? provider.rawValue
        }
    }

    static func installRequests(_ group: RestoreProviderGroup, snapshot: EnvironmentSnapshot?) -> [InstallRequest] {
        zip(group.items, group.requests).map { item, request in
            var request = request
            request.displayName = displayName(item, snapshot: snapshot)
            return request
        }
    }

    // MARK: Status

    static func statusTitle(_ status: ProfileItemStatus) -> String {
        switch status {
        case .installed: String(localized: "Installed", table: "Restore")
        case .versionDiffers: String(localized: "Version Differs", table: "Restore")
        case .pending: String(localized: "To Install", table: "Restore")
        case .pendingAfter: String(localized: "Waiting", table: "Restore")
        case .unavailable: String(localized: "Can't Install", table: "Restore")
        }
    }

    static func statusSymbol(_ status: ProfileItemStatus) -> String {
        switch status {
        case .installed: Symbol.latest
        case .versionDiffers: RestoreSymbol.versionDiffers
        case .pending: RestoreSymbol.pending
        case .pendingAfter: RestoreSymbol.waiting
        case .unavailable: RestoreSymbol.unavailable
        }
    }

    static func statusTint(_ status: ProfileItemStatus) -> Color {
        switch status {
        case .installed: DS.Palette.success
        case .versionDiffers: DS.Palette.textSecondary
        case .pending: DS.Palette.highlight
        case .pendingAfter: DS.Palette.textSecondary
        case .unavailable: DS.Palette.warning
        }
    }

    static func statusDetail(_ status: ProfileItemStatus, snapshot: EnvironmentSnapshot?) -> String? {
        switch status {
        case let .installed(version, provider):
            if let version { return String(localized: "\(version) via \(provider.displayName)", table: "Restore") }
            return String(localized: "Via \(provider.displayName)", table: "Restore")
        case let .versionDiffers(installed, expected, provider):
            return String(localized: "\(installed) via \(provider.displayName), was \(expected)", table: "Restore")
        case .pending:
            return nil
        case let .pendingAfter(provider, enabledBy):
            let names = enabledBy.map { candidateNames[$0] ?? $0.rawValue }.formatted(.list(type: .or))
            return String(localized: "Installs with \(provider.displayName) after \(names)", table: "Restore")
        case let .unavailable(blocker):
            return blockerText(blocker)
        }
    }

    static func blockerText(_ blocker: RestoreBlocker) -> String {
        switch blocker {
        case let .providerMissing(provider):
            String(localized: "\(provider.displayName) isn't installed", table: "Restore")
        case let .unsupportedProvider(raw):
            String(localized: "This version of CLI State can't install with \(raw)", table: "Restore")
        case .invalidPackageName:
            String(localized: "The package name isn't valid, so it's skipped", table: "Restore")
        }
    }

    /// Hints use `code spans` for commands.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    /// What to do when a package manager is missing. CLIState never installs Homebrew itself.
    static func missingProviderHint(_ provider: ProviderID) -> String {
        switch provider {
        case .homebrew:
            String(localized: "Install Homebrew yourself by running this command in Terminal, then refresh. CLI State never runs it for you.", table: "Restore")
        case .npm:
            String(localized: "npm comes with Node.js. Install Node.js first (for example Homebrew's node), then refresh.", table: "Restore")
        case .pnpm:
            String(localized: "Install pnpm first, then run `pnpm setup` in Terminal and refresh.", table: "Restore")
        case .uv:
            String(localized: "Install uv first (for example with Homebrew), then refresh.", table: "Restore")
        case .pipx:
            String(localized: "Install pipx first (for example with Homebrew), then refresh.", table: "Restore")
        case .cargo:
            String(localized: "Install Rust first (Homebrew's rust, or rustup followed by `rustup default stable`), then refresh.", table: "Restore")
        default:
            String(localized: "Install \(provider.displayName) first, then refresh.", table: "Restore")
        }
    }

    // MARK: Templates

    static func templateTitle(_ id: String) -> String {
        switch id {
        case "frontend-web": String(localized: "Frontend Web", table: "Restore")
        case "node-fullstack": String(localized: "Node.js Full Stack", table: "Restore")
        case "python-data": String(localized: "Python & Data", table: "Restore")
        case "php-laravel": String(localized: "PHP & Laravel", table: "Restore")
        case "go-backend": String(localized: "Go Backend", table: "Restore")
        case "rust": String(localized: "Rust", table: "Restore")
        case "apple-platforms": String(localized: "iOS & macOS", table: "Restore")
        case "ai-cli": String(localized: "AI CLI Toolkit", table: "Restore")
        case "devops-cloud": String(localized: "DevOps & Cloud", table: "Restore")
        default: id
        }
    }

    static func templateSummary(_ id: String) -> String {
        switch id {
        case "frontend-web": String(localized: "Node.js with pnpm and Yarn, Deno, Git and GitHub CLI.", table: "Restore")
        case "node-fullstack": String(localized: "Node.js and pnpm with PostgreSQL, Redis and jq.", table: "Restore")
        case "python-data": String(localized: "Python with uv, Ruff, JupyterLab, DuckDB and SQLite.", table: "Restore")
        case "php-laravel": String(localized: "PHP and Composer with MySQL, Redis, nginx and Node.js.", table: "Restore")
        case "go-backend": String(localized: "Go with gopls and golangci-lint, PostgreSQL and Redis.", table: "Restore")
        case "rust": String(localized: "Rust with rust-analyzer, cargo-nextest and ripgrep.", table: "Restore")
        case "apple-platforms": String(localized: "xcodes, SwiftLint, SwiftFormat, xcbeautify, CocoaPods and fastlane.", table: "Restore")
        case "ai-cli": String(localized: "Claude Code, Codex, Gemini CLI, opencode and Aider, with Node.js and uv.", table: "Restore")
        case "devops-cloud": String(localized: "kubectl, Helm, k9s, Terraform and the AWS CLI.", table: "Restore")
        default: ""
        }
    }

    // MARK: Operations (`OperationKind.install`)

    static func installTitle(_ plan: OperationPlan, name: String) -> String {
        let count = plan.targets.count
        return count == 1 ? String(localized: "Install \(name)", table: "Restore") : String(localized: "Install \(count) tools", table: "Restore")
    }

    static func installTitle(count: Int) -> String {
        String(localized: "Install \(count) tools", table: "Restore")
    }

    static func installConfirmTitle(count: Int) -> String {
        count > 1 ? String(localized: "Install \(count) Tools", table: "Restore") : String(localized: "Install", table: "Restore")
    }

    static var installExplanation: String {
        String(localized: "CLI State runs the commands below, then rescans to confirm each package is installed. Packages that are already installed aren't upgraded.", table: "Restore")
    }

    static func installSucceeded(_ plan: OperationPlan) -> String {
        let count = plan.targets.count
        return String(localized: "Installed \(count) tools", table: "Restore")
    }

    static var installUnverified: String {
        String(localized: "Command finished, but the rescan didn't find every package", table: "Restore")
    }

    static func installFailed(name: String, provider: String) -> String {
        String(localized: "\(name) couldn't be installed because \(provider) returned an error. View the output for details.", table: "Restore")
    }
}

extension ProfileSource {
    /// `arm64 · macOS 15.6`
    var summary: String? {
        let parts = [architecture, macOSVersion.map { "macOS \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
