import CLIStateDomain
@testable import CLIStateEngine
import Foundation
import Testing

@Suite("ToolRegistry")
struct ToolRegistryTests {
    let registry = ToolRegistry.standard

    @Test func containsEveryPlannedTool() {
        let expected = [
            "php", "node", "python", "go", "rust", "ruby", "java", "bun", "deno", "git", "gh", "ffmpeg", "imagemagick",
            "wget", "curl", "jq", "ripgrep", "fzf", "tmux", "nginx", "caddy", "redis", "postgresql", "mysql", "mongodb",
            "sqlite", "claude-code", "gemini-cli", "kimi-cli", "codex", "opencode", "aider", "qwen-code", "copilot-cli",
            "homebrew", "npm", "pnpm", "yarn", "pip", "pipx", "uv", "cargo", "rustup", "composer", "gem",
        ] + [
            // Environment restore templates (Lane N).
            "ruff", "jupyterlab", "duckdb", "golangci-lint", "gopls", "rust-analyzer", "cargo-nextest", "xcodes",
            "swiftlint", "swiftformat", "xcbeautify", "cocoapods", "fastlane", "kubectl", "helm", "k9s", "terraform", "awscli",
        ]
        #expect(Set(registry.definitions.map(\.id.rawValue)) == Set(expected))
        #expect(registry.definitions.count == expected.count)
        for definition in registry.definitions {
            #expect(!definition.id.rawValue.contains("."), "IDs carry no category (C12)")
            #expect(definition.homepage != nil)
        }
    }

    @Test func matchesPackagesIncludingVersionedFormulae() {
        #expect(registry.definition(forPackage: "php@8.2", provider: .homebrew)?.id == "php")
        #expect(registry.definition(forPackage: "postgresql@17", provider: .homebrew)?.id == "postgresql")
        #expect(registry.definition(forPackage: "python@3.14", provider: .homebrew)?.id == "python")
        #expect(registry.definition(forPackage: "mongodb/brew/mongodb-community", provider: .homebrew)?.id == "mongodb")
        #expect(registry.definition(forPackage: "@anthropic-ai/claude-code", provider: .npm)?.id == "claude-code")
        #expect(registry.definition(forPackage: "kimi-cli", provider: .uv)?.id == "kimi-cli")
        #expect(registry.definition(forPackage: "openssl@3", provider: .homebrew) == nil)
        #expect(registry.definition(forPackage: "php", provider: .npm) == nil)
    }

    @Test func exposesCommandNamesAndNativeKnowledge() throws {
        let names = registry.commandNames
        #expect(names.contains("claude") && names.contains("rg") && names.contains("python3"))
        #expect(names == names.sorted())

        let claude = try #require(registry.definition("claude-code"))
        #expect(claude.primaryExecutable == "claude")
        #expect(claude.updateSource == .npmDistTags(package: "@anthropic-ai/claude-code", channel: "latest"))
        #expect(claude.selfUpdateCommand(executablePath: "/Users/tester/.local/bin/claude")?.arguments == ["update"])
        #expect(claude.nativeLayouts.first?.hasVersionInPath == true)
        #expect(registry.definition("uv")?.selfUpdateArguments == ["self", "update"])
        #expect(registry.definition("rustup")?.selfUpdateArguments == ["self", "update"])
        #expect(registry.definition("bun")?.selfUpdateArguments == ["upgrade"])
        #expect(registry.definition("java")?.requiresJavaHome == true)
        #expect(registry.definition(forExecutable: "npx")?.id == "npm")
    }
}

@Suite("VersionParser")
struct VersionParserTests {
    private func probeOutput(_ tool: ToolID, _ output: String) -> String? {
        VersionParser.parse(output, pattern: ToolRegistry.standard.definition(tool)?.versionProbe?.pattern)
    }

    @Test func parsesRealProbeOutputs() {
        #expect(probeOutput("node", "v26.2.0\n") == "26.2.0")
        #expect(probeOutput("claude-code", "2.1.234 (Claude Code)\n") == "2.1.234")
        #expect(probeOutput("go", "go version go1.25.1 darwin/arm64\n") == "1.25.1")
        #expect(probeOutput("java", "openjdk version \"21.0.2\" 2024-01-16\nOpenJDK Runtime Environment") == "21.0.2")
        #expect(probeOutput("ffmpeg", "ffmpeg version 8.1.2 Copyright (c) 2000-2026 the FFmpeg developers") == "8.1.2")
        #expect(probeOutput("tmux", "tmux 3.5a\n") == "3.5a")
        #expect(probeOutput("nginx", "\nnginx version: nginx/1.29.1\n") == "1.29.1")
        #expect(probeOutput("caddy", "v2.10.2 h1:g/gTYjGMD0dec+UgMw8SnfmJ3I9+M2TdvoRL/Ovu6U8=\n") == "2.10.2")
        #expect(probeOutput("redis", "Redis server v=8.2.1 sha=00000000:0 malloc=libc bits=64") == "8.2.1")
        #expect(probeOutput("imagemagick", "Version: ImageMagick 7.1.2-3 Q16-HDRI aarch64") == "7.1.2-3")
        #expect(probeOutput("git", "git version 2.50.1 (Apple Git-155)") == "2.50.1")
        #expect(probeOutput("uv", "uv 0.11.8 (0e961dd9a 2026-04-27 aarch64-apple-darwin)") == "0.11.8")
        #expect(probeOutput("jq", "jq-1.8.1") == "1.8.1")
        #expect(probeOutput("mongodb", "db version v8.0.4\nBuild Info: {}") == "8.0.4")
        #expect(VersionParser.parse("no version here") == nil)
    }
}

@Suite("MachOReader")
struct MachOReaderTests {
    private func arch(_ bytes: [UInt8]) -> CPUArchitecture {
        MachOReader.architecture(ofHeader: Data(bytes))
    }

    private func fat(_ magic: [UInt8], _ cpuTypes: [UInt32], is64: Bool = false) -> [UInt8] {
        var bytes = magic + [0, 0, 0, UInt8(cpuTypes.count)]
        for type in cpuTypes {
            bytes += [UInt8(type >> 24), UInt8(type >> 16 & 0xff), UInt8(type >> 8 & 0xff), UInt8(type & 0xff)]
            bytes += [UInt8](repeating: 0, count: is64 ? 28 : 16)
        }
        return bytes
    }

    @Test func thinHeadersInBothEndiannesses() {
        #expect(arch(MachOHeader.arm64) == .arm64)
        #expect(arch(MachOHeader.x86_64) == .x86_64)
        #expect(arch([0xce, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01]) == .x86_64)  // 32-bit magic, little-endian
        #expect(arch([0xfe, 0xed, 0xfa, 0xcf, 0x01, 0x00, 0x00, 0x0c]) == .arm64)   // 64-bit, big-endian
        #expect(arch([0xfe, 0xed, 0xfa, 0xce, 0x00, 0x00, 0x00, 0x12]) == .unknown) // big-endian PowerPC
    }

    @Test func fatHeaders() {
        #expect(arch(fat([0xca, 0xfe, 0xba, 0xbe], [0x0100_0007, 0x0100_000c])) == .universal)
        #expect(arch(fat([0xca, 0xfe, 0xba, 0xbe], [0x0100_0007])) == .x86_64)
        #expect(arch(fat([0xca, 0xfe, 0xba, 0xbf], [0x0100_000c, 0x0100_0007], is64: true)) == .universal)
        #expect(arch(fat([0xca, 0xfe, 0xba, 0xbf], [0x0100_000c], is64: true)) == .arm64)
    }

    @Test func scriptsJavaClassesAndGarbage() {
        #expect(arch(Array("#!/usr/bin/env node\n".utf8)) == .script)
        #expect(arch([0xca, 0xfe, 0xba, 0xbe, 0x00, 0x00, 0x00, 0x41]) == .unknown)
        #expect(arch([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0]) == .unknown)
        #expect(arch([0xcf, 0xfa]) == .unknown)
    }

    @Test func readsAtMostHeaderLengthFromFileSystem() {
        let scenario = EngineScenario(path: [])
        scenario.binary("/opt/homebrew/Cellar/node/26.7.0/bin/node", header: MachOHeader.arm64 + [UInt8](repeating: 0, count: 10_000))
        let reader = MachOReader(fileSystem: scenario.fs)
        #expect(reader.architecture(atPath: "/opt/homebrew/Cellar/node/26.7.0/bin/node") == .arm64)
        #expect(reader.architecture(atPath: "/missing") == nil)
    }
}
