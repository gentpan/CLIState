/// Presentation helpers for raw command output (`CommandEvent` lines keep ANSI escapes).
public enum TerminalText {
    /// Removes CSI / OSC (and other ECMA-48) escape sequences, then applies
    /// carriage-return overwrite per line: only the text after the last `\r` is kept.
    /// A `\r` directly before `\n` (CRLF) is a line ending, not an overwrite.
    public static func strippingANSI(_ text: String) -> String {
        let cleaned = removingEscapeSequences(Array(text.unicodeScalars))
        var output = String.UnicodeScalarView()
        var lineStart = 0
        for index in 0...cleaned.count where index == cleaned.count || cleaned[index] == "\n" {
            var line = cleaned[lineStart..<index]
            while line.last == "\r" { line = line.dropLast() }
            if let lastReturn = line.lastIndex(of: "\r") {
                line = line[(lastReturn + 1)...]
            }
            output.append(contentsOf: line)
            if index < cleaned.count { output.append("\n") }
            lineStart = index + 1
        }
        return String(output)
    }

    private static let escape: Unicode.Scalar = "\u{1B}"
    private static let bell: Unicode.Scalar = "\u{07}"
    private static let c1CSI: Unicode.Scalar = "\u{9B}"
    private static let c1OSC: Unicode.Scalar = "\u{9D}"
    private static let c1StringTerminator: Unicode.Scalar = "\u{9C}"

    private static func removingEscapeSequences(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == c1CSI {
                index = skipControlSequence(scalars, from: index + 1)
                continue
            }
            if scalar == c1OSC {
                index = skipControlString(scalars, from: index + 1)
                continue
            }
            guard scalar == escape else {
                output.append(scalar)
                index += 1
                continue
            }

            let next = index + 1
            guard next < scalars.count else { break }
            switch scalars[next].value {
            case 0x5B: // [  CSI
                index = skipControlSequence(scalars, from: next + 1)
            case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // ] P X ^ _  OSC, DCS, SOS, PM, APC
                index = skipControlString(scalars, from: next + 1)
            case 0x20...0x2F: // nF escapes such as ESC ( B
                var cursor = next
                while cursor < scalars.count, (0x20...0x2F).contains(scalars[cursor].value) { cursor += 1 }
                if cursor < scalars.count, (0x30...0x7E).contains(scalars[cursor].value) { cursor += 1 }
                index = cursor
            case 0x30...0x7E: // two-character escapes such as ESC 7, ESC =, ESC M
                index = next + 1
            default:
                index = next
            }
        }
        return output
    }

    /// Parameter bytes 0x30–0x3F, intermediate bytes 0x20–0x2F, one final byte 0x40–0x7E.
    private static func skipControlSequence(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var cursor = start
        while cursor < scalars.count, (0x20...0x3F).contains(scalars[cursor].value) { cursor += 1 }
        if cursor < scalars.count, (0x40...0x7E).contains(scalars[cursor].value) { cursor += 1 }
        return cursor
    }

    /// Ends at BEL or ST (`ESC \` / U+009C). An unterminated string stops at the next
    /// newline so one malformed sequence can't swallow the rest of the output.
    private static func skipControlString(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var cursor = start
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if scalar == bell || scalar == c1StringTerminator { return cursor + 1 }
            if scalar == escape, cursor + 1 < scalars.count, scalars[cursor + 1] == "\\" { return cursor + 2 }
            if scalar == "\n" { return cursor }
            cursor += 1
        }
        return cursor
    }
}
