import CLIStateDomain
import Foundation

public enum VersionParser {
    /// Dotted version with optional `v` prefix and `-prerelease`: `v26.2.0`, `2.1.234`, `0.0.0-next-15329`.
    public static let genericPattern = #"(?<![0-9A-Za-z.])v?([0-9]+(?:\.[0-9]+)+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?)"#

    /// First capture group of `pattern` (or the generic pattern) in `output`.
    public static func parse(_ output: String, pattern: String? = nil) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern ?? genericPattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = expression.firstMatch(in: output, range: range) else { return nil }
        let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
        guard group.location != NSNotFound, let swiftRange = Range(group, in: output) else { return nil }
        let value = output[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Runs version probes safely (plan §6.6, F5). Callers decide *what* to probe
/// (registry tools only); this type decides *whether it is safe* and runs it.
public struct VersionDetector: Sendable {
    public struct Request: Hashable, Sendable {
        /// Path to execute, as found in PATH (keeps argv[0] intact for multi-call binaries).
        public var executablePath: String
        /// Cache key.
        public var resolvedPath: String
        public var probe: VersionProbe
        public var requiresJavaHome: Bool

        public init(executablePath: String, resolvedPath: String? = nil, probe: VersionProbe, requiresJavaHome: Bool = false) {
            self.executablePath = executablePath
            self.resolvedPath = resolvedPath ?? executablePath
            self.probe = probe
            self.requiresJavaHome = requiresJavaHome
        }

        /// e.g. `node --version`; stored in `CachedVersion.probe`.
        public var probeDescription: String {
            ([PathUtil.lastComponent(executablePath)] + probe.arguments).joined(separator: " ")
        }

        /// Outcome key. Includes the probe because multi-call binaries (rustup
        /// proxies) share one resolved path but answer differently per name.
        public var key: String { resolvedPath + "\u{0}" + probeDescription }
    }

    public enum Outcome: Hashable, Sendable {
        case probed(version: String?, probe: String)
        case cached(version: String?, probe: String)
        /// A safety check failed; the executable was not run.
        case skipped(SkipReason)
        case failed
    }

    public enum SkipReason: String, Hashable, Sendable {
        case developerToolsMissing
        case javaRuntimeMissing
        case fileMissing
    }

    public static let xcodeSelect = "/usr/bin/xcode-select"
    public static let javaHome = "/usr/libexec/java_home"

    private let runner: any CommandRunning
    private let fileSystem: any FileSystem
    private let environment: ExecutionEnvironment
    private let timeout: Duration
    private let maxConcurrentProbes: Int
    private let clock: @Sendable () -> Date

    public init(runner: any CommandRunning, fileSystem: any FileSystem, environment: ExecutionEnvironment, timeout: Duration = .seconds(3), maxConcurrentProbes: Int = 6, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.fileSystem = fileSystem
        self.environment = environment
        self.timeout = timeout
        self.maxConcurrentProbes = max(1, maxConcurrentProbes)
        self.clock = clock
    }

    /// Probes each distinct request once. Returns outcomes keyed by `Request.key`
    /// and the cache entries (keyed by resolved path) to persist, reused or fresh.
    public func detect(_ requests: [Request], cache: [String: CachedVersion]) async -> (outcomes: [String: Outcome], cache: [String: CachedVersion]) {
        var unique: [String: Request] = [:]
        for request in requests where unique[request.key] == nil {
            unique[request.key] = request
        }

        var outcomes: [String: Outcome] = [:]
        var newCache: [String: CachedVersion] = [:]
        // Safety checks run once, and only when a probe needs them (F5). They come
        // before the cache: a shim's size and date don't change when the CLT or JDK
        // behind it is removed, and a cached version would keep the stub looking installed.
        var developerToolsAvailable: Bool?
        var javaAvailable: Bool?
        var runnable: [(Request, FileAttributes)] = []
        for request in unique.values.sorted(by: { $0.key < $1.key }) {
            guard let attributes = fileSystem.attributes(atPath: request.resolvedPath) else {
                outcomes[request.key] = .skipped(.fileMissing)
                continue
            }
            // Java first: `/usr/bin/java` is a JavaLaunching stub, so a missing JDK is the
            // more precise reason even when the CLT are missing too.
            if request.requiresJavaHome {
                if javaAvailable == nil { javaAvailable = await check(Self.javaHome, []) }
                if javaAvailable == false {
                    outcomes[request.key] = .skipped(.javaRuntimeMissing)
                    continue
                }
            }
            if Self.needsDeveloperTools(request) {
                if developerToolsAvailable == nil { developerToolsAvailable = await check(Self.xcodeSelect, ["-p"]) }
                if developerToolsAvailable == false {
                    outcomes[request.key] = .skipped(.developerToolsMissing)
                    continue
                }
            }
            if let entry = cache[request.resolvedPath], entry.probe == request.probeDescription,
               entry.size == attributes.size, entry.modifiedAt == attributes.modifiedAt {
                outcomes[request.key] = .cached(version: entry.version, probe: entry.probe)
                newCache[request.resolvedPath] = entry
                continue
            }
            runnable.append((request, attributes))
        }

        let results = await withTaskGroup(of: (Request, FileAttributes, Date, CommandResult?).self) { group in
            var collected: [(Request, FileAttributes, Date, CommandResult?)] = []
            var iterator = runnable.makeIterator()
            var running = 0
            while running < maxConcurrentProbes, let (request, attributes) = iterator.next() {
                group.addTask { await probe(request, attributes) }
                running += 1
            }
            while let result = await group.next() {
                collected.append(result)
                if let (request, attributes) = iterator.next() {
                    group.addTask { await probe(request, attributes) }
                }
            }
            return collected
        }

        for (request, attributes, probedAt, result) in results.sorted(by: { $0.0.key < $1.0.key }) {
            guard let result, result.termination == .exited else {
                outcomes[request.key] = .failed
                continue
            }
            let output = result.stdoutString + "\n" + result.stderrString
            let version = VersionParser.parse(output, pattern: request.probe.pattern)
            outcomes[request.key] = .probed(version: version, probe: request.probeDescription)
            // A failing run without a version may be transient; don't pin it in the cache.
            if version != nil || result.exitCode == 0 {
                newCache[request.resolvedPath] = CachedVersion(version: version, size: attributes.size, modifiedAt: attributes.modifiedAt, probe: request.probeDescription, probedAt: probedAt)
            }
        }
        return (outcomes, newCache)
    }

    /// CLT shims in `/usr/bin` pop up an install dialog when the tools are missing.
    /// Deliberately broader than `developerToolsShimNames`: an unlisted shim must never run.
    static func needsDeveloperTools(_ request: Request) -> Bool {
        PathUtil.isInside(request.executablePath, "/usr/bin") || PathUtil.isInside(request.resolvedPath, "/usr/bin")
    }

    /// `/usr/bin` executables that are only `xcselect` stubs for the Command Line
    /// Tools (they link `libxcselect.dylib`), as opposed to real system binaries such
    /// as `curl` or `sqlite3`. Without the CLT they don't provide the tool at all.
    public static let developerToolsShimNames: Set<String> = [
        "c++", "cc", "clang", "clang++", "g++", "gcc", "git", "git-receive-pack", "git-shell", "git-upload-archive",
        "git-upload-pack", "gm4", "gnumake", "lldb", "m4", "make", "pip3", "python3", "swift", "swiftc", "xcodebuild",
    ]

    /// Whether a skipped probe means the executable is a stub for something that
    /// isn't installed: `/usr/bin/java` without a JDK, `/usr/bin/git` without the CLT.
    public static func indicatesMissingStubTarget(_ outcome: Outcome?, executablePath: String) -> Bool {
        switch outcome {
        case .skipped(.javaRuntimeMissing)?:
            return AttributionEngine.isOperatingSystemLocation(executablePath)
        case .skipped(.developerToolsMissing)?:
            return PathUtil.isInside(executablePath, "/usr/bin") && developerToolsShimNames.contains(PathUtil.lastComponent(executablePath))
        default:
            return false
        }
    }

    private func check(_ executable: String, _ arguments: [String]) async -> Bool {
        let command = Command(executable: executable, arguments: arguments, timeout: timeout)
        guard let result = try? await runner.run(command, environment: environment) else { return false }
        return result.succeeded
    }

    /// Records the start time: running the executable updates its access time (lastUsedAt).
    private func probe(_ request: Request, _ attributes: FileAttributes) async -> (Request, FileAttributes, Date, CommandResult?) {
        let probedAt = clock()
        return (request, attributes, probedAt, await run(request))
    }

    private func run(_ request: Request) async -> CommandResult? {
        let command = Command(executable: request.executablePath, arguments: request.probe.arguments, timeout: timeout)
        return try? await runner.run(command, environment: environment)
    }
}
