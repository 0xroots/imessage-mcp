# Security

## Reporting a vulnerability

Please open a private security advisory on the repository, or contact the maintainers privately. Do not post exploit details in public issues.

## Design

- **Sandbox.** App Sandbox with read-only, user-selected, app-scoped access to `~/Library/Messages`. No network entitlement, no Full Disk Access.
- **Local bridge.** A Unix socket inside the app container. The adapter and the app verify each other's code signature (bundle identifier plus Team ID).
- **Owner approval per connection.** Each new connection needs approval for selected chats or all chats. Approvals do not persist after the bridge stops.
- **Limits.** Time, message slots per request and per run, requests per minute and response size are set by the owner on every start and apply across reconnects.
- **Attachments.**
  - Off by default. The owner enables them per bridge run with a checkbox and a byte allowance (40 MB by default), on top of the per-connection approval and chat selection.
  - Only photos (decoded and re-encoded as small JPEG) and PDFs (text and the first pages as JPEG). Video, audio and other types are refused; the file type is decided from the content, not the stored MIME label.
  - A file must sit under `Attachments/` inside the granted folder. Paths with `..`, symlinks and anything resolving outside are refused; files over 15 MB are refused. Raw files and file paths are never returned.
- **Sending.**
  - Requires an approved connection, then a separate confirmation showing the recipient and the full text.
  - The approval is tied to the connection and request, expires in 60 seconds and is consumed immediately before the single Apple Event.
  - Request IDs are stored durably (UUIDs only; no text or recipient) and are rejected if repeated, including after restarts.
  - Only Messages is allowed as an Apple Events target. Unknown results are never retried.
  - Control and invisible Unicode characters are rejected so the confirmation text cannot mislead.
- **No content in logs.** The app does not log message text or recipients.

## Threat model and limits

- Another process running as the same user can start the adapter. The approval window is the control: approve only what you started.
- After approval, retrieved text can be sent by the connected tool to whatever service it uses.
- Stopping the bridge prevents new writes, but bytes already buffered cannot be recalled.
- A message already handed to Messages cannot be recalled.
- Archive decoding is incomplete; unsupported bodies are marked, not guessed.
- The request-ID journal is capped at 1,000 entries and fails closed when full; abrupt power loss behavior is unverified.
- Concurrent database integrity while Messages is writing has not been proven.
