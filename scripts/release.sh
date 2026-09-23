#!/bin/bash
# Builds, signs, notarizes and packages CLI State (CLIState.app).
#
#   scripts/release.sh             # archive → Developer ID export → notarize → staple → zip
#   scripts/release.sh --no-notarize
#
# Signing identity comes from Config/Signing.local.xcconfig (git-ignored).
# Notarization uses the Apple developer account signed in to Xcode, so no
# credentials are stored or typed by this script.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f Config/Signing.local.xcconfig ]; then
    echo "error: Config/Signing.local.xcconfig is missing (see Config/Signing.local.xcconfig.example)" >&2
    exit 1
fi

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
ARCHIVE=build-release/CLIState.xcarchive
ZIP=dist/CLIState-$VERSION.zip

xcodegen generate --quiet
rm -rf "$ARCHIVE" dist/export dist/notarized
xcodebuild archive -project CLIState.xcodeproj -scheme CLIState -configuration Release \
    -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' | grep -E "error:|ARCHIVE" || true
[ -d "$ARCHIVE" ] || { echo "error: archive failed" >&2; exit 1; }

if [ "${1:-}" = "--no-notarize" ]; then
    APP="$ARCHIVE/Products/Applications/CLIState.app"
else
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist Config/ExportOptions-DeveloperID.plist \
        -exportPath dist/export -allowProvisioningUpdates | grep -E "error:|Uploaded|EXPORT" || true
    for attempt in $(seq 1 60); do
        if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath dist/notarized >/dev/null 2>&1; then
            break
        fi
        echo "waiting for notarization ($attempt)…"
        sleep 30
    done
    APP=dist/notarized/CLIState.app
    [ -d "$APP" ] || { echo "error: notarization did not finish" >&2; exit 1; }
    xcrun stapler validate "$APP"
fi

codesign --verify --deep --strict "$APP"
spctl -a -t exec -vv "$APP" || true

mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Packaged: $ZIP"
