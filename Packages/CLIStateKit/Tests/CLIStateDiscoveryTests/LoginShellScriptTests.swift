import CLIStateDomain
import CLIStateTestSupport
import Foundation
import Testing
@testable import CLIStateDiscovery

@Suite struct LoginShellScriptTests {
    @Test func parsesBetweenMarkersIgnoringRcNoise() throws {
        let stdout = DiscoveryFixtures.shellOutput(
            environment: [("PATH", "/opt/homebrew/bin:/usr/bin"), ("HOME", "/Users/tester")],
            before: "Welcome back!\n\u{1B}]1337;SetMark\u{07}nvm: lazy loading enabled",
            after: "logout noise from .zlogout\n__CLISTATE_BEGIN__ not again\n"
        )

        let output = try #require(LoginShellScript.parse(stdout))

        #expect(output.variables == ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/tester"])
        #expect(output.shadows.isEmpty)
    }

    @Test func parsesNulSeparatedValuesWithNewlinesAndEquals() throws {
        let certificate = "-----BEGIN CERTIFICATE-----\nMIIB\n__CLISTATE_SHADOWS__\n-----END CERTIFICATE-----"
        let stdout = DiscoveryFixtures.shellOutput(environment: [
            ("PATH", "/usr/bin"),
            ("NODE_EXTRA_CA_CERTS_PEM", certificate),
            ("LESSOPEN", "|lesspipe.sh %s"),
            ("JAVA_TOOL_OPTIONS", "-Dfile.encoding=UTF-8 -Da=b"),
            ("EMPTY", ""),
        ])

        let output = try #require(LoginShellScript.parse(stdout))

        #expect(output.variables["NODE_EXTRA_CA_CERTS_PEM"] == certificate)
        #expect(output.variables["JAVA_TOOL_OPTIONS"] == "-Dfile.encoding=UTF-8 -Da=b")
        #expect(output.variables["LESSOPEN"] == "|lesspipe.sh %s")
        #expect(output.variables["EMPTY"] == "")
        #expect(output.variables.count == 5)
    }

    @Test func missingMarkersReturnNil() {
        #expect(LoginShellScript.parse(Data("PATH=/usr/bin\0".utf8)) == nil)
        #expect(LoginShellScript.parse(Data("\n__CLISTATE_BEGIN__\nPATH=/usr/bin\0".utf8)) == nil)
        #expect(LoginShellScript.parse(Data("\n__CLISTATE_BEGIN__\nPATH=/usr/bin\0\n__CLISTATE_SHADOWS__\nnode: alias".utf8)) == nil)
        #expect(LoginShellScript.parse(Data()) == nil)
    }

    @Test func parsesZshWhenceOutput() throws {
        let stdout = DiscoveryFixtures.shellOutput(
            environment: [("PATH", "/usr/bin")],
            shadowLines: [
                "__CLISTATE_NAME__:node", "node: function", "node: command", "node: command",
                "__CLISTATE_NAME__:ls", "ls: alias", "ls: command",
                "__CLISTATE_NAME__:git", "git: command",
                "__CLISTATE_NAME__:time", "time: reserved",
                "__CLISTATE_NAME__:php", "php: hashed",
                "__CLISTATE_NAME__:echo", "echo: builtin", "echo: command",
                "__CLISTATE_NAME__:missing", "missing: none",
            ]
        )

        let shadows = try #require(LoginShellScript.parse(stdout)).shadows

        #expect(shadows["node"] == [ShellShadow(name: "node", kind: .function)])
        #expect(shadows["ls"] == [ShellShadow(name: "ls", kind: .alias)])
        #expect(shadows["time"] == [ShellShadow(name: "time", kind: .reserved)])
        #expect(shadows["php"] == [ShellShadow(name: "php", kind: .hashed)])
        #expect(shadows["echo"] == [ShellShadow(name: "echo", kind: .builtin)])
        #expect(shadows["git"] == nil)
        #expect(shadows["missing"] == nil)
    }

    @Test func parsesBashTypeOutput() {
        let shadows = LoginShellScript.parseShadows("""
        __CLISTATE_NAME__:ll
        alias
        file
        __CLISTATE_NAME__:nvm
        function
        __CLISTATE_NAME__:if
        keyword
        __CLISTATE_NAME__:git
        file
        file
        __CLISTATE_NAME__:nope
        """)

        #expect(shadows == [
            "ll": [ShellShadow(name: "ll", kind: .alias)],
            "nvm": [ShellShadow(name: "nvm", kind: .function)],
            "if": [ShellShadow(name: "if", kind: .reserved)],
        ])
    }

    @Test func parsesFishTypeOutput() {
        let shadows = LoginShellScript.parseShadows("""
        __CLISTATE_NAME__:ls
        function
        file
        __CLISTATE_NAME__:cd
        function
        builtin
        __CLISTATE_NAME__:rg
        file
        """)

        #expect(shadows["ls"] == [ShellShadow(name: "ls", kind: .function)])
        #expect(shadows["cd"] == [ShellShadow(name: "cd", kind: .function), ShellShadow(name: "cd", kind: .builtin)])
        #expect(shadows["rg"] == nil)
    }

    @Test func scriptUsesShellSpecificLookup() {
        let zsh = LoginShellScript.make(kind: .zsh, shadowCandidates: ["node"])
        let bash = LoginShellScript.make(kind: .bash, shadowCandidates: ["node"])
        let fish = LoginShellScript.make(kind: .fish, shadowCandidates: ["node"])
        let sh = LoginShellScript.make(kind: .sh, shadowCandidates: ["node"])

        #expect(zsh.contains("builtin whence -wa -- node"))
        #expect(bash.contains("builtin type -at -- node"))
        #expect(fish.contains("type -a -t -- node"))
        for script in [zsh, bash, fish, sh] {
            #expect(script.contains("/usr/bin/env -0"))
            #expect(script.contains("__CLISTATE_BEGIN__"))
            #expect(script.contains("__CLISTATE_SHADOWS__"))
            #expect(script.contains("__CLISTATE_END__"))
        }
        #expect(!sh.contains("node"))
        #expect(!sh.contains("whence"))
    }

    @Test(arguments: [
        "node; rm -rf ~", "$(whoami)", "`id`", "a b", "it's", "\"quoted\"", "semi;colon",
        "pipe|x", "new\nline", "", "caf\u{E9}", "back\\slash", "*", "a&b", String(repeating: "a", count: 200),
    ])
    func unsafeShadowNamesNeverReachTheScript(name: String) {
        #expect(!LoginShellScript.isSafeName(name))
        let script = LoginShellScript.make(kind: .zsh, shadowCandidates: ["node", name])
        #expect(script == LoginShellScript.make(kind: .zsh, shadowCandidates: ["node"]))
    }

    @Test func safeNamesAreKeptInOrderWithoutDuplicates() {
        let names = LoginShellScript.sanitizedCandidates(["php", "g++", "python3.12", "claude-code", "_x", "php", "rm -rf"])
        #expect(names == ["php", "g++", "python3.12", "claude-code", "_x"])
    }

    /// Runs the generated script through the real parser shape: every candidate
    /// gets a header line so kinds can be attributed even for bash and fish.
    @Test func everyCandidateGetsAHeader() {
        let script = LoginShellScript.make(kind: .bash, shadowCandidates: ["node", "php"])
        #expect(script.contains("'__CLISTATE_NAME__:node'"))
        #expect(script.contains("'__CLISTATE_NAME__:php'"))
    }
}
