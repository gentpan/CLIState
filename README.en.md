# CLI State

**See which command your terminal actually runs.**

[![Latest release](https://img.shields.io/github/v/release/gentpan/CLIState?style=flat-square)](https://github.com/gentpan/CLIState/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/gentpan/CLIState/ci.yml?branch=main&label=CI&style=flat-square)](https://github.com/gentpan/CLIState/actions/workflows/ci.yml)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-4c5966?style=flat-square)](project.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-4c5966?style=flat-square)](LICENSE)

[简体中文](README.md) · [Download latest](https://github.com/gentpan/CLIState/releases/latest) · [Website](https://clistate.com) · [Report an issue](https://github.com/gentpan/CLIState/issues/new/choose)

CLI State is an open-source native macOS app that brings **PATH resolution, installation sources, versions, conflicts, and updates** into one place. It supports Homebrew, npm, uv, pipx, pnpm, Cargo, and selected official installers. Tools whose ownership cannot be confirmed remain read-only.

![CLI State overview](docs/images/overview.png)

## What you can do

- **Find the active command:** See every executable match in PATH order, the version that takes effect, shadowed copies, and shell aliases or functions.
- **Understand where it came from:** Inspect evidence and confidence for Homebrew, npm, uv, and other sources, including separate installations of the same tool.
- **Spot problems and maintain safely:** Check broken links, PATH conflicts, and updates. Preview commands and their effects before updating, uninstalling, or cleaning up; rescan afterward.
- **Explore and revisit your setup:** Review charts, version-change history, and curated tools. Export an installation list or profile to review when moving to another Mac.

## Install

**Homebrew (recommended)**

```bash
brew tap gentpan/tap
brew install --cask gentpan/tap/clistate
```

Using the fully qualified cask name trusts only CLI State, without trusting the entire tap. See [Homebrew's Tap Trust guide](https://docs.brew.sh/Tap-Trust).

**Manual download**

1. Download `CLIState-<version>.zip` from [Releases](https://github.com/gentpan/CLIState/releases/latest) (signed and notarized by Apple).
2. Unzip it and move `CLIState.app` to Applications.

Later versions are offered inside the app; you can also check in Settings › About.

Requires macOS 15 or later, Apple Silicon or Intel.

## Supported sources

| Source | Discover | Check updates | Update | Uninstall | Services | Cleanup |
|---|---|---|---|---|---|---|
| Homebrew (formulae, CLI casks) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| npm global packages | ✓ | ✓ | ✓ | ✓ | — | ✓ |
| uv tools | ✓ | ✓ | ✓ | ✓ | — | ✓ |
| pnpm global packages | ✓ | ✓ | ✓ | ✓ | — | ✓ |
| pipx | ✓ | — | ✓ | ✓ | — | — |
| Cargo | ✓ | ✓ | ✓ | ✓ | — | — |
| Official installers (Claude Code, …) | ✓ | ✓ | ✓ | — | — | — |
| nvm / fnm / Volta / mise / asdf / rustup / Bun | ✓ | — | read-only | — | — | — |
| macOS / standalone | ✓ | — | read-only | — | — | broken links |

## Safety and privacy

- Never runs `sudo` and never edits shell configuration files.
- Every external command runs with separate arguments; nothing is interpolated into shell strings.
- Reads never change anything; writes need confirmed ownership and your confirmation. Background updates only touch tools you opted in.
- Never executes unknown binaries to probe versions.
- Local first: no account, no telemetry, no cloud sync; no shell history, no project scanning; environment variables stay in memory.

## FAQ

**Where do version numbers come from?** CLI State keeps no package database of its own. It asks each package manager's registry — Homebrew (formulae.brew.sh), npm (registry.npmjs.org), PyPI, crates.io — and respects mirrors you configured.

**Do I need to update every day?** No. While it runs, CLI State checks on a schedule (every 3 hours by default, refreshing Homebrew package info first) and only notifies by default. Only tools you set to Automatic are updated in the background, once a day after the time you choose, and major versions are skipped by default.

**How does CLI State update itself?** Sparkle checks the official update server first and falls back to this repository's Releases, verifying signatures before installing.

## Feedback

- Bugs or wrong detection: [file a bug](https://github.com/gentpan/CLIState/issues/new?template=bug_report.yml).
- Feature ideas or new package managers: [suggest a feature](https://github.com/gentpan/CLIState/issues/new?template=feature_request.yml).
- A diagnostics bundle helps a lot: Settings › About › Export Diagnostics…. It replaces your home folder with `~`, removes your account name, and contains no environment variables or command output — review it before attaching.
- Please report security issues privately via [Security › Report a vulnerability](https://github.com/gentpan/CLIState/security/advisories/new).

## Build from source

Requires macOS 15 or later, Xcode, Swift 6 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
swift test --package-path Packages/CLIStateKit
xcodegen generate
xcodebuild -project CLIState.xcodeproj -scheme CLIState -derivedDataPath build build
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for development notes. The generated `CLIState.xcodeproj` is not committed.

---

© 2026 GiantAccel, LLC. Source code is licensed under MIT; bundled fonts retain the SIL Open Font License in their respective directories.
