import CLIStateDomain
import Foundation

/// Reads the CPU architecture from an executable's header without running it.
public struct MachOReader: Sendable {
    /// Bytes read per file; enough for a fat header with dozens of slices.
    public static let headerLength = 4096

    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    /// `nil` when the file cannot be read.
    public func architecture(atPath path: String) -> CPUArchitecture? {
        guard let data = try? fileSystem.readData(atPath: path, maxBytes: Self.headerLength) else { return nil }
        return Self.architecture(ofHeader: data)
    }

    public static func architecture(ofHeader data: Data) -> CPUArchitecture {
        let bytes = [UInt8](data.prefix(headerLength))
        guard bytes.count >= 4 else { return .unknown }
        if bytes[0] == 0x23, bytes[1] == 0x21 { return .script }  // "#!"

        let bigEndianMagic = readUInt32(bytes, at: 0, bigEndian: true)
        switch bigEndianMagic {
        case fatMagic: return fatArchitecture(bytes, bigEndian: true, is64: false)
        case fatMagic64: return fatArchitecture(bytes, bigEndian: true, is64: true)
        case fatCigam: return fatArchitecture(bytes, bigEndian: false, is64: false)
        case fatCigam64: return fatArchitecture(bytes, bigEndian: false, is64: true)
        default: break
        }

        // Thin images store the magic in the file's own byte order: a little-endian
        // file reads as 0xfeedfacf when interpreted little-endian.
        let littleEndianMagic = readUInt32(bytes, at: 0, bigEndian: false)
        let fileIsBigEndian: Bool
        switch littleEndianMagic {
        case machMagic, machMagic64: fileIsBigEndian = false
        case machCigam, machCigam64: fileIsBigEndian = true
        default: return .unknown
        }
        guard bytes.count >= 8 else { return .unknown }
        return architecture(forCPUType: readUInt32(bytes, at: 4, bigEndian: fileIsBigEndian))
    }

    // MARK: Private

    private static let machMagic: UInt32 = 0xfeed_face
    private static let machMagic64: UInt32 = 0xfeed_facf
    private static let machCigam: UInt32 = 0xcefa_edfe
    private static let machCigam64: UInt32 = 0xcffa_edfe
    private static let fatMagic: UInt32 = 0xcafe_babe
    private static let fatMagic64: UInt32 = 0xcafe_babf
    private static let fatCigam: UInt32 = 0xbeba_feca
    private static let fatCigam64: UInt32 = 0xbfba_feca

    private static let cpuTypeX86_64: UInt32 = 0x0100_0007
    private static let cpuTypeARM64: UInt32 = 0x0100_000c

    /// Java class files share 0xcafebabe; their "slice count" is the class
    /// version (≥ 45), so a small count is required to treat the file as fat.
    private static let maximumFatSlices: UInt32 = 32

    private static func fatArchitecture(_ bytes: [UInt8], bigEndian: Bool, is64: Bool) -> CPUArchitecture {
        guard bytes.count >= 8 else { return .unknown }
        let count = readUInt32(bytes, at: 4, bigEndian: bigEndian)
        guard count > 0, count <= maximumFatSlices else { return .unknown }
        let entrySize = is64 ? 32 : 20
        var hasARM64 = false
        var hasX86_64 = false
        for index in 0..<Int(count) {
            let offset = 8 + index * entrySize
            guard offset + 4 <= bytes.count else { break }
            switch readUInt32(bytes, at: offset, bigEndian: bigEndian) {
            case cpuTypeARM64: hasARM64 = true
            case cpuTypeX86_64: hasX86_64 = true
            default: break
            }
        }
        switch (hasARM64, hasX86_64) {
        case (true, true): return .universal
        case (true, false): return .arm64
        case (false, true): return .x86_64
        case (false, false): return .unknown
        }
    }

    private static func architecture(forCPUType type: UInt32) -> CPUArchitecture {
        switch type {
        case cpuTypeARM64: .arm64
        case cpuTypeX86_64: .x86_64
        default: .unknown
        }
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int, bigEndian: Bool) -> UInt32 {
        let slice = bytes[offset..<offset + 4].map(UInt32.init)
        if bigEndian {
            return slice[0] << 24 | slice[1] << 16 | slice[2] << 8 | slice[3]
        }
        return slice[3] << 24 | slice[2] << 16 | slice[1] << 8 | slice[0]
    }
}

extension CPUArchitecture {
    /// Architecture this process runs as.
    public static var host: CPUArchitecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .unknown
        #endif
    }
}
