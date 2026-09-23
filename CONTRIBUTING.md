# Contributing

Thanks for helping improve CLI State. Bug reports and feature requests can be opened with the issue templates in this repository. For security issues, follow [SECURITY.md](SECURITY.md) and report them privately.

## Requirements

- macOS 15 or later
- Xcode with Swift 6 support
- XcodeGen (`brew install xcodegen`)

## Build and test

```bash
swift test --package-path Packages/CLIStateKit
xcodegen generate
xcodebuild -project CLIState.xcodeproj -scheme CLIState -derivedDataPath build build
xcodebuild -project CLIState.xcodeproj -scheme CLIState -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

`CLIState.xcodeproj` is generated from `project.yml` and should not be committed. Live provider tests that access installed package managers only run when `ENABLE_LIVE_PROVIDER_TESTS=1` is set.

## Code guidelines

- Follow the existing module boundaries in `Packages/CLIStateKit/Package.swift`.
- Pass external commands as an executable and separate arguments; do not build shell command strings.
- Keep read operations read-only. Mutations must go through the operation plan and confirmation flow.
- Add user-facing strings to the String Catalogs in `App/Resources/` in English and Simplified Chinese.
- Keep test fixtures synthetic or redact machine-specific paths and values.

## Licensing

By submitting a contribution, you agree that it may be distributed under this repository's MIT License. Bundled fonts keep their existing SIL Open Font License terms.
