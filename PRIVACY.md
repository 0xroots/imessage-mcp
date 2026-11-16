# Privacy

iMessage MCP runs entirely on your Mac. It has no server, no account, no analytics and no network code. The maintainers never receive your data.

## What it reads

- Messages you choose to expose, from the Messages folder you grant to the app. Access is read-only and limited to that folder through a sandbox grant; the app does not use Full Disk Access.
- For each allowed chat: its group name and the phone numbers or emails of its members, shown to the connected tool so it can find the right chat. Contact names are not read.
- Only after you approve a connection in the app window, and only for the chat or chats you select. You can deny or end a connection at any time.

## What it stores

- The macOS bookmark for the folder you granted, so you do not have to pick it again.
- A list of request IDs (random UUIDs) of messages already sent, so a send is never repeated. Message text and recipients are not stored.
- Nothing else. Message content is read on demand and is not written to disk by the app.

## What it sends

- Messages and search results are returned to the MCP client you connected (for example Claude Code or Codex) through a local Unix socket. What that client does with the content is governed by the client's own privacy terms.
- A message is sent only after you confirm its recipient and text in an on-screen dialog. It is handed to the Messages app through a single Apple Event.
- The app makes no other outbound connections.

## Reading messages on screen

The app's own message browser opens only after you confirm with Touch ID or your Mac password, its window cannot be captured by other apps, and it locks itself after 5 minutes without use. Software that drives your screen, including AI assistants, cannot pass the confirmation. AI tools should read messages through the MCP bridge, where you approve every connection.

## Retention and deletion

- The app keeps no copy of your messages. Quit the bridge to close all connections; remove the app and its container folder (`~/Library/Containers/org.messageslocal.app`) to delete everything it stored.

## Children

The tool is not directed at children under 18.

## Contact

Questions or concerns: open an issue at https://github.com/0xroots/imessage-mcp/issues. For vulnerabilities see [SECURITY.md](SECURITY.md).
