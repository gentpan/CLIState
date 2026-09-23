import CLIStateDomain
import Foundation

/// The `#!` line of a script, read from a bounded prefix of the file. Never
/// executes anything; binaries and files without a complete first line yield `nil`.
struct Shebang: Hashable, Sendable {
    /// Interpreter path exactly as written, e.g. `/opt/homebrew/opt/python@3.14/bin/python3.14`.
    var interpreter: String
    /// Everything after the interpreter (`python3` in `#!/usr/bin/env python3`).
    var argument: String?

    /// Enough for any real interpreter line; macOS itself only honours 512 bytes.
    static let maxLength = 512

    static func read(atPath path: String, fileSystem: any FileSystem) -> Shebang? {
        guard fileSystem.attributes(atPath: path)?.kind == .file,
              let data = try? fileSystem.readData(atPath: path, maxBytes: maxLength)
        else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Shebang? {
        let bytes = [UInt8](data.prefix(maxLength))
        guard bytes.count > 2, bytes[0] == UInt8(ascii: "#"), bytes[1] == UInt8(ascii: "!") else { return nil }
        // A line cut off by the read limit could name a different interpreter.
        guard let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) ?? (data.count < maxLength ? bytes.count : nil) else { return nil }
        guard let line = String(bytes: bytes[2..<newline], encoding: .utf8) else { return nil }
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
        let end = trimmed.firstIndex { $0 == " " || $0 == "\t" } ?? trimmed.endIndex
        let interpreter = String(trimmed[..<end])
        guard interpreter.hasPrefix("/"), !interpreter.contains("\0") else { return nil }
        let rest = trimmed[end...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return Shebang(interpreter: interpreter, argument: rest.isEmpty ? nil : rest)
    }
}

/// uv-managed interpreters live in `<python dir>/<implementation>-<version>[+variant]-<os>-<arch>-<libc>`,
/// e.g. `cpython-3.12.13-macos-aarch64-none` or `cpython-3.13.1+freethreaded-macos-aarch64-none`.
struct UVPythonDirectory: Hashable, Sendable {
    var implementation: String
    var version: String

    init?(name: String) {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 5, !parts[0].isEmpty else { return nil }
        // The build variant is not part of the version the interpreter reports.
        let version = parts[1].split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let first = version.first, first.isASCII, first.isNumber, version.contains(".") else { return nil }
        self.implementation = String(parts[0])
        self.version = String(version)
    }

    var isCPython: Bool { implementation == "cpython" }
}

/// Cargo's own record of `cargo install`: `$CARGO_HOME/.crates2.json`, keyed
/// `"<crate> <version> (<source>)"` with the binaries each install put in `bin/`.
/// Supporting evidence only; `cargo install --list` stays the inventory.
struct CargoInstallMetadata: Hashable, Sendable {
    struct Install: Hashable, Sendable {
        var crate: String
        var version: String
    }

    static let fileName = ".crates2.json"
    static let maxBytes = 4 << 20

    /// Binary name → the install that owns it.
    var installsByBinary: [String: Install] = [:]

    static func read(cargoHome: String, fileSystem: any FileSystem) -> CargoInstallMetadata {
        guard let data = try? fileSystem.readData(atPath: "\(cargoHome)/\(fileName)", maxBytes: maxBytes) else { return CargoInstallMetadata() }
        return parse(data)
    }

    static func parse(_ data: Data) -> CargoInstallMetadata {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installs = root["installs"] as? [String: Any]
        else { return CargoInstallMetadata() }
        var metadata = CargoInstallMetadata()
        for key in installs.keys.sorted() {
            let parts = key.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, let bins = (installs[key] as? [String: Any])?["bins"] as? [String] else { continue }
            let install = Install(crate: String(parts[0]), version: String(parts[1]))
            for bin in bins where !bin.isEmpty && metadata.installsByBinary[bin] == nil {
                metadata.installsByBinary[bin] = install
            }
        }
        return metadata
    }
}

/// The `version` a JavaScript package declares in its own `package.json`.
enum PackageManifest {
    static let maxBytes = 1 << 20

    static func version(packageDirectory: String, expectedName: String, fileSystem: any FileSystem) -> String? {
        guard let data = try? fileSystem.readData(atPath: "\(packageDirectory)/package.json", maxBytes: maxBytes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = (object["version"] as? String)?.trimmingCharacters(in: .whitespaces), !version.isEmpty
        else { return nil }
        if let name = object["name"] as? String, name != expectedName { return nil }
        return version
    }
}
