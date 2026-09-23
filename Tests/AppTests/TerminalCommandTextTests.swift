import CLIStateDomain
import Testing

@Suite("Copyable terminal commands")
struct TerminalCommandTextTests {
    @Test func preservesProviderPathEnvironmentAndArguments() {
        let command = Command(executable: "/opt/homebrew/bin/brew", arguments: ["uninstall", "--cask", "1password"], environmentOverrides: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
        #expect(TerminalCommandText.render([.command(command)]) == "/usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 /opt/homebrew/bin/brew uninstall --cask 1password")
    }

    @Test func quotesShellSyntaxAndWorkingDirectory() {
        let command = Command(executable: "/a path/tool", arguments: ["a'b", "$(touch /tmp/unwanted)", ""], workingDirectory: "/a path")
        #expect(TerminalCommandText.render([.command(command)]) == "(cd -- '/a path' && '/a path/tool' 'a'\\''b' '$(touch /tmp/unwanted)' '')")
    }

    @Test func stopsOnFailureAndRejectsIncompletePlans() {
        let step = OperationStep.command(Command(executable: "/bin/true"))
        #expect(TerminalCommandText.render([step, step]) == "/bin/true &&\n/bin/true")
        #expect(TerminalCommandText.render([]) == nil)
        #expect(TerminalCommandText.render([step, .moveToTrash(path: "/example")]) == nil)
    }
}
