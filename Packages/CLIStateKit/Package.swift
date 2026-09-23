// swift-tools-version: 6.0
import PackageDescription

// Module boundaries (docs/CLIState-合并开发方案.md §5):
//
//   CLIStateApplication ──┬─> CLIStateDiscovery ─────┐
//                         ├─> CLIStateProviders ─────┤
//                         ├─> CLIStateEngine ────────┼─> CLIStateDomain (Foundation only)
//                         └─> CLIStateInfrastructure ┘
//
// Discovery, Providers and Engine depend only on Domain protocols
// (CommandRunning, FileSystem), never on each other or on Infrastructure.
let package = Package(
    name: "CLIStateKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CLIStateDomain", targets: ["CLIStateDomain"]),
        .library(name: "CLIStateInfrastructure", targets: ["CLIStateInfrastructure"]),
        .library(name: "CLIStateDiscovery", targets: ["CLIStateDiscovery"]),
        .library(name: "CLIStateProviders", targets: ["CLIStateProviders"]),
        .library(name: "CLIStateEngine", targets: ["CLIStateEngine"]),
        .library(name: "CLIStateApplication", targets: ["CLIStateApplication"]),
        .library(name: "CLIStateAI", targets: ["CLIStateAI"]),
        .executable(name: "clistate-probe", targets: ["clistate-probe"]),
    ],
    targets: [
        .target(name: "CLIStateDomain"),
        .target(name: "CLIStateInfrastructure", dependencies: ["CLIStateDomain"]),
        .target(name: "CLIStateDiscovery", dependencies: ["CLIStateDomain"]),
        .target(name: "CLIStateProviders", dependencies: ["CLIStateDomain"]),
        .target(name: "CLIStateEngine", dependencies: ["CLIStateDomain"]),
        .target(
            name: "CLIStateApplication",
            dependencies: [
                "CLIStateDomain",
                "CLIStateInfrastructure",
                "CLIStateDiscovery",
                "CLIStateProviders",
                "CLIStateEngine",
            ]
        ),
        // AI explanations (Lane K): prompt building, OpenAI-compatible and on-device clients.
        .target(name: "CLIStateAI", dependencies: ["CLIStateDomain"]),
        .executableTarget(
            name: "clistate-probe",
            dependencies: ["CLIStateApplication", "CLIStateDomain", "CLIStateInfrastructure", "CLIStateDiscovery", "CLIStateProviders", "CLIStateEngine"]
        ),

        .target(name: "CLIStateTestSupport", dependencies: ["CLIStateDomain"], path: "Tests/CLIStateTestSupport"),
        .testTarget(name: "CLIStateDomainTests", dependencies: ["CLIStateDomain", "CLIStateTestSupport"]),
        .testTarget(name: "CLIStateInfrastructureTests", dependencies: ["CLIStateInfrastructure", "CLIStateTestSupport"]),
        .testTarget(name: "CLIStateDiscoveryTests", dependencies: ["CLIStateDiscovery", "CLIStateTestSupport"]),
        .testTarget(
            name: "CLIStateProvidersTests",
            dependencies: ["CLIStateProviders", "CLIStateTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "CLIStateEngineTests", dependencies: ["CLIStateEngine", "CLIStateTestSupport"]),
        .testTarget(name: "CLIStateApplicationTests", dependencies: ["CLIStateApplication", "CLIStateTestSupport"]),
        .testTarget(name: "CLIStateAITests", dependencies: ["CLIStateAI", "CLIStateTestSupport"]),
    ]
)
