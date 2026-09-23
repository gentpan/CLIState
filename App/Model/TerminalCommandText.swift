import CLIStateDomain

/// Copyable terminal text only; execution still uses the original structured plan.
enum TerminalCommandText {
    static func render(_ steps: [OperationStep]) -> String? {
        guard !steps.isEmpty else { return nil }
        var lines: [String] = []
        for step in steps {
            guard case let .command(command) = step else { return nil }
            var text = command.fullDisplayString
            if !command.environmentOverrides.isEmpty {
                let assignments = command.environmentOverrides.keys.sorted().map {
                    "\($0)=\(command.environmentOverrides[$0]!)"
                }
                text = Command(executable: "/usr/bin/env", arguments: assignments + [command.executable] + command.arguments).fullDisplayString
            }
            if let directory = command.workingDirectory {
                let changeDirectory = Command(executable: "cd", arguments: ["--", directory]).fullDisplayString
                text = "(\(changeDirectory) && \(text))"
            }
            lines.append(text)
        }
        return lines.joined(separator: " &&\n")
    }
}
