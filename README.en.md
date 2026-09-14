# CLI State

**Know what's running in your terminal.**

[简体中文](README.md) · [Download](https://github.com/gentpan/CLIState/releases/latest) · [Report an issue](https://github.com/gentpan/CLIState/issues/new/choose)

![CLI State overview](docs/images/overview.png)

CLI State is a native macOS app for understanding and managing your command-line development environment. It discovers tools and runtimes installed through Homebrew, npm, uv, pipx, pnpm, Cargo and official installers, resolves the binaries your terminal actually runs from your real PATH, detects duplicate and conflicting installations, and keeps track of available updates.

It is not another Homebrew GUI: a Homebrew GUI shows what Homebrew has; CLI State shows what your terminal environment actually is.

## Install

**Homebrew (recommended)**

```bash
brew tap gentpan/tap
brew trust gentpan/tap
brew install --cask clistate
```

Homebrew 6 requires trusting a third-party tap (`brew trust`) before installing from it.

**Manual download**

1. Download `CLIState-<version>.zip` from [Releases](https://github.com/gentpan/CLIState/releases/latest) (signed and notarized by Apple).
2. Unzip it and move `CLIState.app` to Applications.

Later versions are offered inside the app; you can also check in Settings › About.

Requires macOS 15 or later, Apple Silicon or Intel.

## Features

- **Discover tools**: curated developer, PHP, Python and media tools, with existing-install detection and individual or batch installation previews.
- **Visual overview**: installation-source charts, recorded version changes and environment checks with actionable maintenance.

- **Environment discovery** — starts your login shell in a clean environment to read the same PATH a new Terminal window gets; flags missing, duplicate and privacy-protected entries.
- **Resolution chains** — every PATH match for a command in order, which one is active, which are shadowed, and shell aliases/functions that run first.
- **Attribution with evidence** — who installed each executable (Homebrew, npm, uv, pipx, pnpm, Cargo, nvm, rustup, official installers, macOS…), with evidence and confidence. Anything not confirmed stays read-only.
- **Versions and updates** — asked of each package manager's own registry; official installers such as Claude Code are checked against their release channel.
- **Health** — PATH conflicts, multiple installations, broken links, missing runtimes, failed services.
- **Update, uninstall, services** — always through the owning package manager, showing the exact command and a dry-run preview first, then rescanning to verify.
- **Cleanup** — previewed cleanup of package caches, old versions, orphaned dependencies and broken links. Unowned files only go to the Trash.
- **Auto-update policy** — off, notify (default) or automatic, per tool, provider or globally; skips major versions by default and runs only on power.

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

**How does CLI State update itself?** Through Sparkle, from this repository's Releases, verifying signatures before installing.

## Feedback

- Bugs or wrong detection: [file a bug](https://github.com/gentpan/CLIState/issues/new?template=bug_report.yml).
- Feature ideas or new package managers: [suggest a feature](https://github.com/gentpan/CLIState/issues/new?template=feature_request.yml).
- A diagnostics bundle helps a lot: Settings › About › Export Diagnostics…. It replaces your home folder with `~`, removes your account name, and contains no environment variables or command output — review it before attaching.
- Please report security issues privately via [Security › Report a vulnerability](https://github.com/gentpan/CLIState/security/advisories/new).

---

© 2026 GiantAccel, LLC. All rights reserved.
