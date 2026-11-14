#!/bin/bash
# Builds a Developer ID signed, notarized and stapled DMG.
#
# One-time setup (credentials never live in this repository):
#   xcrun notarytool store-credentials "imessage-mcp-notary" --key <AuthKey.p8> --key-id <ID> --issuer <UUID>
#
#   export MSGLOCAL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   export MSGLOCAL_TEAM_ID="TEAMID"
#   export MSGLOCAL_VERSION="0.2.0"
#   ./scripts/release.sh
#
# Optional: MSGLOCAL_NOTARY_PROFILE (default imessage-mcp-notary).
set -euo pipefail

: "${MSGLOCAL_SIGN_IDENTITY:?Set MSGLOCAL_SIGN_IDENTITY to a Developer ID Application identity}"
: "${MSGLOCAL_TEAM_ID:?Set MSGLOCAL_TEAM_ID}"
VERSION="${MSGLOCAL_VERSION:-0.2.0}"
PROFILE="${MSGLOCAL_NOTARY_PROFILE:-imessage-mcp-notary}"
root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$root/dist"
mkdir -p "$dist"

MSGLOCAL_RELEASE=1 "$root/scripts/build.sh"
app="$root/build/iMessageMCP.app"

# Notarize the app (zip is only a transport for the upload).
work="$(mktemp -d "${TMPDIR:-/tmp}/imessagemcp-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT
ditto -c -k --keepParent "$app" "$work/app.zip"
xcrun notarytool submit "$work/app.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$app"

# Package, sign, notarize and staple the DMG.
dmg="$dist/iMessageMCP-$VERSION.dmg"
rm -f "$dmg"
mkdir "$work/dmg" && ditto "$app" "$work/dmg/iMessageMCP.app" && ln -s /Applications "$work/dmg/Applications"
hdiutil create -volname "iMessage MCP" -srcfolder "$work/dmg" -ov -format UDZO "$dmg" >/dev/null
codesign --force --sign "$MSGLOCAL_SIGN_IDENTITY" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$dmg"

spctl -a -vvv -t exec "$app"
spctl -a -vvv -t open --context context:primary-signature "$dmg"
shasum -a 256 "$dmg" | tee "$dmg.sha256"
