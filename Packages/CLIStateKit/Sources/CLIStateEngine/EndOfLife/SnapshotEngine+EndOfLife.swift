import CLIStateDomain
import Foundation

extension SnapshotEngine {
    /// Loads cycle data for the registry runtimes present and applies it. Only deep
    /// scans may touch the network; fast scans use whatever is cached.
    func applyEndOfLife(_ tools: [Tool], provider: (any EndOfLifeProviding)?, depth: ScanDepth, now: Date) async -> (tools: [Tool], issues: [HealthIssue]) {
        guard let provider else { return (tools, []) }
        let analyzer = EndOfLifeAnalyzer(registry: registry)
        let slugs = analyzer.products(for: tools)
        guard !slugs.isEmpty else { return (tools, []) }
        let products = await withTaskGroup(of: EndOfLifeProduct?.self) { group in
            for slug in slugs {
                group.addTask { await provider.product(slug, allowNetwork: depth == .deep) }
            }
            var loaded: [String: EndOfLifeProduct] = [:]
            for await product in group {
                if let product { loaded[product.slug] = product }
            }
            return loaded
        }
        return analyzer.apply(tools: tools, products: products, now: now)
    }

    /// Adds end-of-life issues after health analysis, keeping its ordering and the
    /// per-tool issue IDs in sync.
    static func merging(_ extra: [HealthIssue], into issues: [HealthIssue], tools: [Tool]) -> (issues: [HealthIssue], tools: [Tool]) {
        guard !extra.isEmpty else { return (issues, tools) }
        let merged = (issues + extra).sorted { ($0.severity, $1.id) > ($1.severity, $0.id) }
        let byTool = Dictionary(grouping: extra.filter { $0.toolID != nil }) { $0.toolID! }
        let updated = tools.map { tool in
            guard let added = byTool[tool.id] else { return tool }
            var tool = tool
            tool.health.issueIDs = (tool.health.issueIDs + added.map(\.id)).sorted()
            return tool
        }
        return (merged, updated)
    }
}
