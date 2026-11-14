#!/bin/bash
# Packs the stdio adapter into an MCPB archive and notarizes it.
# Run scripts/release.sh first: this takes the signed adapter from build/.
#
#   export MSGLOCAL_VERSION="0.2.0"
#   ./scripts/pack_mcpb.sh
#
# Optional: MSGLOCAL_NOTARY_PROFILE (default imessage-mcp-notary).
# The adapter only talks to the iMessage MCP app; install the app as well.
set -euo pipefail

VERSION="${MSGLOCAL_VERSION:-0.2.0}"
PROFILE="${MSGLOCAL_NOTARY_PROFILE:-imessage-mcp-notary}"
APP_ID="${MSGLOCAL_APP_ID:-org.messageslocal.app}"
root="$(cd "$(dirname "$0")/.." && pwd)"
adapter="$root/build/iMessageMCP.app/Contents/Helpers/messages-mcp"
[ -x "$adapter" ] || { echo "Missing $adapter: run scripts/release.sh first" >&2; exit 1; }

dist="$root/dist"; mkdir -p "$dist"
stage="$(mktemp -d "${TMPDIR:-/tmp}/imessagemcp-mcpb.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/pkg/server"
cp "$adapter" "$stage/pkg/server/messages-mcp"
cp "$root/docs/icon.png" "$stage/pkg/icon.png"

cat > "$stage/pkg/manifest.json" <<JSON
{
  "manifest_version": "0.3",
  "name": "imessage-mcp",
  "display_name": "iMessage MCP",
  "version": "$VERSION",
  "description": "Read, search and send iMessage from AI tools on macOS without Full Disk Access. Requires the iMessage MCP app.",
  "long_description": "Connects an MCP client to the iMessage MCP macOS app. The app is sandboxed with a read-only grant to your Messages folder and asks for your approval for every connection and every send. This package contains only the stdio adapter; install the app first (brew install --cask 0xroots/tap/imessage-mcp) and switch the bridge on in its window.",
  "author": { "name": "0xroots", "url": "https://github.com/0xroots" },
  "homepage": "https://github.com/0xroots/imessage-mcp",
  "repository": { "type": "git", "url": "https://github.com/0xroots/imessage-mcp" },
  "documentation": "https://github.com/0xroots/imessage-mcp#readme",
  "support": "https://github.com/0xroots/imessage-mcp/issues",
  "icon": "icon.png",
  "license": "MIT",
  "keywords": ["imessage", "messages", "macos", "privacy", "no-full-disk-access"],
  "server": {
    "type": "binary",
    "entry_point": "server/messages-mcp",
    "mcp_config": {
      "command": "\${__dirname}/server/messages-mcp",
      "args": ["\${HOME}/Library/Containers/$APP_ID/Data/tmp/messages-mcp.sock"]
    }
  },
  "tools": [
    { "name": "list_conversations", "description": "List the chats you allowed" },
    { "name": "get_messages", "description": "Read messages from an allowed chat" },
    { "name": "search_messages", "description": "Search message text with filters" },
    { "name": "get_recent_messages", "description": "Messages since a date" },
    { "name": "get_attachment_metadata", "description": "Attachment names and types, never contents" },
    { "name": "send_message", "description": "Send one message after on-screen owner confirmation" }
  ],
  "privacy_policies": ["https://github.com/0xroots/imessage-mcp/blob/main/PRIVACY.md"],
  "compatibility": { "platforms": ["darwin"] }
}
JSON
python3 -c "import json,sys; json.load(open('$stage/pkg/manifest.json'))"

out="$dist/imessage-mcp-$VERSION.mcpb"
rm -f "$out"
(cd "$stage/pkg" && zip -q -X -r "$out" manifest.json icon.png server)
xcrun notarytool submit "$out" --keychain-profile "$PROFILE" --wait
shasum -a 256 "$out" | tee "$out.sha256"
