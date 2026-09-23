import CLIStateDomain
@testable import CLIStateInfrastructure
import Testing

@Suite struct TerminalTextTests {
    @Test(arguments: [
        ("\u{1B}[31mred\u{1B}[0m plain", "red plain"),
        ("\u{1B}[1;38;5;208mbold\u{1B}[m", "bold"),
        ("\u{1B}[?25lhidden cursor\u{1B}[?25h", "hidden cursor"),
        ("\u{1B}]0;window title\u{07}after", "after"),
        ("\u{1B}]8;;https://brew.sh\u{1B}\\link\u{1B}]8;;\u{1B}\\", "link"),
        ("\u{1B}(Bcharset", "charset"),
        ("\u{1B}7saved\u{1B}8", "saved"),
        ("\u{9B}32mC1 CSI", "C1 CSI"),
        ("\u{1B}]unterminated\nnext line", "\nnext line"),
        ("trailing escape\u{1B}", "trailing escape"),
        ("中文 \u{1B}[32m✔\u{1B}[0m", "中文 ✔"),
    ])
    func stripsEscapeSequences(input: String, expected: String) {
        #expect(TerminalText.strippingANSI(input) == expected)
    }

    @Test func carriageReturnKeepsTextAfterLastReturn() {
        #expect(TerminalText.strippingANSI("10%\r50%\r100%\ndone") == "100%\ndone")
        #expect(TerminalText.strippingANSI("\u{1B}[2K\rDownloading\u{1B}[0K\rInstalled") == "Installed")
    }

    @Test func crlfIsALineEndingNotAnOverwrite() {
        #expect(TerminalText.strippingANSI("first\r\nsecond\r\n") == "first\nsecond\n")
        #expect(TerminalText.strippingANSI("step 1\rstep 2\r\nnext") == "step 2\nnext")
    }

    @Test func plainTextIsUnchanged() {
        let text = "==> Upgrading php\n  8.4.12 -> 8.5.7\n\n"
        #expect(TerminalText.strippingANSI(text) == text)
        #expect(TerminalText.strippingANSI("") == "")
    }
}

@Suite struct AppLogTests {
    @Test func splitsExecutableNameFromArguments() {
        let command = Command(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "php@8.2", "it's"], environmentOverrides: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
        let parts = AppLog.redactableParts(of: command)
        #expect(parts.name == "brew")
        #expect(parts.arguments == "upgrade php@8.2 'it'\\''s'")
        #expect(!parts.arguments.contains("HOMEBREW_NO_AUTO_UPDATE"))
        #expect(AppLog.redactableParts(of: Command(executable: "/usr/bin/env")).arguments == "")
    }

    @Test func everyCategoryHasALogger() {
        #expect(AppLog.Category.allCases.map(\.rawValue) == ["scan", "provider", "command", "update", "service", "database", "ui"])
        for category in AppLog.Category.allCases {
            AppLog.log(Command(executable: "/usr/bin/true"), .started(pid: 1), to: AppLog.logger(category))
        }
    }
}
