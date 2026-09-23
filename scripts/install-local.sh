#!/bin/bash
# Test, increment the local build, install one verified App, and record delivery.
# Usage: scripts/install-local.sh "修改说明" ["另一条说明" ...]
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$#" -gt 0 ] || { echo "usage: $0 <changelog entry> [...]" >&2; exit 1; }

mkdir -p build-local
LOCK=build-local/.install-lock
mkdir "$LOCK" 2>/dev/null || { echo "error: another local installation is in progress" >&2; exit 1; }
STAGING=
REPLACED=0
FINISHED=0
cleanup() {
    status=$?
    if [ "$REPLACED" = 1 ] && [ "$FINISHED" = 0 ]; then
        pkill -TERM -x CLIState 2>/dev/null || true
        rm -rf /Applications/CLIState.app
        if [ -d "$STAGING/previous.app" ]; then
            mv "$STAGING/previous.app" /Applications/CLIState.app
            open /Applications/CLIState.app || true
        fi
    fi
    [ -z "$STAGING" ] || rm -rf "$STAGING"
    rmdir "$LOCK"
    exit "$status"
}
trap cleanup EXIT

run_logged() {
    local log=$1
    shift
    if ! "$@" > "$log" 2>&1; then
        tail -80 "$log" >&2
        return 1
    fi
}

run_logged build-local/script-tests.log python3 -m unittest discover -s scripts/tests
run_logged build-local/package-tests.log swift test --package-path Packages/CLIStateKit
scripts/bump-version.sh --build
VERSION=$(python3 scripts/local_version.py show)
xcodegen generate --quiet
run_logged build-local/app-tests.log xcodebuild -project CLIState.xcodeproj -scheme CLIState -configuration Debug \
    -derivedDataPath build-local -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO test

# Never mask xcodebuild's exit status or fall back to an old product on disk.
run_logged build-local/local-build.log xcodebuild -project CLIState.xcodeproj -scheme CLIState -configuration Release \
    -derivedDataPath build-local -destination "platform=macOS,arch=$(uname -m)" \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS= ENABLE_HARDENED_RUNTIME=NO build
APP=build-local/Build/Products/Release/CLIState.app
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
[ "$BUILT_VERSION" = "$VERSION" ] || { echo "error: built version does not match $VERSION" >&2; exit 1; }

[ ! -L /Applications/CLIState.app ] || { echo "error: installation target is a symlink" >&2; exit 1; }
if [ -e /Applications/CLIState.app ]; then
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/CLIState.app/Contents/Info.plist)" = com.clistate.app ] || exit 1
fi
STAGING=$(mktemp -d /Applications/.CLIState-install.XXXXXX)
ditto "$APP" "$STAGING/CLIState.app"
codesign --verify --deep --strict "$STAGING/CLIState.app"
pkill -TERM -x CLIState 2>/dev/null || true
for attempt in {1..20}; do
    pgrep -x CLIState >/dev/null || break
    sleep 0.5
done
if pgrep -x CLIState >/dev/null; then
    echo "error: CLI State did not exit; existing installation preserved" >&2
    exit 1
fi
if [ -d /Applications/CLIState.app ]; then
    mv /Applications/CLIState.app "$STAGING/previous.app"
fi
REPLACED=1
mv "$STAGING/CLIState.app" /Applications/CLIState.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/CLIState.app
open /Applications/CLIState.app
sleep 3
pgrep -f '^/Applications/CLIState.app/Contents/MacOS/CLIState($| )' >/dev/null || {
    echo "error: new CLI State did not stay running; restoring previous installation" >&2
    exit 1
}
python3 scripts/local_version.py record "$@"
FINISHED=1
python3 scripts/clean_local_copies.py
echo "Installed and launched CLI State $VERSION; only /Applications/CLIState.app remains."
