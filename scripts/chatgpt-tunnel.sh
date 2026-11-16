#!/bin/bash
# Connects the iMessage MCP adapter to ChatGPT (and its dots) through OpenAI's Secure MCP Tunnel.
# Safe to run again: it only creates the profile if it is missing, then validates and starts it.
#
#   export CONTROL_PLANE_TUNNEL_ID="tunnel_..."          # from the OpenAI Platform tunnel page
#   echo "<runtime key>" > ~/.config/tunnel-client/runtime.key && chmod 600 ~/.config/tunnel-client/runtime.key
#   ./scripts/chatgpt-tunnel.sh
#
# The runtime key is read from that file (or CONTROL_PLANE_API_KEY) and is never printed or stored in the repo.
set -euo pipefail

APP="${IMESSAGE_MCP_APP:-/Applications/iMessageMCP.app}"
ADAPTER="$APP/Contents/Helpers/messages-mcp"
SOCKET="$HOME/Library/Containers/org.messageslocal.app/Data/tmp/messages-mcp.sock"
PROFILE="${TUNNEL_PROFILE:-imessage-mcp}"
KEYFILE="${TUNNEL_KEY_FILE:-$HOME/.config/tunnel-client/runtime.key}"

[ -x "$ADAPTER" ] || { echo "iMessage MCP app not found at $APP (set IMESSAGE_MCP_APP)." >&2; exit 1; }
[ -n "${CONTROL_PLANE_TUNNEL_ID:-}" ] || { echo "Set CONTROL_PLANE_TUNNEL_ID to your tunnel ID (tunnel_...)." >&2; exit 1; }

if ! command -v tunnel-client >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || { echo "Homebrew is required to install tunnel-client." >&2; exit 1; }
  brew install openai/tools/tunnel-client
fi

if [ -z "${CONTROL_PLANE_API_KEY:-}" ]; then
  [ -r "$KEYFILE" ] || { echo "Put the tunnel runtime key in $KEYFILE (chmod 600) or set CONTROL_PLANE_API_KEY." >&2; exit 1; }
  CONTROL_PLANE_API_KEY="$(tr -d '[:space:]' < "$KEYFILE")"
  export CONTROL_PLANE_API_KEY
fi

# One stdio instance per tunnel ID: stop here if another one is running.
if pgrep -f "tunnel-client run --profile $PROFILE" >/dev/null 2>&1; then
  echo "tunnel-client is already running for profile $PROFILE." >&2; exit 0
fi

if ! tunnel-client doctor --profile "$PROFILE" >/dev/null 2>&1; then
  tunnel-client init --sample sample_mcp_stdio_local --profile "$PROFILE" \
    --tunnel-id "$CONTROL_PLANE_TUNNEL_ID" --mcp-command "\"$ADAPTER\" \"$SOCKET\""
fi
tunnel-client doctor --profile "$PROFILE" --explain
exec tunnel-client run --profile "$PROFILE"
