import CLIStateDomain
@testable import CLIStateEngine
import CLIStateTestSupport
import Foundation
import Testing

/// Trimmed from `GET https://endoflife.date/api/v1/products/nodejs/` (schema 1.2.1, 2026-09-13).
private let nodeV1 = Data("""
{"schema_version":"1.2.1","generated_at":"2026-09-13T00:07:57+00:00","result":{"name":"nodejs","aliases":["node"],"label":"Node.js","releases":[
{"name":"26","codename":null,"label":"26 (Upcoming LTS)","releaseDate":"2026-05-05","isLts":false,"ltsFrom":"2026-10-28","isEoas":false,"eoasFrom":"2027-10-27","isEol":false,"eolFrom":"2029-04-30","isMaintained":true,"latest":{"name":"26.8.2","date":"2026-09-09","link":null},"custom":null},
{"name":"25","releaseDate":"2025-10-15","isLts":false,"isEol":true,"eolFrom":"2026-06-01","isMaintained":false,"latest":{"name":"25.9.0","date":"2026-04-01"}},
{"name":"24","releaseDate":"2025-05-06","isLts":true,"isEol":false,"eolFrom":"2028-04-30","latest":{"name":"24.21.0"}},
{"name":"22","releaseDate":"2024-04-24","isLts":true,"isEol":false,"eolFrom":"2027-04-30","latest":{"name":"22.23.2"}},
{"name":"20","releaseDate":"2023-04-18","isLts":true,"isEol":true,"eolFrom":"2026-04-30","latest":{"name":"20.20.2"},"futureField":{"x":1}}
]}}
""".utf8)

/// Trimmed from the legacy `GET https://endoflife.date/api/nodejs.json`.
private let nodeLegacy = Data("""
[{"cycle":"26","releaseDate":"2026-05-05","lts":"2026-10-28","eol":"2029-04-30","latest":"26.8.2","latestReleaseDate":"2026-09-09","support":"2027-10-27","extendedSupport":false},
{"cycle":"25","releaseDate":"2025-10-15","eol":"2026-06-01","latest":"25.9.0","lts":false,"support":"2026-04-01"},
{"cycle":"20","releaseDate":"2023-04-18","lts":"2023-10-24","eol":"2026-04-30","latest":"20.20.2"}]
""".utf8)

/// Legacy rows with numeric cycles and boolean `eol` (Go and Bun publish these).
private let goLegacy = Data("""
[{"cycle":"1.27","releaseDate":"2026-08-19","eol":false,"latest":"1.27.1","lts":false},
{"cycle":1.25,"releaseDate":"2025-08-12","eol":"2026-08-19","latest":"1.25.14","lts":false},
{"cycle":"1.24","releaseDate":"2025-02-11","eol":true,"latest":"1.24.13"}]
""".utf8)

private func day(_ text: String) -> Date {
    try! Date(text, strategy: EndOfLifeDecoder.dayFormat)
}

private func product(_ slug: String, _ cycles: [(String, String?, Bool?)], fetchedAt: Date = day("2026-09-01")) -> EndOfLifeProduct {
    EndOfLifeProduct(slug: slug, cycles: cycles.map { EndOfLifeCycle(name: $0.0, endOfLifeDate: $0.1.map(day), isEndOfLife: $0.2) }, fetchedAt: fetchedAt)
}

private let python = product("python", [("3.14", "2030-10-31", false), ("3.13", "2029-10-31", false), ("3.10", "2026-10-31", false), ("3.9", "2025-10-31", true)])
private let php = product("php", [("8.5", "2029-12-31", false), ("8.1", "2025-12-31", true)])
private let postgres = product("postgresql", [("18", "2030-11-14", false), ("14", "2026-11-12", false), ("9.6", "2021-11-11", true)])
private let clock = day("2026-09-13")

@Suite("End-of-life reminders")
struct EndOfLifeTests {
    // MARK: Decoding

    @Test func decodesV1Releases() throws {
        let cycles = try #require(EndOfLifeDecoder.cycles(from: nodeV1))
        #expect(cycles.map(\.name) == ["26", "25", "24", "22", "20"])
        let twenty = try #require(cycles.last)
        #expect(twenty.isEndOfLife == true)
        #expect(twenty.endOfLifeDate == day("2026-04-30"))
        #expect(twenty.latestVersion == "20.20.2")
        #expect(twenty.isLTS == true)
        #expect(cycles.first?.releaseDate == day("2026-05-05"))
    }

    @Test func decodesLegacyArrayWithNumbersAndBooleans() throws {
        let node = try #require(EndOfLifeDecoder.cycles(from: nodeLegacy))
        #expect(node.map(\.name) == ["26", "25", "20"])
        #expect(node[0].endOfLifeDate == day("2029-04-30"))
        #expect(node[0].isEndOfLife == nil)
        #expect(node[0].isLTS == true)
        #expect(node[1].isLTS == false)

        let go = try #require(EndOfLifeDecoder.cycles(from: goLegacy))
        #expect(go.map(\.name) == ["1.27", "1.25", "1.24"])
        #expect(go[0].isEndOfLife == false && go[0].endOfLifeDate == nil)
        #expect(go[2].isEndOfLife == true)
    }

    @Test func rejectsUnrelatedJSON() {
        #expect(EndOfLifeDecoder.cycles(from: Data(#"{"message":"not found"}"#.utf8)) == nil)
        #expect(EndOfLifeDecoder.cycles(from: Data("<html>".utf8)) == nil)
    }

    // MARK: Cycle matching

    @Test(arguments: [
        ("20.11.1", EndOfLifeDefinition.CycleScheme.major, "20"),
        ("v22.3.0", .major, "22"),
        ("3.9.6", .majorMinor, "3.9"),
        ("3.10.20", .majorMinor, "3.10"),
        ("8.1.31_2", .majorMinor, "8.1"),
        ("go1.25.1", .majorMinor, "1.25"),
        ("14.13", .automatic, "14"),
        ("9.6.24", .automatic, "9.6"),
        ("1.8.0_392", .javaFeature, "8"),
        ("21.0.2+13", .javaFeature, "21"),
    ])
    func matchesCycles(version: String, scheme: EndOfLifeDefinition.CycleScheme, expected: String) {
        let names = ["22", "21", "20", "14", "9.6", "8", "8.1", "3.10", "3.9", "1.25"]
        let cycles = names.map { EndOfLifeCycle(name: $0) }
        #expect(EndOfLifeAnalyzer.cycle(for: ToolVersion(version), scheme: scheme, in: cycles)?.name == expected)
    }

    @Test func unknownVersionsDoNotMatch() {
        let cycles = [EndOfLifeCycle(name: "3.9"), EndOfLifeCycle(name: "3")]
        #expect(EndOfLifeAnalyzer.cycle(for: ToolVersion("3.8.1"), scheme: .majorMinor, in: cycles) == nil)
        #expect(EndOfLifeAnalyzer.cycle(for: ToolVersion("HEAD"), scheme: .automatic, in: cycles) == nil)
    }

    // MARK: Phases

    @Test func phaseBoundaries() {
        let now = day("2026-09-13")
        func phase(_ eol: String?, _ flag: Bool? = nil) -> RuntimeSupportPhase {
            EndOfLifeAnalyzer.phase(of: EndOfLifeCycle(name: "x", endOfLifeDate: eol.map(day), isEndOfLife: flag), now: now)
        }
        #expect(phase("2026-09-13") == .ended)
        #expect(phase("2026-09-12") == .ended)
        #expect(phase("2026-09-14") == .endingSoon)
        // Exactly 90 days away still reminds; 91 days doesn't.
        #expect(phase("2026-12-12") == .endingSoon)
        #expect(phase("2026-12-13") == .supported)
        #expect(phase(nil, true) == .ended)
        #expect(phase(nil, false) == .supported)
        #expect(phase(nil) == .supported)
        #expect(phase("2027-01-01", true) == .ended)
    }

    @Test func latestSupportedCyclePrefersReleaseDates() throws {
        let cycles = try #require(EndOfLifeDecoder.cycles(from: nodeV1))
        #expect(EndOfLifeAnalyzer.latestSupportedCycle(in: cycles, now: clock) == "26")
        // Before Node 26 was released: 25 is flagged EOL by the source, so 24 is the newest supported line.
        #expect(EndOfLifeAnalyzer.latestSupportedCycle(in: cycles, now: day("2026-01-01")) == "24")
        let temurin = [
            EndOfLifeCycle(name: "17", releaseDate: day("2021-09-22"), endOfLifeDate: day("2027-10-31")),
            EndOfLifeCycle(name: "11", releaseDate: day("2021-08-01"), endOfLifeDate: day("2027-10-31")),
            EndOfLifeCycle(name: "25", releaseDate: day("2025-09-16"), endOfLifeDate: day("2031-09-30")),
        ]
        #expect(EndOfLifeAnalyzer.latestSupportedCycle(in: temurin, now: clock) == "25")
    }

    // MARK: Health

    @Test func endedActiveInstallationIsAWarning() throws {
        let tool = runtime("php", active: installation("homebrew:php@8.1", version: "8.1.31", provider: .homebrew))
        let result = EndOfLifeAnalyzer().apply(tools: [tool], products: ["php": php], now: clock)
        let issue = try #require(result.issues.first)
        #expect(issue.id == "runtimeEndOfLife:php")
        #expect(issue.severity == .warning)
        #expect(issue.details["cycle"] == "8.1")
        #expect(issue.details["eol"] == "2025-12-31")
        #expect(issue.details["latestCycle"] == "8.5")
        #expect(issue.details["phase"] == "ended")
        #expect(issue.suggestedAction == .openTool("php"))
        #expect(result.tools[0].installations[0].support?.phase == .ended)
    }

    @Test func endingSoonIsInfoAndSupportedRaisesNothing() throws {
        let soon = runtime("postgresql", active: installation("homebrew:postgresql@14", version: "14.13", provider: .homebrew))
        let fine = runtime("python", active: installation("homebrew:python@3.14", version: "3.14.7", provider: .homebrew))
        let result = EndOfLifeAnalyzer().apply(tools: [soon, fine], products: ["postgresql": postgres, "python": python], now: clock)
        #expect(result.issues.count == 1)
        let issue = try #require(result.issues.first)
        #expect(issue.toolID == "postgresql")
        #expect(issue.severity == .info)
        #expect(issue.details["phase"] == "endingSoon")
        #expect(result.tools[1].installations[0].support?.phase == .supported)
        #expect(result.tools[1].installations[0].support?.endOfLifeDate == day("2030-10-31"))
    }

    @Test func confirmedShadowedInstallationCountsButUnconfirmedDoesNot() throws {
        let active = installation("homebrew:python@3.14", version: "3.14.7", provider: .homebrew)
        let keg = installation("homebrew:python@3.9", version: "3.9.21", provider: .homebrew, linkState: .notOnPath)
        let stray = installation("path:/Users/tester/.local/share/uv/python/cpython-3.10/bin/python", version: "3.10.20", provider: .standalone, confidence: .unknown, linkState: .notOnPath)
        let tool = runtime("python", active: active, others: [keg, stray])
        let result = EndOfLifeAnalyzer().apply(tools: [tool], products: ["python": python], now: clock)
        let issue = try #require(result.issues.first)
        #expect(issue.severity == .warning)
        #expect(issue.installationIDs == [keg.id])
        // Every matched installation still shows its support state.
        #expect(result.tools[0].installations.map { $0.support?.phase } == [.supported, .ended, .endingSoon])
    }

    @Test func macOSRuntimeOnlyGetsInfo() throws {
        var system = installation("path:/usr/bin/python3", version: "3.9.6", provider: .system)
        system.isSystemManaged = true
        let tool = runtime("python", active: system)
        let issue = try #require(EndOfLifeAnalyzer().apply(tools: [tool], products: ["python": python], now: clock).issues.first)
        #expect(issue.severity == .info)
        #expect(issue.details["systemManaged"] == "true")
    }

    @Test func javaNeedsTemurinPathEvidence() {
        let temurin = product("eclipse-temurin", [("21", "2029-12-31", false), ("8", "2030-12-31", false)])
        var jdk = installation("path:/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/bin/java", version: "21.0.2", provider: .standalone)
        jdk.installPrefix = "/Library/Java/JavaVirtualMachines/temurin-21.jdk"
        let openjdk = installation("homebrew:openjdk", version: "21.0.2", provider: .homebrew)
        let result = EndOfLifeAnalyzer().apply(tools: [runtime("java", active: jdk, others: [openjdk])], products: ["eclipse-temurin": temurin], now: clock)
        #expect(result.tools[0].installations[0].support?.cycle == "21")
        #expect(result.tools[0].installations[1].support == nil)
    }

    @Test func registryAssignsProducts() {
        let registry = ToolRegistry.standard
        #expect(registry.definition("node")?.endOfLife?.product == "nodejs")
        #expect(registry.definition("postgresql")?.endOfLife?.scheme == .automatic)
        #expect(registry.definition("java")?.endOfLife?.pathHints == ["temurin"])
        #expect(registry.definition("git")?.endOfLife == nil)
        for definition in registry.definitions {
            if let slug = definition.endOfLife?.product { #expect(EndOfLifeSource.isValidSlug(slug)) }
        }
    }

    // MARK: Engine integration and source

    @Test func fastScansNeverAllowNetworkAndIssuesJoinHealth() async throws {
        let scenario = EngineScenario(path: ["/opt/homebrew/bin", "/usr/bin"])
        scenario.executable("/opt/homebrew/Cellar/php/8.1.31/bin/php")
        scenario.link("/opt/homebrew/bin/php", to: "../Cellar/php/8.1.31/bin/php")
        let inventory = homebrewInventory([formula("php", "8.1.31", executables: ["php"])])
        let provider = RecordingEndOfLifeProvider(products: ["php": php])
        let engine = SnapshotEngine(fileSystem: scenario.fs, commandRunner: scenario.runner, hostArchitecture: .arm64, endOfLife: provider)

        let fast = await engine.buildSnapshot(discovery: scenario.discovery(), inventories: [inventory], failedProviders: [:], previous: nil, depth: .fast, now: clock)
        let deep = await engine.buildSnapshot(discovery: scenario.discovery(), inventories: [inventory], failedProviders: [:], previous: fast, depth: .deep, now: clock)
        #expect(await provider.requests == [RecordingEndOfLifeProvider.Request(slug: "php", allowNetwork: false), .init(slug: "php", allowNetwork: true)])

        let issue = try #require(deep.issues.first { $0.type == .runtimeEndOfLife })
        #expect(issue.severity == .warning)
        #expect(deep.tool("php")?.health.issueIDs.contains(issue.id) == true)
        #expect(deep.tool("php")?.installations.first?.support?.cycle == "8.1")
        #expect(deep.health == .attention)
    }

    @Test func sourceFallsBackToLegacyEndpoint() async throws {
        let http = StubHTTP(responses: [
            EndOfLifeSource.v1URL("nodejs"): HTTPResponse(statusCode: 404, body: Data()),
            EndOfLifeSource.legacyURL("nodejs"): HTTPResponse(statusCode: 200, body: nodeLegacy),
        ])
        let product = try await EndOfLifeSource(http: http).fetch("nodejs", now: clock)
        #expect(product.cycles.count == 3)
        #expect(product.fetchedAt == clock)
        #expect(EndOfLifeSource.v1URL("nodejs").absoluteString == "https://endoflife.date/api/v1/products/nodejs/")
        #expect(EndOfLifeSource.legacyURL("nodejs").absoluteString == "https://endoflife.date/api/nodejs.json")

        await #expect(throws: EndOfLifeSource.FetchError.invalidSlug) {
            try await EndOfLifeSource(http: http).fetch("../etc", now: clock)
        }
    }
}

// MARK: - Helpers

private func installation(_ id: String, version: String, provider: ProviderID, confidence: AttributionConfidence = .confirmed, linkState: LinkState = .active) -> ToolInstallation {
    ToolInstallation(
        id: InstallationID(id),
        ownership: Ownership(provider: provider, confidence: confidence),
        version: ObservedValue(ToolVersion(version), source: .provider(provider), confidence: .confirmed, observedAt: clock),
        executables: [ExecutableRef(name: "bin", path: "/opt/\(id)/bin")],
        linkState: linkState
    )
}

private func runtime(_ id: ToolID, active: ToolInstallation, others: [ToolInstallation] = []) -> Tool {
    Tool(
        id: id,
        identity: ToolRegistry.standard.definition(id)!.identity,
        installations: [active] + others,
        activeInstallationID: active.id,
        health: ToolHealthState(status: .healthy),
        lastScannedAt: clock
    )
}

actor RecordingEndOfLifeProvider: EndOfLifeProviding {
    struct Request: Hashable, Sendable {
        var slug: String
        var allowNetwork: Bool
    }

    let products: [String: EndOfLifeProduct]
    private(set) var requests: [Request] = []

    init(products: [String: EndOfLifeProduct]) {
        self.products = products
    }

    func product(_ slug: String, allowNetwork: Bool) async -> EndOfLifeProduct? {
        requests.append(Request(slug: slug, allowNetwork: allowNetwork))
        return products[slug]
    }
}

struct StubHTTP: HTTPFetching {
    var responses: [URL: HTTPResponse]

    func get(_ url: URL, timeout: Duration) async throws -> HTTPResponse {
        guard let response = responses[url] else { throw URLError(.notConnectedToInternet) }
        return response
    }
}
