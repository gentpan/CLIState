import CLIStateDomain
import Foundation
import Testing

@Suite("Environment profile")
struct EnvironmentProfileTests {
    @Test func roundTripsThroughTheFileFormat() throws {
        let profile = EnvironmentProfile(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            name: "Work Mac",
            note: "Laptop",
            source: ProfileSource(architecture: "arm64", macOSVersion: "15.6", appVersion: "0.2.0"),
            items: [
                ProfileItem(toolID: "git", provider: .homebrewFormula, packageName: "git", version: "2.51.0"),
                ProfileItem(toolID: "terraform", provider: .homebrewFormula, packageName: "terraform", version: "1.13.3", pinned: true, tap: "hashicorp/tap"),
                ProfileItem(toolID: "claude-code", provider: .npm, packageName: "@anthropic-ai/claude-code", version: "2.1.270"),
            ]
        )
        let data = try profile.encoded()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(#""format" : "clistate-profile""#))
        #expect(text.contains(#""createdAt" : "2027-01-15T08:00:00Z""#))
        #expect(text.contains("@anthropic-ai/claude-code"))
        #expect(try EnvironmentProfile.decode(from: data) == profile)
    }

    @Test func toleratesUnknownKeysMissingFieldsAndBrokenItems() throws {
        let json = """
        {
          "format": "clistate-profile",
          "schemaVersion": 3,
          "futureField": {"nested": true},
          "source": {"architecture": 64, "macOSVersion": "26.0", "hostName": "ignored"},
          "items": [
            {"provider": "homebrew-formula", "packageName": "jq", "version": 1.7, "pinned": "yes", "extra": []},
            {"provider": "npm"},
            {"packageName": "orphan"},
            42,
            "text",
            {"provider": "homebrew-cask", "packageName": "  ghostty  ", "tap": ""},
            {"provider": "mas", "packageName": "Xcode"},
            {"provider": "homebrew-formula", "packageName": "jq"}
          ]
        }
        """
        let profile = try EnvironmentProfile.decode(from: Data(json.utf8))
        #expect(profile.schemaVersion == 3)
        #expect(profile.isNewerSchema)
        #expect(profile.createdAt == Date(timeIntervalSince1970: 0))
        #expect(profile.source == ProfileSource(architecture: nil, macOSVersion: "26.0"))
        #expect(profile.items.map(\.id) == ["homebrew-formula:jq", "homebrew-cask:ghostty", "mas:Xcode"])
        #expect(profile.items[0].version == nil)
        #expect(profile.items[0].pinned == false)
        #expect(profile.items[1].tap == nil)
        #expect(profile.items[2].provider.providerID == nil)
        #expect(profile.items[2].provider.packageKind == nil)
    }

    @Test func acceptsProfilesWithoutFormatAndFractionalDates() throws {
        let json = #"{"createdAt": "2026-09-13T10:20:30.123Z", "items": [{"provider": "uv", "packageName": "ruff"}]}"#
        let profile = try EnvironmentProfile.decode(from: Data(json.utf8))
        #expect(profile.items.first?.provider == .uv)
        #expect(profile.createdAt.timeIntervalSince1970 > 1_789_000_000)
    }

    @Test("Rejects files that aren't profiles", arguments: [
        "not json",
        "[]",
        "{}",
        #"{"format": "brewfile", "items": []}"#,
        #"{"tools": []}"#,
    ])
    func rejectsOtherFiles(_ text: String) {
        #expect(throws: EnvironmentProfileError.notAProfile) {
            try EnvironmentProfile.decode(from: Data(text.utf8))
        }
    }

    @Test func mapsProvidersAndQualifiedNames() {
        #expect(ProfileProvider(providerID: .homebrew, kind: .cask) == .homebrewCask)
        #expect(ProfileProvider(providerID: .npm, kind: .formula) == nil)
        #expect(ProfileProvider(providerID: .bun, kind: .globalPackage) == nil)
        #expect(ProfileProvider.cargo.providerID == .cargo)
        #expect(ProfileProvider.pnpm.packageKind == .globalPackage)

        let tapped = ProfileItem(provider: .homebrewFormula, packageName: "terraform", tap: "hashicorp/tap")
        #expect(tapped.qualifiedName == "hashicorp/tap/terraform")
        #expect(InstallRequest(item: tapped).qualifiedName == "hashicorp/tap/terraform")
        #expect(InstallRequest(item: tapped).kind == .formula)
        // A tap only means something to Homebrew.
        #expect(ProfileItem(provider: .npm, packageName: "x", tap: "a/b").qualifiedName == "x")
    }
}
