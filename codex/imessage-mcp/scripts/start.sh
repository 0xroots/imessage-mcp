#!/bin/bash
# Starts the iMessage MCP stdio adapter that ships inside the iMessage MCP app.
# The app itself must be installed and the bridge switched on in its window.
# Override the app location with IMESSAGE_MCP_APP.
set -euo pipefail

app_id="org.messageslocal.app"
socket="$HOME/Library/Containers/$app_id/Data/tmp/messages-mcp.sock"

for candidate in "${IMESSAGE_MCP_APP:-}" "/Applications/iMessageMCP.app" "$HOME/Applications/iMessageMCP.app"; do
  if [ -n "$candidate" ] && [ -x "$candidate/Contents/Helpers/messages-mcp" ]; then
    exec "$candidate/Contents/Helpers/messages-mcp" "$socket"
  fi
done

echo "iMessage MCP app not found. Install it from https://github.com/0xroots/imessage-mcp/releases/latest or set IMESSAGE_MCP_APP." >&2
exit 1
