import Foundation

// A bridge run is explicitly started by the owner and shared by all approved
// connections until Stop. Reconnecting never resets its quotas or expiry.
final class SessionAuthority {
 enum Mode { case assisted(Set<String>), full }
 enum Decision: Equatable { case allowed, denied, expired, rateLimited }

 struct Limits: Equatable {
  static let defaults = Limits(
   maxMessagesPerRequest: 20,
   maxMessagesPerSession: 100,
   requestsPerMinute: 30,
   durationSeconds: 900,
   maxResponseBytes: 65_536
  )!

  // Owner chose "no limits": quotas are lifted except the ceilings that are
  // technical (100 results per call, 120 KiB reply). Connections still need approval.
  static let unlimited = Limits(unchecked: 100, 1_000_000_000, 1_000_000, 10 * 365 * 86_400, 120 * 1_024)
  var isUnlimited: Bool { self == Limits.unlimited }

  static let hardMaxMessagesPerRequest = 100
  static let hardMaxMessagesPerSession = 500
  static let hardMaxRequestsPerMinute = 60
  static let hardMaxDurationSeconds = 3_600
  // Keep this aligned with MessagesMCPAdapter's maximum reply line length.
  // Leaves room for the adapter's outer MCP JSON/text escaping below 256 KiB.
  static let hardMaxResponseBytes = 120 * 1_024
  static let minResponseBytes = 1_024

  let maxMessagesPerRequest: Int
  let maxMessagesPerSession: Int
  let requestsPerMinute: Int
  let durationSeconds: Int
  let maxResponseBytes: Int

  private init(unchecked perRequest: Int, _ perSession: Int, _ perMinute: Int, _ seconds: Int, _ bytes: Int) {
   maxMessagesPerRequest = perRequest
   maxMessagesPerSession = perSession
   requestsPerMinute = perMinute
   durationSeconds = seconds
   maxResponseBytes = bytes
  }

  init?(maxMessagesPerRequest: Int,
        maxMessagesPerSession: Int,
        requestsPerMinute: Int,
        durationSeconds: Int,
        maxResponseBytes: Int) {
   guard (1...Self.hardMaxMessagesPerRequest).contains(maxMessagesPerRequest),
         (1...Self.hardMaxMessagesPerSession).contains(maxMessagesPerSession),
         (1...Self.hardMaxRequestsPerMinute).contains(requestsPerMinute),
         (1...Self.hardMaxDurationSeconds).contains(durationSeconds),
         (Self.minResponseBytes...Self.hardMaxResponseBytes).contains(maxResponseBytes) else { return nil }
   self.maxMessagesPerRequest = maxMessagesPerRequest
   self.maxMessagesPerSession = maxMessagesPerSession
   self.requestsPerMinute = requestsPerMinute
   self.durationSeconds = durationSeconds
   self.maxResponseBytes = maxResponseBytes
  }
 }

 struct Ticket {
  let connection: UUID
  let generation: UUID
  let runGeneration: UUID
  let mode: Mode
  let limits: Limits
  // Remaining maximum message result slots in the owner-started bridge run.
  let remainingMessages: Int
 }

 struct MessageCursor: Equatable {
  let timestampNanos: Int64?
  let rowID: Int64
  let chatGUID: String
 }

 private enum CursorValue {
  case offset(Int64)
  case message(MessageCursor)
 }
 private struct Cursor {
  let value: CursorValue
  let binding: String
  let order: UInt64
 }
 private struct Session {
  let generation: UUID
  let runGeneration: UUID
  let mode: Mode
  let expires: TimeInterval
  var cursors: [String: Cursor]
  var nextCursorOrder: UInt64
 }
 private struct ExplicitRun {
  let generation: UUID
  let limits: Limits
  let expires: TimeInterval
  var bucketStart: TimeInterval
  var requestCount: Int
  var reservedMessages: Int
 }

 private let lock = NSLock()
 private var sessions: [UUID: Session] = [:]
 private var run: ExplicitRun?
 private let clock: () -> TimeInterval
 private let maximumCursorsPerConnection = 64

 init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
  self.clock = clock
 }

 // Called only after the owner chooses Start AI bridge and accepts limits.
 // A second active run cannot replace or reset the first run's counters.
 // Set when a client asked for more message slots than the run has left; the app
 // reads it once to ask the owner for a new approval.
 private var budgetDenied = false
 func takeBudgetDenied() -> Bool {
  lock.lock(); defer { lock.unlock() }
  defer { budgetDenied = false }
  return budgetDenied
 }

 func beginExplicitSession(limits: Limits) -> Bool {
  lock.lock(); defer { lock.unlock() }
  guard run == nil else { return false }
  budgetDenied = false
  let now = clock()
  run = ExplicitRun(generation: UUID(), limits: limits, expires: now + Double(limits.durationSeconds),
                    bucketStart: now, requestCount: 0, reservedMessages: 0)
  return true
 }

 // Stop invalidates all tickets and cursors immediately and resets run budgets.
 func endExplicitSession() {
  lock.lock(); defer { lock.unlock() }
  sessions.removeAll()
  run = nil
 }

 func grant(connection: UUID, mode: Mode, seconds: TimeInterval,
            ownerConfirmed: Bool, warningConfirmed: Bool) -> Bool {
  // The run-wide bound below (never above the hard maximum for custom limits) caps the grant.
  guard ownerConfirmed, seconds > 0 else { return false }
  switch mode {
  case .full:
   guard warningConfirmed else { return false }
  case .assisted(let chats):
   guard !chats.isEmpty, chats.count <= 1_000,
         chats.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains(0) }) else { return false }
  }
  lock.lock(); defer { lock.unlock() }
  guard let activeRun = run, seconds <= Double(activeRun.limits.durationSeconds) else { return false }
  let now = clock()
  guard now < activeRun.expires else { return false }
  sessions[connection] = Session(generation: UUID(), runGeneration: activeRun.generation,
                                 mode: mode, expires: min(activeRun.expires, now + seconds),
                                 cursors: [:], nextCursorOrder: 0)
  return true
 }

 func revoke(_ connection: UUID) {
  lock.lock(); defer { lock.unlock() }
  sessions.removeValue(forKey: connection)
 }

 // Retained for tests and explicit mass revocation; unlike Stop it does not
 // create a fresh run or reset quotas.
 func revokeAll() {
  lock.lock(); defer { lock.unlock() }
  sessions.removeAll()
 }

 func currentMode(connection: UUID) -> Mode? {
  lock.lock(); defer { lock.unlock() }
  guard let session = sessions[connection], let activeRun = run,
        session.runGeneration == activeRun.generation,
        clock() < session.expires, clock() < activeRun.expires else {
   sessions.removeValue(forKey: connection)
   return nil
  }
  return session.mode
 }

 func explicitSessionIsCurrent() -> Bool {
  lock.lock(); defer { lock.unlock() }
  guard let activeRun = run else { return false }
  return clock() < activeRun.expires
 }

 func ticket(connection: UUID, chat: String?, allowAssistedListing: Bool = false) -> Ticket? {
  lock.lock(); defer { lock.unlock() }
  let now = clock()
  guard let session = sessions[connection], var activeRun = run,
        session.runGeneration == activeRun.generation else { return nil }
  guard now < session.expires, now < activeRun.expires else {
   sessions.removeValue(forKey: connection)
   return nil
  }
  if now - activeRun.bucketStart >= 60 {
   activeRun.bucketStart = now
   activeRun.requestCount = 0
  }
  guard activeRun.requestCount < activeRun.limits.requestsPerMinute else {
   run = activeRun
   return nil
  }
  activeRun.requestCount += 1
  run = activeRun
  switch session.mode {
  case .full:
   break
  case .assisted(let chats):
   if let chat {
    guard chats.contains(where: { $0.utf8.elementsEqual(chat.utf8) }) else { return nil }
   } else {
    guard allowAssistedListing else { return nil }
   }
  }
  sessions[connection] = session
  return Ticket(connection: connection, generation: session.generation,
                runGeneration: activeRun.generation, mode: session.mode,
                limits: activeRun.limits,
                remainingMessages: max(0, activeRun.limits.maxMessagesPerSession - activeRun.reservedMessages))
 }

 // Reserve the maximum number of message-result slots before the backend read.
 // Reservations are not refunded on errors; this makes concurrent callers and
 // failed delivery conservative. Search misses also consume their requested cap.
 func reserveMessages(_ ticket: Ticket, count: Int) -> Bool {
  guard count > 0, count <= ticket.limits.maxMessagesPerRequest else { return false }
  lock.lock(); defer { lock.unlock() }
  let now = clock()
  guard let session = sessions[ticket.connection], session.generation == ticket.generation,
        session.runGeneration == ticket.runGeneration,
        var activeRun = run, activeRun.generation == ticket.runGeneration,
        now < session.expires, now < activeRun.expires else { return false }
  guard count <= activeRun.limits.maxMessagesPerSession - activeRun.reservedMessages else {
   budgetDenied = true
   return false
  }
  activeRun.reservedMessages += count
  run = activeRun
  return true
 }

 func isCurrent(_ ticket: Ticket) -> Bool {
  lock.lock(); defer { lock.unlock() }
  guard let session = sessions[ticket.connection], let activeRun = run else { return false }
  return session.generation == ticket.generation && session.runGeneration == ticket.runGeneration &&
         activeRun.generation == ticket.runGeneration && clock() < session.expires && clock() < activeRun.expires
 }

 func issueCursor(_ ticket: Ticket, value: Int64, binding: String) -> String? {
  issueCursor(ticket, cursorValue: .offset(value), binding: binding)
 }

 func issueCursor(_ ticket: Ticket, value: MessageCursor, binding: String) -> String? {
  guard value.rowID >= 0, !value.chatGUID.isEmpty, value.chatGUID.utf8.count <= 512,
        !value.chatGUID.utf8.contains(0) else { return nil }
  return issueCursor(ticket, cursorValue: .message(value), binding: binding)
 }

 private func issueCursor(_ ticket: Ticket, cursorValue: CursorValue, binding: String) -> String? {
  guard binding.utf8.count <= 4_096 else { return nil }
  lock.lock(); defer { lock.unlock() }
  guard var session = sessions[ticket.connection], session.generation == ticket.generation,
        session.runGeneration == ticket.runGeneration, let activeRun = run,
        activeRun.generation == ticket.runGeneration, clock() < session.expires,
        clock() < activeRun.expires else { return nil }
  if session.cursors.count >= maximumCursorsPerConnection,
     let oldest = session.cursors.min(by: { $0.value.order < $1.value.order })?.key {
   session.cursors.removeValue(forKey: oldest)
  }
  let token = UUID().uuidString
  let order = session.nextCursorOrder
  session.nextCursorOrder &+= 1
  session.cursors[token] = Cursor(value: cursorValue, binding: binding, order: order)
  sessions[ticket.connection] = session
  return token
 }

 func resolveCursor(_ ticket: Ticket, token: String, binding: String) -> Int64? {
  guard token.utf8.count <= 64 else { return nil }
  lock.lock(); defer { lock.unlock() }
  guard let session = sessions[ticket.connection], session.generation == ticket.generation,
        session.runGeneration == ticket.runGeneration, let activeRun = run,
        activeRun.generation == ticket.runGeneration, clock() < session.expires,
        clock() < activeRun.expires, let cursor = session.cursors[token],
        cursor.binding == binding, case .offset(let value) = cursor.value else { return nil }
  return value
 }

 func resolveMessageCursor(_ ticket: Ticket, token: String, binding: String) -> MessageCursor? {
  guard token.utf8.count <= 64 else { return nil }
  lock.lock(); defer { lock.unlock() }
  guard let session = sessions[ticket.connection], session.generation == ticket.generation,
        session.runGeneration == ticket.runGeneration, let activeRun = run,
        activeRun.generation == ticket.runGeneration, clock() < session.expires,
        clock() < activeRun.expires, let cursor = session.cursors[token],
        cursor.binding == binding, case .message(let value) = cursor.value else { return nil }
  return value
 }

 func decide(connection: UUID, chat: String?) -> Decision {
  lock.lock(); defer { lock.unlock() }
  let now = clock()
  guard let session = sessions[connection], var activeRun = run,
        session.runGeneration == activeRun.generation else { return .denied }
  guard now < session.expires, now < activeRun.expires else {
   sessions.removeValue(forKey: connection)
   return .expired
  }
  if now - activeRun.bucketStart >= 60 {
   activeRun.bucketStart = now
   activeRun.requestCount = 0
  }
  guard activeRun.requestCount < activeRun.limits.requestsPerMinute else {
   run = activeRun
   return .rateLimited
  }
  activeRun.requestCount += 1
  run = activeRun
  switch session.mode {
  case .full: return .allowed
  case .assisted(let chats):
   guard let chat, chats.contains(where: { $0.utf8.elementsEqual(chat.utf8) }) else { return .denied }
   return .allowed
  }
 }
}
