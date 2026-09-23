import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing
@testable import CLIStateDiscovery

@Suite struct PATHResolverTests {
    let home = DiscoveryFixtures.home

    @Test func developerMacPATH() {
        let fs = DiscoveryFixtures.developerMac()
        let entries = PATHResolver(fileSystem: fs).resolve(
            path: DiscoveryFixtures.developerPATH,
            variables: ["HOMEBREW_PREFIX": "/opt/homebrew"]
        )

        #expect(entries.count == 23)
        #expect(entries.map(\.priority) == Array(1...23))

        let herd = entries[0]
        #expect(herd.rawValue == "\(home)/Library/Application Support/Herd/bin/")
        #expect(herd.normalizedPath == "\(home)/Library/Application Support/Herd/bin")
        #expect(herd.status == .missing)
        #expect(herd.source == .unknown)

        #expect(entries[5].status == .ok)
        #expect(entries[8].normalizedPath == "\(home)/.mavis/bin")
        #expect(entries[8].status == .duplicate)
        #expect(entries[8].duplicateOf == 6)

        #expect(entries[6].source == .bun)
        #expect(entries[7].source == .cargo)
        #expect(entries[9].source == .userLocal)
        #expect(entries[10].source == .homebrew)
        #expect(entries[11].source == .homebrew)
        #expect(entries[12].source == .userLocal)
        #expect(entries[13].source == .system)
        #expect(entries[13].status == .ok)
        #expect(entries[14...17].allSatisfy { $0.source == .system && $0.status == .ok })

        let codexBootstrap = entries[19]
        #expect(codexBootstrap.normalizedPath == "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin")
        #expect(codexBootstrap.status == .missing)
        #expect(codexBootstrap.source == .system)

        #expect(entries[21].normalizedPath == "/pkg/env/global/bin")
        #expect(entries[21].status == .missing)
        #expect(entries[21].source == .unknown)
        #expect(entries[22].source == .system)
        #expect(entries[22].status == .ok)

        #expect(entries.filter { $0.status == .ok }.count == 17)
        #expect(entries.filter { $0.status == .missing }.count == 5)
    }

    @Test func normalizesTildeAndTrailingSlashesKeepingRawValue() {
        let fs = InMemoryFileSystem(home: home)
        fs.addDirectory("\(home)/.local/bin")
        let resolver = PATHResolver(fileSystem: fs)

        #expect(resolver.normalize("~/.local/bin/") == "\(home)/.local/bin")
        #expect(resolver.normalize("~") == home)
        #expect(resolver.normalize("/") == "/")
        #expect(resolver.normalize("///") == "/")
        #expect(resolver.normalize("/usr/bin//") == "/usr/bin")
        #expect(resolver.normalize("~other/bin") == "~other/bin")

        let entries = resolver.resolve(path: ["~/.local/bin/", "/", "~/.local/bin"])
        #expect(entries[0].rawValue == "~/.local/bin/")
        #expect(entries[0].normalizedPath == "\(home)/.local/bin")
        #expect(entries[0].status == .ok)
        #expect(entries[0].isWritable)
        #expect(entries[1].normalizedPath == "/")
        #expect(entries[1].status == .ok)
        #expect(entries[2].status == .duplicate)
        #expect(entries[2].duplicateOf == 1)
    }

    @Test func flagsEmptyRelativeMissingAndNotDirectory() {
        let fs = InMemoryFileSystem(home: home)
        fs.addFile("/opt/tool/bin", contents: Data("not a directory".utf8))
        let entries = PATHResolver(fileSystem: fs).resolve(path: ["", ".", "bin", "node_modules/.bin", "~other/bin", "/nope", "/opt/tool/bin"])

        #expect(entries.map(\.status) == [.empty, .relative, .relative, .relative, .relative, .missing, .notDirectory])
        #expect(entries.allSatisfy { !$0.isWritable && $0.executableCount == 0 && $0.duplicateOf == nil })
    }

    @Test func duplicateByRealPath() {
        let fs = InMemoryFileSystem(home: home)
        fs.addDirectory("/opt/homebrew/bin")
        fs.addSymlink("/usr/local/bin", to: "/opt/homebrew/bin")
        fs.addSymlink("\(home)/bin", to: "../../opt/homebrew/bin")
        fs.addDirectory("/usr/bin")

        let entries = PATHResolver(fileSystem: fs).resolve(path: ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/bin", "/usr/bin/"])

        #expect(entries.map(\.status) == [.ok, .ok, .duplicate, .duplicate, .duplicate])
        #expect(entries.map(\.duplicateOf) == [nil, nil, 2, 2, 1])
    }

    @Test func symlinkToMissingDirectoryIsMissing() {
        let fs = InMemoryFileSystem(home: home)
        fs.addSymlink("/usr/local/bin", to: "/Volumes/Gone/bin")
        #expect(PATHResolver(fileSystem: fs).resolve(path: ["/usr/local/bin"]).first?.status == .missing)
    }

    @Test func unreadableDirectory() {
        let fs = UnreadableDirectoryFileSystem(base: InMemoryFileSystem(home: home), unreadable: "/opt/locked/bin")
        fs.base.addDirectory("/opt/locked/bin")
        fs.base.addExecutable("/opt/locked/bin/secret")

        let entries = PATHResolver(fileSystem: fs).resolve(path: ["/opt/locked/bin"])
        #expect(entries.first?.status == .unreadable)
    }

    @Test func skipsTCCProtectedLocationsWithoutTouchingThem() {
        let base = InMemoryFileSystem(home: home)
        base.addExecutable("\(home)/Documents/bin/tool")
        base.addDirectory("\(home)/Library/Mobile Documents/com~apple~CloudDocs/bin")
        base.addDirectory("\(home)/Library/CloudStorage/Dropbox/bin")
        base.addDirectory("\(home)/Desktop")
        base.addDirectory("\(home)/Downloads/x/bin")
        base.addSymlink("\(home)/tools", to: "Documents/bin")
        base.addDirectory("\(home)/Documentation/bin")
        let fs = TouchRecordingFileSystem(base: base)

        let entries = PATHResolver(fileSystem: fs).resolve(path: [
            "~/Documents/bin",
            "~/Library/Mobile Documents/com~apple~CloudDocs/bin",
            "~/Library/CloudStorage/Dropbox/bin/",
            "~/Desktop",
            "\(home)/downloads/x/bin",
            "~/Desktop/../Documents/bin",
            "~/tools",
            "~/Documentation/bin",
        ])

        #expect(entries.map(\.status) == [
            .protectedLocation, .protectedLocation, .protectedLocation, .protectedLocation,
            .protectedLocation, .protectedLocation, .protectedLocation, .ok,
        ])
        let touched = fs.touchedPaths
        #expect(!touched.contains { ProtectedLocations(home: home).contains($0) })
        #expect(touched.contains("\(home)/tools"))
    }

    @Test(arguments: [
        ("/opt/homebrew/opt/python@3.13/libexec/bin", PATHSource.homebrew),
        ("/usr/local/Homebrew/bin", .homebrew),
        ("/usr/libexec", .system),
        ("/System/Cryptexes/OS/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers", .system),
        ("/Library/Apple/usr/bin", .system),
        ("/private/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin", .system),
        ("/Users/tester/.cargo/bin", .cargo),
        ("/Users/tester/go/bin", .go),
        ("/Users/tester/.bun/bin", .bun),
        ("/Users/tester/.nvm/versions/node/v22.11.0/bin", .versionManager),
        ("/Users/tester/.volta/bin", .versionManager),
        ("/Users/tester/.asdf/shims", .versionManager),
        ("/Users/tester/.local/share/mise/shims", .versionManager),
        ("/Users/tester/.pyenv/shims", .versionManager),
        ("/Users/tester/.rbenv/shims", .versionManager),
        ("/Users/tester/Library/Application Support/fnm/node-versions/v22/installation/bin", .versionManager),
        ("/Users/tester/.local/state/fnm_multishells/123_456/bin", .versionManager),
        ("/Applications/Visual Studio Code.app/Contents/Resources/app/bin", .application),
        ("/Applications/Ghostty.app/Contents/MacOS", .application),
        ("/Users/tester/.local/bin", .userLocal),
        ("/usr/local/bin", .userLocal),
        ("/Users/tester/bin", .userLocal),
        ("/Users/tester/Library/pnpm", .unknown),
        ("/Users/tester/.kimi-code/bin", .unknown),
    ])
    func classifiesSources(path: String, expected: PATHSource) {
        let classifier = PATHSourceClassifier(home: home, variables: [:])
        #expect(classifier.classify(path) == expected)
    }

    @Test func classifiesFromSessionVariables() {
        let classifier = PATHSourceClassifier(home: home, variables: [
            "HOMEBREW_PREFIX": "/usr/local",
            "CARGO_HOME": "/Users/tester/.rust/cargo/",
            "GOBIN": "/Users/tester/.gobin",
            "GOPATH": "/Users/tester/code/go",
            "NPM_CONFIG_PREFIX": "/Users/tester/.npm-global",
            "NVM_DIR": "/Users/tester/.config/nvm",
            "BUN_INSTALL": "/Users/tester/.bun-custom",
        ])

        #expect(classifier.classify("/usr/local/bin") == .homebrew)
        #expect(classifier.classify("/Users/tester/.rust/cargo/bin") == .cargo)
        #expect(classifier.classify("/Users/tester/.gobin") == .go)
        #expect(classifier.classify("/Users/tester/code/go/bin") == .go)
        #expect(classifier.classify("/Users/tester/.npm-global/bin") == .npm)
        #expect(classifier.classify("/Users/tester/.config/nvm/versions/node/v20/bin") == .versionManager)
        #expect(classifier.classify("/Users/tester/.bun-custom/bin") == .bun)
    }
}

/// Wraps a filesystem and records every path passed to it.
final class TouchRecordingFileSystem: FileSystem, @unchecked Sendable {
    let base: InMemoryFileSystem
    private let lock = NSLock()
    private var touched: [String] = []

    init(base: InMemoryFileSystem) { self.base = base }

    var touchedPaths: [String] { lock.withLock { touched } }
    var homeDirectory: String { base.homeDirectory }

    private func touch(_ path: String) { lock.withLock { touched.append(path) } }

    func attributes(atPath path: String) -> FileAttributes? { touch(path); return base.attributes(atPath: path) }
    func contentsOfDirectory(atPath path: String) throws -> [String] { touch(path); return try base.contentsOfDirectory(atPath: path) }
    func destinationOfSymbolicLink(atPath path: String) throws -> String { touch(path); return try base.destinationOfSymbolicLink(atPath: path) }
    func resolvingSymlinks(atPath path: String) -> String? { touch(path); return base.resolvingSymlinks(atPath: path) }
    func isExecutableFile(atPath path: String) -> Bool { touch(path); return base.isExecutableFile(atPath: path) }
    func isWritable(atPath path: String) -> Bool { touch(path); return base.isWritable(atPath: path) }
    func readData(atPath path: String, maxBytes: Int?) throws -> Data { touch(path); return try base.readData(atPath: path, maxBytes: maxBytes) }
}

/// Listing one directory fails with a permission error.
struct UnreadableDirectoryFileSystem: FileSystem {
    let base: InMemoryFileSystem
    let unreadable: String

    var homeDirectory: String { base.homeDirectory }
    func attributes(atPath path: String) -> FileAttributes? { base.attributes(atPath: path) }
    func contentsOfDirectory(atPath path: String) throws -> [String] {
        if path == unreadable { throw CocoaError(.fileReadNoPermission) }
        return try base.contentsOfDirectory(atPath: path)
    }
    func destinationOfSymbolicLink(atPath path: String) throws -> String { try base.destinationOfSymbolicLink(atPath: path) }
    func resolvingSymlinks(atPath path: String) -> String? { base.resolvingSymlinks(atPath: path) }
    func isExecutableFile(atPath path: String) -> Bool { base.isExecutableFile(atPath: path) }
    func isWritable(atPath path: String) -> Bool { base.isWritable(atPath: path) }
    func readData(atPath path: String, maxBytes: Int?) throws -> Data { try base.readData(atPath: path, maxBytes: maxBytes) }
}
