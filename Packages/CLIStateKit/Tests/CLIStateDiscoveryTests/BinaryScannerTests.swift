import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing
@testable import CLIStateDiscovery

@Suite struct BinaryScannerTests {
    let home = DiscoveryFixtures.home

    private func scan(_ fs: FileSystem, path: [String], variables: [String: String] = [:]) async -> ([PATHEntry], BinaryInventory) {
        let (entries, listings) = PATHResolver(fileSystem: fs).resolveWithListings(path: path, variables: variables)
        let inventory = await BinaryScanner(fileSystem: fs).scan(entries, listings: listings)
        return (BinaryScanner.annotate(entries, with: inventory), inventory)
    }

    @Test func developerMacNodeIsShadowedByLocalInstall() async throws {
        let fs = DiscoveryFixtures.developerMac()
        let (entries, inventory) = await scan(fs, path: DiscoveryFixtures.developerPATH)

        let node = inventory.candidates(named: "node")
        #expect(node.map(\.path) == ["\(home)/.local/bin/node", "/opt/homebrew/bin/node"])
        #expect(node.map(\.pathPriority) == [10, 11])
        #expect(node.map(\.resolvedPath) == [
            "\(home)/.local/opt/node-v26.2.0-darwin-arm64/bin/node",
            "/opt/homebrew/Cellar/node/26.7.0/bin/node",
        ])
        #expect(node.allSatisfy { $0.isSymlink })
        #expect(inventory.groups["node"]?.active?.path == "\(home)/.local/bin/node")

        #expect(entries[10].executableCount == 719)
        #expect(entries[9].executableCount == 2)
        #expect(entries[8].executableCount == 0)
        #expect(entries[0].executableCount == 0)

        #expect(inventory.brokenSymlinks == [BrokenSymlink(
            path: "/opt/homebrew/bin/codexbar",
            destination: "/opt/homebrew/Caskroom/codexbar/0.18.0/CodexBar.app/Contents/Helpers/CodexBarCLI",
            pathPriority: 11
        )])
        #expect(inventory.candidates(named: "codexbar").isEmpty)
        #expect(inventory.candidates(named: "python3").map(\.pathPriority) == [11, 15])
        // Duplicate ~/.mavis/bin (#9) is not rescanned.
        #expect(inventory.candidates(named: "mavis").map(\.pathPriority) == [6])
        #expect(inventory.candidates(named: "curl").first?.path == "/System/Cryptexes/App/usr/bin/curl")
    }

    @Test func handlesSymlinksBrokenLinksNonExecutablesAndHiddenFiles() async throws {
        let fs = InMemoryFileSystem(home: home)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        fs.addFile("/opt/homebrew/Cellar/php/8.5.7/bin/php", contents: Data(repeating: 1, count: 4096), executable: true, modifiedAt: modified)
        fs.addSymlink("/opt/homebrew/bin/php", to: "../Cellar/php/8.5.7/bin/php")
        fs.addSymlink("/opt/homebrew/bin/phpize", to: "php")
        fs.addFile("/opt/homebrew/bin/README", contents: Data("docs".utf8), executable: false)
        fs.addFile("/opt/homebrew/Cellar/php/8.5.7/share/config.ini")
        fs.addSymlink("/opt/homebrew/bin/php-config.ini", to: "../Cellar/php/8.5.7/share/config.ini")
        fs.addExecutable("/opt/homebrew/bin/.hidden-tool")
        fs.addSymlink("/opt/homebrew/bin/.hidden-broken", to: "nowhere")
        fs.addDirectory("/opt/homebrew/bin/subdir")
        fs.addExecutable("/opt/homebrew/bin/subdir/nested")
        fs.addSymlink("/opt/homebrew/bin/linked-dir", to: "subdir")
        fs.addSymlink("/opt/homebrew/bin/gone", to: "../Cellar/gone/1.0/bin/gone")
        fs.addSymlink("/opt/homebrew/bin/loop", to: "loop")

        let (entries, inventory) = await scan(fs, path: ["/opt/homebrew/bin"])

        #expect(Set(inventory.groups.keys) == ["php", "phpize"])
        let php = try #require(inventory.candidates(named: "php").first)
        #expect(php == BinaryCandidate(
            name: "php",
            path: "/opt/homebrew/bin/php",
            pathPriority: 1,
            isSymlink: true,
            resolvedPath: "/opt/homebrew/Cellar/php/8.5.7/bin/php",
            size: 4096,
            modifiedAt: modified
        ))
        #expect(inventory.candidates(named: "phpize").first?.resolvedPath == "/opt/homebrew/Cellar/php/8.5.7/bin/php")
        #expect(inventory.brokenSymlinks.map(\.path) == ["/opt/homebrew/bin/gone", "/opt/homebrew/bin/loop"])
        #expect(inventory.brokenSymlinks.first?.destination == "../Cellar/gone/1.0/bin/gone")
        #expect(inventory.brokenSymlinks.first?.absoluteDestination == "/opt/homebrew/Cellar/gone/1.0/bin/gone")
        #expect(entries.first?.executableCount == 2)
    }

    @Test func regularFilesRecordRealDirectory() async throws {
        let fs = InMemoryFileSystem(home: home)
        fs.addExecutable("/opt/tools/bin/tool")
        fs.addSymlink("/usr/local/bin", to: "/opt/tools/bin")

        let (_, inventory) = await scan(fs, path: ["/usr/local/bin"])

        let tool = try #require(inventory.candidates(named: "tool").first)
        #expect(tool.path == "/usr/local/bin/tool")
        #expect(!tool.isSymlink)
        #expect(tool.resolvedPath == "/opt/tools/bin/tool")
    }

    @Test func onlyOkEntriesAreScanned() async {
        let fs = InMemoryFileSystem(home: home)
        fs.addExecutable("/usr/bin/git")
        fs.addExecutable("\(home)/Documents/bin/git")
        let entries = [
            PATHEntry(priority: 1, rawValue: "~/Documents/bin", normalizedPath: "\(home)/Documents/bin", status: .protectedLocation, source: .unknown),
            PATHEntry(priority: 2, rawValue: "/usr/bin", normalizedPath: "/usr/bin", status: .duplicate, source: .system, duplicateOf: 3),
            PATHEntry(priority: 3, rawValue: "/usr/bin", normalizedPath: "/usr/bin", status: .ok, source: .system),
        ]

        let inventory = await BinaryScanner(fileSystem: fs).scan(entries)

        #expect(inventory.candidates(named: "git").map(\.pathPriority) == [3])
    }

    @Test func linksIntoProtectedLocationsAreNotResolved() async throws {
        let base = InMemoryFileSystem(home: home)
        base.addExecutable("\(home)/Documents/scripts/deploy")
        base.addSymlink("\(home)/.local/bin/deploy", to: "../../Documents/scripts/deploy")
        let fs = TouchRecordingFileSystem(base: base)

        let (_, inventory) = await scan(fs, path: ["~/.local/bin"])

        let deploy = try #require(inventory.candidates(named: "deploy").first)
        #expect(deploy.resolvedPath == "\(home)/Documents/scripts/deploy")
        #expect(deploy.size == nil)
        #expect(!fs.touchedPaths.contains { ProtectedLocations(home: home).contains($0) })
    }

    @Test func resultIsDeterministicAcrossRuns() async {
        let fs = DiscoveryFixtures.developerMac()
        let (_, first) = await scan(fs, path: DiscoveryFixtures.developerPATH)
        for concurrency in [1, 3, 16] {
            let entries = PATHResolver(fileSystem: fs).resolve(path: DiscoveryFixtures.developerPATH)
            let again = await BinaryScanner(fileSystem: fs, maximumConcurrentDirectories: concurrency).scan(entries)
            #expect(again == first)
        }
    }

    @Test func scansHundredDirectoriesOfFiftyBinariesQuickly() async {
        let fs = InMemoryFileSystem(home: home)
        var path: [String] = []
        for directory in 0..<100 {
            let bin = "/opt/synthetic/\(directory)/bin"
            path.append(bin)
            for binary in 0..<50 {
                if binary.isMultiple(of: 5) {
                    fs.addExecutable("/opt/synthetic/\(directory)/libexec/tool\(binary)")
                    fs.addSymlink("\(bin)/tool\(binary)", to: "../libexec/tool\(binary)")
                } else {
                    fs.addExecutable("\(bin)/tool\(binary)")
                }
            }
        }

        let clock = ContinuousClock()
        let start = clock.now
        let (entries, inventory) = await scan(fs, path: path)
        let elapsed = clock.now - start

        #expect(inventory.executableCount == 5000)
        #expect(inventory.groups.count == 50)
        #expect(inventory.candidates(named: "tool7").map(\.pathPriority) == Array(1...100))
        #expect(entries.allSatisfy { $0.executableCount == 50 })
        // Shared CI runners are several times slower than a developer Mac.
        let limit: Duration = ProcessInfo.processInfo.environment["CI"] == nil ? .seconds(2) : .seconds(15)
        #expect(elapsed < limit, "scan took \(elapsed)")
    }
}
