import Darwin

/// Splits on newlines, retaining only a bounded prefix of oversized lines.
/// Bytes beyond the limit are drained until the next newline; later lines survive.
struct LineSplitter {
    static let defaultByteLimit = 4096
    private let byteLimit: Int
    private var pending: [UInt8] = []
    private var truncated = false

    init(byteLimit: Int = Self.defaultByteLimit) {
        self.byteLimit = max(1, byteLimit)
    }

    mutating func append(_ bytes: UnsafeRawBufferPointer, emit: (String) -> Void) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        var start = 0
        while start < bytes.count {
            let found = memchr(base + start, 0x0A, bytes.count - start)
            let end = found.map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
            let retained = min(end - start, byteLimit - pending.count)
            if retained > 0 { pending.append(contentsOf: bytes[start..<(start + retained)]) }
            truncated = truncated || retained < end - start
            guard found != nil else { return }
            emit(decodedLine())
            pending.removeAll(keepingCapacity: true)
            truncated = false
            start = end + 1
        }
    }

    mutating func finish(emit: (String) -> Void) {
        guard !pending.isEmpty || truncated else { return }
        emit(decodedLine())
        pending = []
        truncated = false
    }

    private func decodedLine() -> String {
        var bytes = pending[...]
        if truncated {
            // A byte limit can bisect a UTF-8 scalar. Drop only that incomplete
            // scalar; retain replacement decoding for genuinely invalid input.
            if let start = bytes.lastIndex(where: { $0 & 0xC0 != 0x80 }) {
                let lead = bytes[start]
                let width = lead < 0x80 ? 1 : lead & 0xE0 == 0xC0 ? 2 : lead & 0xF0 == 0xE0 ? 3 : lead & 0xF8 == 0xF0 ? 4 : 1
                if bytes.endIndex - start < width { bytes = bytes[..<start] }
            }
            return String(decoding: bytes, as: UTF8.self) + "…"
        }
        if bytes.last == 0x0D { bytes = bytes.dropLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
