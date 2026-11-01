#!/usr/bin/env bash
# Build a distributable, ad-hoc signed universal macOS app and release assets.
#
# Usage:
#   scripts/package-release.sh [VERSION] [BUILD_NUMBER]
#
# Optional environment:
#   CODESIGN_IDENTITY  "Developer ID Application: ..." to sign instead of ad-hoc
#   NOTARY_PROFILE     notarytool keychain profile for notarization
#
# Set up notarization credentials once with:
#   xcrun notarytool store-credentials AgentNotchNotary \
#     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0.0}"
BUILD_NUMBER="${2:-${GITHUB_RUN_NUMBER:-1}}"
OUT="$ROOT/build/release"
DERIVED="$ROOT/build/release-derived-data"
APP="$OUT/AgentNotch.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "Invalid version: $VERSION" >&2
  exit 2
fi

rm -rf "$OUT" "$DERIVED"
mkdir -p "$OUT"

echo "==> Building AgentNotch $VERSION ($BUILD_NUMBER), arm64 + x86_64"
xcodebuild \
  -project "$ROOT/AgentNotch.xcodeproj" \
  -scheme AgentNotch \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  build

cp -R "$DERIVED/Build/Products/Release/AgentNotch.app" "$APP"

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$ACTUAL_VERSION" == "$VERSION" ]] || { echo "Version mismatch: $ACTUAL_VERSION" >&2; exit 1; }
[[ "$ACTUAL_BUILD" == "$BUILD_NUMBER" ]] || { echo "Build mismatch: $ACTUAL_BUILD" >&2; exit 1; }
[[ "$ACTUAL_BUNDLE_ID" == "com.benmoeckel.agentnotch" ]] || { echo "Unexpected bundle ID: $ACTUAL_BUNDLE_ID" >&2; exit 1; }

echo "==> Signing with: $IDENTITY"
SIGN_ARGS=(--force --deep --sign "$IDENTITY" --options runtime
  --entitlements "$ROOT/AgentNotch/AgentNotch.entitlements")
if [[ "$IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Creating zip"
ditto -c -k --norsrc --keepParent "$APP" "$OUT/AgentNotch-macos.zip"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing (this can take a few minutes)"
  xcrun notarytool submit "$OUT/AgentNotch-macos.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$OUT/AgentNotch-macos.zip"
  ditto -c -k --norsrc --keepParent "$APP" "$OUT/AgentNotch-macos.zip"
fi

echo "==> Creating disk image"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/AgentNotch.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "AgentNotch $VERSION" \
  -srcfolder "$STAGING" -ov -format UDZO "$OUT/AgentNotch-macos.dmg"
rm -rf "$STAGING"
trap - EXIT

echo "==> Packaging VS Code bridge"
VSIX="$(python3 "$ROOT/scripts/package-vscode-bridge.py" | tail -n 1)"
cp "$VSIX" "$OUT/AgentNotch-bridge.vsix"

(
  cd "$OUT"
  shasum -a 256 AgentNotch-macos.zip AgentNotch-macos.dmg AgentNotch-bridge.vsix > SHA256SUMS.txt
)

echo
echo "Release assets in $OUT:"
ls -lh "$OUT"
echo
cat "$OUT/SHA256SUMS.txt"
