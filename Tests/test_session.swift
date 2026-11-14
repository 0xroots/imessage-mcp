import Foundation

@main struct Test {
 static func main() {
  var now: TimeInterval = 100
  let authority = SessionAuthority(clock: { now })
  let limits = SessionAuthority.Limits(maxMessagesPerRequest: 2,
                                      maxMessagesPerSession: 3,
                                      requestsPerMinute: 2,
                                      durationSeconds: 120,
                                      maxResponseBytes: 4_096)!
  precondition(SessionAuthority.Limits(maxMessagesPerRequest: 101, maxMessagesPerSession: 3,
                                      requestsPerMinute: 2, durationSeconds: 120,
                                      maxResponseBytes: 4_096) == nil)
  precondition(SessionAuthority.Limits(maxMessagesPerRequest: 2, maxMessagesPerSession: 501,
                                      requestsPerMinute: 2, durationSeconds: 120,
                                      maxResponseBytes: 4_096) == nil)
  precondition(SessionAuthority.Limits(maxMessagesPerRequest: 2, maxMessagesPerSession: 3,
                                      requestsPerMinute: 61, durationSeconds: 120,
                                      maxResponseBytes: 4_096) == nil)
  precondition(SessionAuthority.Limits(maxMessagesPerRequest: 2, maxMessagesPerSession: 3,
                                      requestsPerMinute: 2, durationSeconds: 3_601,
                                      maxResponseBytes: 4_096) == nil)
  precondition(SessionAuthority.Limits(maxMessagesPerRequest: 2, maxMessagesPerSession: 3,
                                      requestsPerMinute: 2, durationSeconds: 120,
                                      maxResponseBytes: SessionAuthority.Limits.hardMaxResponseBytes + 1) == nil)
  let x = UUID(), y = UUID()

  precondition(!authority.grant(connection: x, mode: .assisted(["a"]), seconds: 60,
                                ownerConfirmed: true, warningConfirmed: false))
  precondition(authority.beginExplicitSession(limits: limits))
  precondition(!authority.beginExplicitSession(limits: limits), "active run must not reset quotas")
  precondition(!authority.grant(connection: x, mode: .full, seconds: 60,
                                ownerConfirmed: true, warningConfirmed: false))
  precondition(authority.grant(connection: x, mode: .assisted(["a"]), seconds: 120,
                               ownerConfirmed: true, warningConfirmed: false))
  precondition(authority.ticket(connection: y, chat: "a") == nil)
  guard let first = authority.ticket(connection: x, chat: "a") else { preconditionFailure("ticket missing") }
  precondition(first.remainingMessages == 3)
  precondition(first.limits.maxMessagesPerRequest == 2)
  precondition(authority.reserveMessages(first, count: 2))
  precondition(!authority.reserveMessages(first, count: 2), "reservation must respect run cap")
  precondition(authority.ticket(connection: x, chat: "b") == nil)
  precondition(authority.ticket(connection: x, chat: "a") == nil, "request cap shared across the run")

  // Reconnect and a new owner approval must not reset message or request quotas.
  authority.revoke(x)
  precondition(authority.grant(connection: y, mode: .assisted(["a"]), seconds: 120,
                               ownerConfirmed: true, warningConfirmed: false))
  precondition(authority.ticket(connection: y, chat: "a") == nil,
               "reconnect must not reset the current request window")
  now = 160
  guard let reconnected = authority.ticket(connection: y, chat: "a") else { preconditionFailure("window did not reset") }
  precondition(reconnected.remainingMessages == 1)
  precondition(authority.reserveMessages(reconnected, count: 1))
  precondition(!authority.reserveMessages(reconnected, count: 1), "session message quota must persist")

  // The shared run expiry remains anchored to Start, not to reconnect.
  now = 221
  precondition(!authority.explicitSessionIsCurrent())
  precondition(authority.ticket(connection: y, chat: "a") == nil)
  authority.endExplicitSession()
  precondition(authority.beginExplicitSession(limits: limits), "Stop may start a fresh explicit run")
  precondition(authority.grant(connection: y, mode: .full, seconds: 120,
                               ownerConfirmed: true, warningConfirmed: true))
  precondition(authority.ticket(connection: y, chat: nil) != nil)
  authority.endExplicitSession()

  // Cursor eviction stays bounded while the newest page remains usable.
  let cursorAuthority = SessionAuthority(clock: { now })
  precondition(cursorAuthority.beginExplicitSession(limits: limits))
  precondition(cursorAuthority.grant(connection: x, mode: .full, seconds: 120,
                                     ownerConfirmed: true, warningConfirmed: true))
  guard let cursorTicket = cursorAuthority.ticket(connection: x, chat: nil) else { preconditionFailure("cursor ticket missing") }
  var tokens: [String] = []
  for index in 0..<65 {
   let cursor = SessionAuthority.MessageCursor(timestampNanos: Int64(index), rowID: Int64(index), chatGUID: "chat")
   guard let token = cursorAuthority.issueCursor(cursorTicket, value: cursor, binding: "query-A") else { preconditionFailure("cursor issue failed") }
   tokens.append(token)
  }
  precondition(cursorAuthority.resolveMessageCursor(cursorTicket, token: tokens[0], binding: "query-A") == nil)
  let last = SessionAuthority.MessageCursor(timestampNanos: 64, rowID: 64, chatGUID: "chat")
  precondition(cursorAuthority.resolveMessageCursor(cursorTicket, token: tokens[64], binding: "query-A") == last)
  precondition(cursorAuthority.resolveMessageCursor(cursorTicket, token: tokens[64], binding: "query-B") == nil)
  precondition(cursorAuthority.issueCursor(cursorTicket, value: 12, binding: "list") != nil)
  cursorAuthority.revoke(x)
  precondition(cursorAuthority.resolveMessageCursor(cursorTicket, token: tokens[64], binding: "query-A") == nil)
  precondition(cursorAuthority.grant(connection: x, mode: .full, seconds: 120,
                                     ownerConfirmed: true, warningConfirmed: true))
  guard let newTicket = cursorAuthority.ticket(connection: x, chat: nil) else { preconditionFailure("new ticket missing") }
  precondition(cursorAuthority.resolveMessageCursor(newTicket, token: tokens[64], binding: "query-A") == nil)
  cursorAuthority.endExplicitSession()

  // Canonically equivalent but byte-distinct identifiers are not interchangeable.
  let exact = SessionAuthority(clock: { now })
  precondition(exact.beginExplicitSession(limits: limits))
  precondition(exact.grant(connection: x, mode: .assisted(["é"]), seconds: 120,
                           ownerConfirmed: true, warningConfirmed: false))
  precondition(exact.ticket(connection: x, chat: "e\u{301}") == nil)
  exact.endExplicitSession()
  // Budget exhaustion is reported once so the app can ask for a new approval.
  let budget = SessionAuthority(clock: { now })
  precondition(budget.beginExplicitSession(limits: limits))
  precondition(budget.grant(connection: x, mode: .assisted(["a"]), seconds: 120, ownerConfirmed: true, warningConfirmed: false))
  let bt = budget.ticket(connection: x, chat: "a")!
  precondition(budget.reserveMessages(bt, count: 2))
  precondition(!budget.takeBudgetDenied())
  precondition(!budget.reserveMessages(bt, count: 2))
  precondition(budget.takeBudgetDenied() && !budget.takeBudgetDenied())
  budget.endExplicitSession()

  // "No limits": large quotas and a long run, grants longer than the hard maximum are allowed.
  let free = SessionAuthority(clock: { now })
  let unlimited = SessionAuthority.Limits.unlimited
  precondition(unlimited.isUnlimited && !limits.isUnlimited)
  precondition(free.beginExplicitSession(limits: unlimited))
  precondition(free.grant(connection: x, mode: .assisted(["a"]), seconds: Double(unlimited.durationSeconds),
                          ownerConfirmed: true, warningConfirmed: false))
  let ft = free.ticket(connection: x, chat: "a")!
  precondition(free.reserveMessages(ft, count: 100) && free.reserveMessages(ft, count: 100))
  free.endExplicitSession()
  print("PASS owner start, hard limits, reconnect quotas, rate window, expiry, exact allowlist and cursor rotation")
 }
}
