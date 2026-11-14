#!/bin/bash
# Builds and signs iMessageMCP.app. The signing identity and team come from the
# environment, so nothing personal is stored in the repository.
#
#   export MSGLOCAL_SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"   # or its SHA-1
#   export MSGLOCAL_TEAM_ID="YOURTEAMID"
#   ./scripts/build.sh
#
# Optional: MSGLOCAL_APP_ID (default org.messageslocal.app), MSGLOCAL_ADAPTER_ID
# (default org.messageslocal.mcp), MSGLOCAL_VERSION (default 0.2.0).
set -euo pipefail

: "${MSGLOCAL_SIGN_IDENTITY:?Set MSGLOCAL_SIGN_IDENTITY to a code-signing identity (see: security find-identity -v -p codesigning)}"
: "${MSGLOCAL_TEAM_ID:?Set MSGLOCAL_TEAM_ID to the Team ID of that identity}"
APP_ID="${MSGLOCAL_APP_ID:-org.messageslocal.app}"
ADAPTER_ID="${MSGLOCAL_ADAPTER_ID:-org.messageslocal.mcp}"
VERSION="${MSGLOCAL_VERSION:-0.2.0}"

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build"
# Build and sign in a temporary APFS directory: on non-APFS volumes (exFAT) macOS
# adds "._" metadata files after signing, which invalidates the signature.
stage="$(mktemp -d "${TMPDIR:-/tmp}/messageslocal-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/iMessageMCP.app"
gen="$stage/generated"
cache="$stage/modulecache"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" "$gen" "$cache" "$out"
export CLANG_MODULE_CACHE_PATH="$cache"

# Fill build-time identity (used by the app and the adapter to verify each other).
sed -e "s/@TEAM_ID@/$MSGLOCAL_TEAM_ID/" -e "s/@APP_ID@/$APP_ID/" -e "s/@ADAPTER_ID@/$ADAPTER_ID/" \
  "$root/Sources/Shared/BuildIdentity.swift.in" > "$gen/BuildIdentity.swift"
sed -e "s/@APP_ID@/$APP_ID/" -e "s/@VERSION@/$VERSION/" \
  "$root/Resources/Info.plist.in" > "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

xcrun swiftc -O "$root"/Sources/App/*.swift "$root"/Sources/Reader/*.swift "$root"/Sources/Bridge/*.swift \
  "$gen/BuildIdentity.swift" -lsqlite3 -o "$app/Contents/MacOS/iMessageMCP"
xcrun swiftc -O "$root/Sources/Adapter/main.swift" "$gen/BuildIdentity.swift" -o "$app/Contents/Helpers/messages-mcp"

find "$app" -name '._*' -delete
codesign --force --sign "$MSGLOCAL_SIGN_IDENTITY" --identifier "$ADAPTER_ID" --timestamp=none "$app/Contents/Helpers/messages-mcp"
codesign --force --sign "$MSGLOCAL_SIGN_IDENTITY" --entitlements "$root/Resources/MessagesLocal.entitlements" --timestamp=none "$app"
find "$app" -name '._*' -delete
codesign --verify --deep --strict "$app"
final="$out/iMessageMCP.app"
rm -rf "$final"
ditto --norsrc --noextattr --noqtn "$app" "$final"
find "$final" -name '._*' -delete
codesign --verify --deep --strict "$final"
echo "Built $final"
echo "MCP adapter: $final/Contents/Helpers/messages-mcp <socket-path>"
