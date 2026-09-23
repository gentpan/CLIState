import CLIStateDomain
@testable import CLIStateEngine
import CLIStateTestSupport
import Foundation
import Testing

@Suite("Installation order")
struct InstallationOrderTests {
    private let brewKeg = "/opt/homebrew/Cellar/python@3.14/3.14.7"
    private let uvRoot = "\(home)/.local/share/uv/python"

    /// The reference machine: Homebrew python@3.14 wins `python3`, uv links
    /// `~/.local/bin/python3.12` (earlier in PATH, but a different command), two more
    /// uv interpreters sit outside PATH, and macOS ships `/usr/bin/python3`.
    private func pythonScenario() -> EngineScenario {
        let scenario = EngineScenario()
        scenario.binary("\(brewKeg)/Frameworks/Python.framework/Versions/3.14/bin/python3.14", header: MachOHeader.arm64)
        scenario.link("\(brewKeg)/bin/python3", to: "\(brewKeg)/Frameworks/Python.framework/Versions/3.14/bin/python3.14")
        scenario.link("/opt/homebrew/bin/python3", to: "\(brewKeg)/bin/python3")

        for version in ["3.10.20", "3.12.13", "3.13.13"] {
            let directory = "\(uvRoot)/cpython-\(version)-macos-aarch64-none/bin"
            let minor = version.split(separator: ".").prefix(2).joined(separator: ".")
            scenario.binary("\(directory)/python\(minor)", header: MachOHeader.arm64)
            scenario.link("\(directory)/python", to: "\(directory)/python\(minor)")
            scenario.link("\(directory)/python3", to: "\(directory)/python\(minor)")
        }
        scenario.link("\(home)/.local/bin/python3.12", to: "\(uvRoot)/cpython-3.12.13-macos-aarch64-none/bin/python3.12")

        scenario.binary("/usr/bin/python3", header: MachOHeader.arm64)
        scenario.runner.stub("python3", ["--version"], stdout: "Python 3.9.6\n")
        return scenario
    }

    @Test func activeFirstThenOwnedByVersionThenSystem() async throws {
        let scenario = pythonScenario()
        let snapshot = await scenario.build(inventories: [
            homebrewInventory([formula("python@3.14", "3.14.7", direct: false, executables: ["python3"])]),
        ])
        let python = try #require(snapshot.tool("python"))

        #expect(python.activeInstallationID == "homebrew:python@3.14")
        #expect(python.installations.map(\.id) == [
            "homebrew:python@3.14",
            "path:\(uvRoot)/cpython-3.13.13-macos-aarch64-none/bin/python",
            "path:\(home)/.local/bin/python3.12",
            "path:\(uvRoot)/cpython-3.10.20-macos-aarch64-none/bin/python",
            "path:/usr/bin/python3",
        ])
        #expect(python.installations.map { $0.version?.value.rawValue } == ["3.14.7", "3.13.13", "3.12.13", "3.10.20", "3.9.6"])
        #expect(python.primaryInstallation?.id == "homebrew:python@3.14")
    }

    @Test func withoutActiveInstallationConfirmedComesFirst() {
        func installation(_ id: InstallationID, _ provider: ProviderID, _ confidence: AttributionConfidence, _ version: String?, linkState: LinkState = .notOnPath, system: Bool = false) -> ToolInstallation {
            ToolInstallation(
                id: id,
                ownership: Ownership(provider: provider, confidence: confidence),
                version: version.map { ObservedValue(ToolVersion($0), source: .path, confidence: .probable, observedAt: scanDate) },
                linkState: linkState,
                isSystemManaged: system
            )
        }
        let installations = [
            installation("path:/usr/bin/python3", .system, .confirmed, "3.9.6", linkState: .shadowed, system: true),
            installation("path:/uv/3.13/bin/python", .uv, .probable, "3.13.13"),
            installation("path:/broken/python3", .standalone, .unknown, nil, linkState: .broken),
            installation("homebrew:python@3.12", .homebrew, .confirmed, "3.12.11"),
            installation("homebrew:python@3.14", .homebrew, .confirmed, "3.14.7"),
            installation("path:/uv/3.10/bin/python", .uv, .probable, "3.10.20", linkState: .shadowed),
        ]
        let ordered = MergeEngine.presentationOrder(installations, activeID: nil).map(\.id)
        #expect(ordered == [
            "homebrew:python@3.14", "homebrew:python@3.12",
            "path:/uv/3.13/bin/python", "path:/uv/3.10/bin/python", "path:/broken/python3",
            "path:/usr/bin/python3",
        ])

        // An active system stub still leads: it is what the terminal runs.
        let withActiveSystem = MergeEngine.presentationOrder(installations, activeID: "path:/usr/bin/python3").map(\.id)
        #expect(withActiveSystem.first == "path:/usr/bin/python3")
        #expect(withActiveSystem.dropFirst().first == "homebrew:python@3.14")
    }

    @Test func versionComparisonPrefersParseableThenMissing() {
        #expect(MergeEngine.newerVersionFirst(ToolVersion("3.13.1"), ToolVersion("3.9.6")) == true)
        #expect(MergeEngine.newerVersionFirst(ToolVersion("3.9.6"), ToolVersion("3.13.1")) == false)
        #expect(MergeEngine.newerVersionFirst(ToolVersion("3.14"), ToolVersion("3.14.0")) == nil)
        #expect(MergeEngine.newerVersionFirst(ToolVersion("HEAD"), ToolVersion("1.0")) == false)
        #expect(MergeEngine.newerVersionFirst(ToolVersion("HEAD"), nil) == true)
        #expect(MergeEngine.newerVersionFirst(nil, nil) == nil)
    }

    @Test func orderDoesNotChangeInstallationIDs() async throws {
        let scenario = pythonScenario()
        let inventories = [homebrewInventory([formula("python@3.14", "3.14.7", direct: false, executables: ["python3"])])]
        let first = await scenario.build(inventories: inventories)
        let second = await scenario.build(inventories: inventories, previous: first)
        #expect(Set(first.tool("python")?.installations.map(\.id) ?? []) == Set(second.tool("python")?.installations.map(\.id) ?? []))
        #expect(first.tool("python")?.installations.map(\.id) == second.tool("python")?.installations.map(\.id))
    }
}
