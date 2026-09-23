import CLIStateDomain
import Foundation

/// A small editorial catalog, not a popularity ranking. Sources are Homebrew formula pages.
struct RecommendedTool: Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let symbol: String
    let summary: String

    var sourceURL: URL { URL(string: "https://formulae.brew.sh/formula/\(id)")! }
    var profileItem: ProfileItem { ProfileItem(provider: .homebrewFormula, packageName: id) }

    func installedTool(in tools: [Tool]) -> Tool? {
        tools.first { tool in
            guard !tool.installations.isEmpty else { return false }
            return tool.identity.name == id || tool.identity.registryID == id || tool.installations.contains {
                $0.ownership.provider == .homebrew && $0.ownership.packageName == id
            }
        }
    }

    static let categories = ["Developer Essentials", "PHP Development", "Python Tools", "Media Tools"]
    static let catalog: [Self] = [
        .init(id: "git", name: "Git", category: "Developer Essentials", symbol: "arrow.triangle.branch", summary: "Track code changes and collaborate on projects."),
        .init(id: "gh", name: "GitHub CLI", category: "Developer Essentials", symbol: "terminal", summary: "Manage GitHub pull requests and issues from Terminal."),
        .init(id: "ripgrep", name: "ripgrep", category: "Developer Essentials", symbol: "doc.text.magnifyingglass", summary: "Quickly search text across your project files."),
        .init(id: "jq", name: "jq", category: "Developer Essentials", symbol: "curlybraces", summary: "Read, filter and transform JSON data."),
        .init(id: "php", name: "PHP", category: "PHP Development", symbol: "chevron.left.forwardslash.chevron.right", summary: "Run PHP scripts and build web applications."),
        .init(id: "composer", name: "Composer", category: "PHP Development", symbol: "shippingbox", summary: "Install and manage the libraries your PHP project needs."),
        .init(id: "uv", name: "uv", category: "Python Tools", symbol: "square.stack.3d.up", summary: "Manage Python projects, environments and command-line tools."),
        .init(id: "ffmpeg", name: "FFmpeg", category: "Media Tools", symbol: "film", summary: "Convert, record and process audio and video."),
    ]
}
