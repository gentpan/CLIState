import CLIStateDomain
import Foundation
import Testing

@Suite("Recommendation installation detection")
struct RecommendedToolTests {
    @Test func detectsSystemAndOtherProviderCopiesWithoutReinstalling() {
        let git = RecommendedTool.catalog.first { $0.id == "git" }!
        let installed = Tool(id: "git", identity: ToolIdentity(name: "git", displayName: "Git", category: .developerTool), installations: [ToolInstallation(id: "system-git", ownership: Ownership(provider: .system, confidence: .confirmed), linkState: .active, isSystemManaged: true)], health: ToolHealthState(status: .healthy), lastScannedAt: Date())
        #expect(git.installedTool(in: [installed])?.id == "git")
        var removed = installed
        removed.installations = []
        #expect(git.installedTool(in: [removed]) == nil)
        #expect(RecommendedTool.catalog.first { $0.id == "gh" }!.installedTool(in: [installed]) == nil)
    }
}
