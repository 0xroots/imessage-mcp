# Use iMessage MCP from ChatGPT and dots

ChatGPT agents, including dots, run in the cloud and cannot start a program on your Mac. OpenAI's
[Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels.md) closes that gap: a small
client on your Mac (`tunnel-client`) connects outbound to OpenAI and runs the iMessage MCP adapter for the agent.
No port is opened and nothing is published on the internet.

## One-time setup

1. Install the iMessage MCP app and allow your Messages folder (see the README).
2. In the OpenAI Platform, create a tunnel and a runtime key, and give your ChatGPT workspace access to the tunnel.
3. Save the key and run the helper:

   ```bash
   mkdir -p ~/.config/tunnel-client && umask 077 && cat > ~/.config/tunnel-client/runtime.key   # paste the key, then Ctrl-D
   export CONTROL_PLANE_TUNNEL_ID="tunnel_..."
   ./scripts/chatgpt-tunnel.sh
   ```

   It installs `tunnel-client` with Homebrew if needed, creates the profile once, validates it and starts the tunnel.
   Keep it running (one instance per tunnel).
4. In ChatGPT, open **Plugins**, create a developer-mode app, choose **Tunnel** as the connection and select your tunnel.
   Name it **iMessage MCP** and upload `docs/icon.png` as the icon.
5. In the iMessage MCP app, press **Start AI bridge**. The first call from ChatGPT shows the approval dialog on your Mac.

### Already have `tunnel-client` as a service?

If you run `tunnel-client` as a Homebrew service with the key in the macOS Keychain, you do not need the helper script.
Point the profile's `--mcp-command` at the adapter and its socket, as the script does. After you update the
iMessage MCP app, restart the service so it starts the new adapter (`brew services list` shows its name, then
`brew services restart <name>`).

## What the agent gets

Reading and searching chats, photos and PDFs (on by default; switch "Photos and PDFs for AI" in the app window), and sending
messages, each send confirmed on your screen. Group chats are found by name (for example "ADA") or by members.

## Limits to know

- The tunnel allows 120 seconds per request: approve the connection dialog promptly.
- Replies are capped at 10 MiB; attachment replies stay under 3.5 MB.
- Only one `tunnel-client` may run per tunnel ID when it starts a local command.
- Tunnels are for private use, not for publishing the app to everyone.
