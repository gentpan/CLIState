import Foundation

extension ActivityRun {
    /// Output lines kept per run. Upgrading many formulae can print tens of thousands
    /// of lines; the drawer only needs the tail, and history never stores output (§147).
    static let outputLineLimit = 2_000
    /// Finished runs kept for the drawer's picker.
    static let finishedRunLimit = 20

    /// Keeps roughly the last `outputLineLimit` lines. Old lines go in batches, so a
    /// long stream doesn't shift the whole buffer for every new line.
    mutating func appendLine(_ line: ActivityLine) {
        lines.append(line)
        let overflow = lines.count - Self.outputLineLimit
        guard overflow >= Self.outputLineLimit / 4 else { return }
        lines.removeFirst(overflow)
        omittedLineCount += overflow
    }

    /// Drops the oldest finished runs beyond `finishedRunLimit`; running ones always stay.
    static func pruningFinished(_ runs: [ActivityRun]) -> [ActivityRun] {
        var excess = runs.filter { !$0.isRunning }.count - finishedRunLimit
        guard excess > 0 else { return runs }
        return runs.filter { run in
            guard excess > 0, !run.isRunning else { return true }
            excess -= 1
            return false
        }
    }
}
