import CLIStateDomain
import Foundation
import Testing

@Suite("ToolVersion")
struct VersionTests {
    @Test("Parses real-world version strings", arguments: [
        ("8.5.7", [8, 5, 7]),
        ("v26.2.0", [26, 2, 0]),
        ("go1.27.1", [1, 27, 1]),
        ("1.6.3_1", [1, 6, 3]),
        ("17.10", [17, 10]),
    ])
    func parses(raw: String, components: [Int]) {
        #expect(ToolVersion(raw).semantic?.components == components)
    }

    @Test func rejectsNonVersions() {
        #expect(ToolVersion("HEAD").semantic == nil)
        #expect(ToolVersion("nightly-2026-09-12").semantic == nil)
    }

    @Test func ordersHomebrewRevisionsAndPrereleases() throws {
        let revision = try #require(SemanticVersion(parsing: "1.6.3_1"))
        #expect(revision < SemanticVersion(parsing: "1.6.5")!)
        #expect(SemanticVersion(parsing: "1.6.3")! < revision)
        #expect(SemanticVersion(parsing: "2.0.0-beta.1")! < SemanticVersion(parsing: "2.0.0")!)
        #expect(SemanticVersion(parsing: "2.92.0")! < SemanticVersion(parsing: "2.100.0")!)
    }

    @Test func updateKindIsUnknownForChannelTags() {
        #expect(UpdateKind.between(ToolVersion("8.1.2_1"), ToolVersion("9.0.1")) == .major)
        #expect(UpdateKind.between(ToolVersion("8.5.7"), ToolVersion("8.5.10")) == .patch)
        #expect(UpdateKind.between(ToolVersion("0.0.0-next-15329"), ToolVersion("0.0.0-beta-17823")) == .unknown)
    }

    @Test func commandDisplayQuotesUnsafeArguments() {
        let command = Command(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "foo; rm -rf ~"])
        #expect(command.displayString == "brew upgrade 'foo; rm -rf ~'")
        #expect(command.arguments.count == 2)
    }

    @Test func environmentHealthIgnoresInfo() {
        let info = HealthIssue(type: .duplicatePathEntry, severity: .info, subject: "~/.mavis/bin")
        let warning = HealthIssue(type: .brokenSymlink, severity: .warning, subject: "codexbar")
        #expect(EnvironmentHealth.evaluate([info]) == .good)
        #expect(EnvironmentHealth.evaluate([info, warning]) == .attention)
    }
}

@Suite("UpdatePreferences")
struct UpdatePreferencesTests {
    private func installation(from: String, to: String, confidence: AttributionConfidence = .confirmed) -> ToolInstallation {
        let now = Date(timeIntervalSince1970: 0)
        return ToolInstallation(
            id: "homebrew:php",
            ownership: Ownership(provider: .homebrew, packageName: "php", confidence: confidence),
            version: ObservedValue(ToolVersion(from), source: .provider(.homebrew), confidence: .confirmed, observedAt: now),
            latest: ObservedValue(ToolVersion(to), source: .provider(.homebrew), confidence: .confirmed, observedAt: now),
            linkState: .active,
            capabilities: ToolCapabilities(canUpdate: true)
        )
    }

    @Test func defaultsToNotifyOnly() {
        let preferences = UpdatePreferences()
        #expect(preferences.policy(for: "php", provider: .homebrew) == .notify)
        #expect(!preferences.allowsAutomaticInstall(tool: "php", installation: installation(from: "8.5.7", to: "8.5.10")))
    }

    @Test func toolPolicyOverridesProviderPolicy() {
        let preferences = UpdatePreferences(providerPolicies: [.homebrew: .off], toolPolicies: ["php": .automatic])
        #expect(preferences.allowsAutomaticInstall(tool: "php", installation: installation(from: "8.5.7", to: "8.5.10")))
    }

    @Test func automaticSkipsMajorSkippedAndUnconfirmed() {
        var preferences = UpdatePreferences(defaultPolicy: .automatic)
        #expect(!preferences.allowsAutomaticInstall(tool: "ffmpeg", installation: installation(from: "8.1.2_1", to: "9.0.1")))
        #expect(!preferences.allowsAutomaticInstall(tool: "php", installation: installation(from: "8.5.7", to: "8.5.10", confidence: .probable)))
        preferences.skippedVersions["homebrew:php"] = "8.5.10"
        #expect(!preferences.allowsAutomaticInstall(tool: "php", installation: installation(from: "8.5.7", to: "8.5.10")))
    }
}

@Test func identifierKeyedDictionariesEncodeAsObjects() throws {
    let data = try JSONEncoder().encode(UpdatePreferences(toolPolicies: ["php": .automatic]))
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains(#""toolPolicies":{"php":"automatic"}"#))
    #expect(try JSONDecoder().decode(UpdatePreferences.self, from: data).toolPolicies["php"] == .automatic)
}

@Test("Lexical path normalization never consults the disk", arguments: [
    ("/opt/homebrew/bin/../lib/node_modules/npm/bin/npm-cli.js", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js"),
    ("/private/var/folders/x/../y/./z/", "/private/var/folders/y/z"),
    ("//usr///bin/", "/usr/bin"),
    ("/../..", "/"),
    ("a/../../b", "../b"),
    ("", "."),
])
func lexicalNormalization(input: String, expected: String) {
    #expect(PathNormalization.lexical(input) == expected)
}
