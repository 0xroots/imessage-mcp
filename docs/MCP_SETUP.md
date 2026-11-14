# Connecting an MCP client

iMessage MCP ships a small stdio adapter inside the app bundle:

```
iMessageMCP.app/Contents/Helpers/messages-mcp <socket-path>
```

The socket lives in the app's sandbox container and exists only while the AI bridge is running:

```
~/Library/Containers/<app bundle id>/Data/tmp/messages-mcp.sock
```

With the default build the bundle id is `org.messageslocal.app`.

Register the adapter in any client that supports stdio MCP servers. The configuration needs a command and one argument:

```json
{
  "mcpServers": {
    "imessage-mcp": {
      "command": "/path/to/iMessageMCP.app/Contents/Helpers/messages-mcp",
      "args": ["/Users/<you>/Library/Containers/org.messageslocal.app/Data/tmp/messages-mcp.sock"]
    }
  }
}
```

Many clients also offer a command-line way to add a server; use the same command and argument.

## What to expect

1. Start the AI bridge in the app.
2. The first request from the client opens an approval window in iMessage MCP. Approve a selected chat, all chats, or deny.
3. Calls fail with a clear message if the bridge is stopped or the limits are used up.
4. `send_message` takes `recipient` (E.164, for example `+15551234567`), `text` and a new UUID `request_id`. A confirmation window shows the recipient and the full text. The result is `submitted`, `not_attempted` (with a `reason`) or `unknown`. Never retry automatically after `unknown`; check Messages first.

The first time a message is sent, macOS asks you to allow iMessage MCP to control Messages. Allow it once.
