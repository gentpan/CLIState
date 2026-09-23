#!/bin/bash
# Publishes a notarized build to the public repo gentpan/CLIState:
# signs the zip for Sparkle, writes appcast.xml, and uploads both to a GitHub Release.
#
#   scripts/release.sh && scripts/publish-release.sh
#
# Needs: the Sparkle private key in the keychain (account "clistate") and `gh` logged in
# with access to gentpan/CLIState.
#
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLIC_REPO=gentpan/CLIState
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
TAG="v$VERSION"
ZIP="dist/CLIState-$VERSION.zip"
SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin
STAGING=dist/appcast

[ -f "$ZIP" ] || { echo "error: $ZIP not found; run scripts/release.sh first" >&2; exit 1; }
[ -x "$SPARKLE_BIN/generate_appcast" ] || xcodebuild -project CLIState.xcodeproj -scheme CLIState -resolvePackageDependencies -derivedDataPath build >/dev/null

rm -rf "$STAGING" && mkdir -p "$STAGING"
cp "$ZIP" "$STAGING/"
NOTES=$(awk -v v="## $VERSION" '$0==v{f=1;next} /^## /{f=0} f' CHANGELOG.md 2>/dev/null || true)

# Release notes shown in the update dialog: Sparkle picks up a .md file named like the archive.
if [ -n "$NOTES" ]; then
    printf '%s\n' "$NOTES" > "$STAGING/CLIState-$VERSION.md"
fi

"$SPARKLE_BIN/generate_appcast" --account clistate --embed-release-notes \
    --download-url-prefix "https://github.com/$PUBLIC_REPO/releases/download/$TAG/" \
    --link "https://github.com/$PUBLIC_REPO" \
    "$STAGING"

gh release create "$TAG" "$STAGING/CLIState-$VERSION.zip" "$STAGING/appcast.xml" \
    --repo "$PUBLIC_REPO" --title "CLI State $VERSION" --notes "${NOTES:-CLI State $VERSION}"
echo "Published https://github.com/$PUBLIC_REPO/releases/tag/$TAG"

# Homebrew cask in gentpan/homebrew-tap: bump version and checksum.
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
TAP_DIR=$(mktemp -d)/homebrew-tap
gh repo clone gentpan/homebrew-tap "$TAP_DIR" -- -q
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/; s/^  name \".*\"/  name \"CLI State\"/" "$TAP_DIR/Casks/clistate.rb"
if git -C "$TAP_DIR" diff --quiet; then
    echo "Homebrew cask already at $VERSION"
else
    git -C "$TAP_DIR" commit -q -am "clistate $VERSION"
    git -C "$TAP_DIR" pull -q --rebase origin main
    git -C "$TAP_DIR" push -q origin main
    echo "Updated Homebrew cask gentpan/tap/clistate to $VERSION"
fi
