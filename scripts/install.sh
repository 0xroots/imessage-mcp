#!/bin/bash
# One-command install: build, sign, copy to /Applications and optionally register the
# MCP server with your clients.
#
#   export MSGLOCAL_SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
#   export MSGLOCAL_TEAM_ID="YOURTEAMID"
#   ./scripts/install.sh [--claude] [--codex]
#
# --claude  run `claude mcp add` for you (user scope)
# --codex   run `codex mcp add` for you
# Without flags nothing outside /Applications is changed; the commands are printed instead.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
APP_ID="${MSGLOCAL_APP_ID:-org.messageslocal.app}"
register_claude=0; register_codex=0
for arg in "$@"; do
  case "$arg" in
    --claude) register_claude=1 ;;
    --codex) register_codex=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

"$root/scripts/build.sh"
dest="/Applications/iMessageMCP.app"
if [[ ! -w /Applications ]]; then dest="$HOME/Applications/iMessageMCP.app"; mkdir -p "$HOME/Applications"; fi
rm -rf "$dest"
ditto --norsrc --noextattr --noqtn "$root/build/iMessageMCP.app" "$dest"
codesign --verify --deep --strict "$dest"
echo "Installed $dest"

adapter="$dest/Contents/Helpers/messages-mcp"
socket="$HOME/Library/Containers/$APP_ID/Data/tmp/messages-mcp.sock"
if [[ $register_claude == 1 ]]; then
  claude mcp add --scope user --transport stdio imessage-mcp -- "$adapter" "$socket"
else
  echo "Claude Code:  claude mcp add --scope user --transport stdio imessage-mcp -- \"$adapter\" \"$socket\""
fi
if [[ $register_codex == 1 ]]; then
  codex mcp add imessage-mcp -- "$adapter" "$socket"
else
  echo "Codex:        codex mcp add imessage-mcp -- \"$adapter\" \"$socket\""
fi
echo "Next: open the app, allow the Messages folder, then press Start AI bridge."
