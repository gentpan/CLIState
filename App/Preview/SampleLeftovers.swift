import CLIStateDomain

extension SampleSnapshot {
    /// What `LeftoverScanner` would find for the sample tools. Claude Code stays
    /// installed (native, cleanup only); gh and Kimi CLI show the full
    /// Uninstall and Clean Up flow.
    static func leftovers() -> [ToolID: [LeftoverItem]] {
        [
            "claude-code": [
                LeftoverItem(path: "\(home)/.claude", kind: .data, origin: .registry, sizeBytes: 412_600_000, sizeIsLowerBound: true),
                LeftoverItem(path: "\(home)/.claude.json", kind: .config, origin: .registry, sizeBytes: 48_213),
                LeftoverItem(path: "\(home)/Library/Caches/claude-cli-nodejs", kind: .logs, origin: .registry, sizeBytes: 23_418_880),
            ],
            "gh": [
                LeftoverItem(path: "\(home)/.config/gh", kind: .config, origin: .registry, sizeBytes: 3_120),
                LeftoverItem(path: "\(home)/Library/Caches/gh", kind: .cache, origin: .exactName, sizeBytes: 1_204_224),
                LeftoverItem(path: "\(home)/.local/state/gh", kind: .state, origin: .exactName, sizeBytes: 18_402),
            ],
            "kimi-cli": [
                LeftoverItem(path: "\(home)/Library/Caches/kimi-cli", kind: .cache, origin: .exactName, sizeBytes: 86_016_000),
                LeftoverItem(path: "\(home)/Library/Logs/kimi-cli", kind: .logs, origin: .exactName, sizeBytes: 2_310_144),
                LeftoverItem(path: "\(home)/.config/kimi-cli", kind: .config, origin: .exactName, sizeBytes: 1_536),
            ],
            "uv": [
                LeftoverItem(path: "\(home)/.cache/uv", kind: .cache, origin: .registry, sizeBytes: 1_842_000_000, sizeIsLowerBound: true),
            ],
            "go": [
                LeftoverItem(path: "\(home)/Library/Caches/go-build", kind: .cache, origin: .registry, sizeBytes: 2_310_000_000, sizeIsLowerBound: true),
            ],
        ]
    }
}
