@testable import CLIStateApplication
import CLIStateDomain
import Foundation
import Testing

@Suite("Memory bounds")
struct MemoryBoundsTests {
    @Test func transcriptKeepsOnlyTheTailButStillClassifies() {
        var transcript = OperationCoordinator.TranscriptTail()
        for index in 0..<50_000 {
            transcript.append("==> Pouring formula-\(index)--1.0.arm64_tahoe.bottle.tar.gz 🍺")
        }
        transcript.append("Error: Permission denied @ dir_s_mkdir - /opt/homebrew/Cellar")
        #expect(transcript.text.utf8.count <= OperationCoordinator.TranscriptTail.limit * 2)
        #expect(!transcript.text.contains("formula-0--"))
        #expect(transcript.text.hasSuffix("/opt/homebrew/Cellar\n"))
        #expect(OperationCoordinator.classify(transcript.text) == .permissionDenied)
    }

    @Test func providerFailureTextIsBounded() {
        let stderr = String(repeating: "Warning: something noisy happened\n", count: 5_000)
        let error = ProviderError.commandFailed(.homebrew, command: "brew info --json=v2 --installed", exitCode: 1, stderr: stderr)
        let summary = ScanCoordinator.failureSummary(error)
        #expect(summary.count == ScanCoordinator.failureSummaryLimit + 1)
        #expect(summary.contains("brew info"))
        #expect(ScanCoordinator.failureSummary(ProviderError.unsupportedOperation) == String(describing: ProviderError.unsupportedOperation))
    }
}
