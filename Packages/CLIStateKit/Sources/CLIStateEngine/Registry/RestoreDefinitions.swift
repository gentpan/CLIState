import CLIStateDomain
import Foundation

/// Registry tools added for environment restore templates (Lane N). Kept apart
/// from the core lists so they stay last: earlier definitions win executable-name
/// conflicts, and these must never take a command from an existing tool. Popular
/// packages that scans already show under a provider namespace (`npm.typescript`,
/// `homebrew.docker`) stay out, so their tool IDs and saved policies don't change (C12).
extension StandardDefinitions {
    static func restoreTool(
        _ id: String,
        _ displayName: String,
        _ summary: String,
        _ category: ToolCategory,
        executables: [String],
        packages: [ProviderID: [String]],
        probe: VersionProbe?,
        homepage: String,
        docs: String? = nil,
        config: [String] = []
    ) -> ToolDefinition {
        ToolDefinition(
            id: ToolID(id),
            displayName: displayName,
            summary: summary,
            category: category,
            executables: executables,
            packages: packages,
            versionProbe: probe,
            homepage: URL(string: homepage),
            documentationURL: docs.flatMap { URL(string: $0) },
            configPaths: config
        )
    }

    static let restoreAdditions: [ToolDefinition] = [
        // Python and data
        restoreTool("ruff", "Ruff", "Extremely fast Python linter and code formatter.", .developerTool,
                    executables: ["ruff"],
                    packages: [.homebrew: ["ruff"], .uv: ["ruff"], .pipx: ["ruff"]],
                    probe: VersionProbe(["--version"]),
                    homepage: "https://docs.astral.sh/ruff/", docs: "https://docs.astral.sh/ruff/"),
        restoreTool("jupyterlab", "JupyterLab", "Web-based notebooks for data science and scientific computing.", .developerTool,
                    executables: ["jupyter-lab"],
                    packages: [.uv: ["jupyterlab"], .pipx: ["jupyterlab"], .homebrew: ["jupyterlab"]],
                    probe: VersionProbe(["--version"]),
                    homepage: "https://jupyter.org", docs: "https://jupyterlab.readthedocs.io"),
        restoreTool("duckdb", "DuckDB", "In-process analytical SQL database.", .database,
                    executables: ["duckdb"],
                    packages: [.homebrew: ["duckdb"]],
                    probe: VersionProbe(["--version"]),
                    homepage: "https://duckdb.org", docs: "https://duckdb.org/docs/",
                    config: ["~/.duckdbrc"]),

        // Go
        restoreTool("golangci-lint", "golangci-lint", "Fast linters runner for Go.", .developerTool,
                    executables: ["golangci-lint"],
                    packages: [.homebrew: ["golangci-lint"]],
                    probe: VersionProbe(["--version"], pattern: #"version v?([0-9][^\s]*)"#),
                    homepage: "https://golangci-lint.run", docs: "https://golangci-lint.run/docs/"),
        restoreTool("gopls", "gopls", "Official Go language server for editors.", .developerTool,
                    executables: ["gopls"],
                    packages: [.homebrew: ["gopls"]],
                    probe: VersionProbe(["version"], pattern: #"gopls v([0-9][^\s]*)"#),
                    homepage: "https://go.dev/gopls/", docs: "https://go.dev/gopls/"),

        // Rust
        restoreTool("rust-analyzer", "rust-analyzer", "Language server for Rust.", .developerTool,
                    executables: ["rust-analyzer"],
                    packages: [.homebrew: ["rust-analyzer"]],
                    probe: VersionProbe(["--version"]),
                    homepage: "https://rust-analyzer.github.io", docs: "https://rust-analyzer.github.io/book/"),
        restoreTool("cargo-nextest", "cargo-nextest", "Next-generation test runner for Rust.", .developerTool,
                    executables: ["cargo-nextest"],
                    packages: [.cargo: ["cargo-nextest"], .homebrew: ["cargo-nextest"]],
                    // Needs the `nextest` subcommand argument; the provider reports the version.
                    probe: nil,
                    homepage: "https://nexte.st", docs: "https://nexte.st/docs/"),

        // iOS and macOS
        restoreTool("xcodes", "xcodes", "Install and switch between Xcode versions.", .developerTool,
                    executables: ["xcodes"],
                    packages: [.homebrew: ["xcodes"]],
                    probe: VersionProbe(["version"]),
                    homepage: "https://github.com/XcodesOrg/xcodes"),
        restoreTool("swiftlint", "SwiftLint", "Enforce Swift style and conventions.", .developerTool,
                    executables: ["swiftlint"],
                    packages: [.homebrew: ["swiftlint"]],
                    probe: VersionProbe(["version"]),
                    homepage: "https://realm.github.io/SwiftLint/", docs: "https://realm.github.io/SwiftLint/"),
        restoreTool("swiftformat", "SwiftFormat", "Code formatter for Swift.", .developerTool,
                    executables: ["swiftformat"],
                    packages: [.homebrew: ["swiftformat"]],
                    probe: VersionProbe(["--version"]),
                    homepage: "https://github.com/nicklockwood/SwiftFormat"),
        restoreTool("xcbeautify", "xcbeautify", "Readable output for xcodebuild.", .developerTool,
                    executables: ["xcbeautify"],
                    packages: [.homebrew: ["xcbeautify"]],
                    probe: VersionProbe(["--version"]),
                    homepage: "https://github.com/cpisciotta/xcbeautify"),
        restoreTool("cocoapods", "CocoaPods", "Dependency manager for Swift and Objective-C projects.", .packageManager,
                    executables: ["pod"],
                    packages: [.homebrew: ["cocoapods"]],
                    probe: VersionProbe(["--version"]),
                    homepage: "https://cocoapods.org", docs: "https://guides.cocoapods.org"),
        restoreTool("fastlane", "fastlane", "Automate building and releasing iOS and macOS apps.", .developerTool,
                    executables: ["fastlane"],
                    packages: [.homebrew: ["fastlane"]],
                    // `fastlane --version` loads the whole toolchain and may check for updates online.
                    probe: nil,
                    homepage: "https://fastlane.tools", docs: "https://docs.fastlane.tools"),

        // DevOps and cloud
        restoreTool("kubectl", "kubectl", "Command-line tool for Kubernetes clusters.", .developerTool,
                    executables: ["kubectl"],
                    packages: [.homebrew: ["kubernetes-cli"]],
                    probe: VersionProbe(["version", "--client"], pattern: #"Client Version: v([0-9][^\s]*)"#),
                    homepage: "https://kubernetes.io", docs: "https://kubernetes.io/docs/reference/kubectl/",
                    config: ["~/.kube/config"]),
        restoreTool("helm", "Helm", "Package manager for Kubernetes.", .developerTool,
                    executables: ["helm"],
                    packages: [.homebrew: ["helm"]],
                    probe: VersionProbe(["version", "--short"], pattern: #"v([0-9][^\s+]*)"#),
                    homepage: "https://helm.sh", docs: "https://helm.sh/docs/"),
        restoreTool("k9s", "k9s", "Terminal UI for managing Kubernetes clusters.", .developerTool,
                    executables: ["k9s"],
                    packages: [.homebrew: ["k9s"]],
                    probe: VersionProbe(["version", "--short"], pattern: #"Version\s+v?([0-9][^\s]*)"#),
                    homepage: "https://k9scli.io"),
        restoreTool("terraform", "Terraform", "Infrastructure as code from HashiCorp.", .developerTool,
                    executables: ["terraform"],
                    // Distributed from HashiCorp's own tap since the license change.
                    packages: [.homebrew: ["hashicorp/tap/terraform"]],
                    // `terraform version` contacts HashiCorp's checkpoint service.
                    probe: nil,
                    homepage: "https://www.terraform.io", docs: "https://developer.hashicorp.com/terraform/docs"),
        restoreTool("awscli", "AWS CLI", "Command-line interface for Amazon Web Services.", .developerTool,
                    executables: ["aws"],
                    packages: [.homebrew: ["awscli"]],
                    probe: VersionProbe(["--version"], pattern: #"aws-cli/([0-9][^\s]*)"#),
                    homepage: "https://aws.amazon.com/cli/", docs: "https://docs.aws.amazon.com/cli/",
                    config: ["~/.aws/config"]),
    ]
}
