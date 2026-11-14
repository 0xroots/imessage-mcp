#!/bin/bash
# Compiles and runs the standalone unit tests. No signing or Messages access needed.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CLANG_MODULE_CACHE_PATH="$tmp/cache"
S="$root/Sources"; T="$root/Tests"
sed -e 's/@TEAM_ID@/TESTTEAM/' -e 's/@APP_ID@/test.app/' -e 's/@ADAPTER_ID@/test.mcp/' \
  "$S/Shared/BuildIdentity.swift.in" > "$tmp/BuildIdentity.swift"
run() { name="$1"; shift; xcrun swiftc "$@" -lsqlite3 -o "$tmp/$name" && "$tmp/$name"; }
run policy "$S/Bridge/MessageDispatchPolicy.swift" "$T/test_message_dispatch_policy.swift"
run sender "$S/Bridge/SendMessagesAppleEvents.swift" "$T/test_send_messages_apple_events.swift"
run session "$S/Bridge/SessionAuthority.swift" "$T/test_session.swift"
run writer "$S/Bridge/RevocableSocketWriter.swift" "$T/test_revocable_writer.swift"
run socket "$S/Bridge/LocalSocketIO.swift" "$T/test_local_socket_io.swift"
run access "$S/Reader/AccessPolicy.swift" "$T/test_access_policy.swift"
echo "All tests passed"
