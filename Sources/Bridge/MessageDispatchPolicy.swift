import Foundation
import Darwin

// In-memory, one-shot approval for a single send request. Approval payloads
// are never written to disk. Request IDs remain reserved across process
// restarts after cancellation, expiry, or consumption.
final class MessageDispatchPolicy {
 static let shared = MessageDispatchPolicy()

 static let approvalLifetime: TimeInterval = 60

 private enum ApprovalState {
  case pending
  case approved
 }

 private struct Approval {
  let requestID: UUID
  let recipient: String
  let text: String
  let connectionID: UUID
  let expiresAt: TimeInterval
  var state: ApprovalState
 }

 private let lock = NSLock()
 private var seenRequestIDs = Set<UUID>()
 private var approvals = [UUID: Approval]()
 // Durable app-lifetime cap: 1,000 unique IDs total, including prior launches.
 private let cap = 1000
 private let requestIDLedger: PersistentRequestIDLedger?
 // Reason for the most recent failed beginApproval/reserve; read under the same call path.
 enum ReserveFailure { case duplicate, full, unavailable }
 private(set) var lastFailure: ReserveFailure?

 // Passing a directory makes the policy use an isolated durable ledger there.
 // The default path is inside this app's sandboxed Application Support folder.
 // An unavailable default path leaves the ledger nil, which fails closed.
 init(storeDirectory: URL? = nil) {
  let directory = storeDirectory ?? Self.defaultStoreDirectory()
  requestIDLedger = directory.map(PersistentRequestIDLedger.init(directory:))
 }

 private static func defaultStoreDirectory() -> URL? {
  #if MCP_SYNTHETIC || MCP_TEST_AUTO
  let temporaryPath = FileManager.default.temporaryDirectory.path
  guard let resolved = temporaryPath.withCString({ realpath($0, nil) }) else { return nil }
  defer { free(resolved) }
  return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
   .appendingPathComponent("MessagesLocal-SyntheticApprovalLedger", isDirectory: true)
  #else
  guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
  return appSupport.appendingPathComponent("MessagesLocalSendPolicy", isDirectory: true)
  #endif
 }

 static func valid(recipient: String, text: String) -> Bool {
  let bytes = Array(recipient.utf8)
  guard (9...16).contains(bytes.count), bytes.first == 43,
        bytes.dropFirst().allSatisfy({ $0 >= 48 && $0 <= 57 }),
        bytes[1] != 48 else { return false }
  guard !text.isEmpty, text.utf8.count <= 4096, text.count <= 1000 else { return false }

  // Prevent invisible/bidirectional control characters from misleading the
  // owner in the exact-recipient/exact-text confirmation dialog.
  for scalar in text.unicodeScalars {
   let value = scalar.value
   if scalar.properties.isDefaultIgnorableCodePoint { return false }
   if (value < 32 && value != 9 && value != 10) || (value >= 0x7f && value <= 0x9f) ||
      (0x200b...0x200f).contains(value) || (0x202a...0x202e).contains(value) ||
      (0x2066...0x2069).contains(value) || value == 0xfeff { return false }
  }
  return true
 }

 // Starts a fresh pending approval and reserves requestID immediately. `now`
 // is process uptime, which is monotonic and straightforward to control in
 // synthetic tests. The returned UUID is an opaque, one-shot approval token.
 func beginApproval(requestID: UUID, recipient: String, text: String,
                    connectionID: UUID,
                    now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                    lifetime: TimeInterval = MessageDispatchPolicy.approvalLifetime) -> UUID? {
  guard Self.valid(recipient: recipient, text: text), now.isFinite,
        lifetime.isFinite, lifetime > 0 else { return nil }
  let expiresAt = now + lifetime
  guard expiresAt.isFinite else { return nil }

  lock.lock()
  defer { lock.unlock() }
  removeExpired(now: now)
  guard reserveRequestIDLocked(requestID) else { return nil }

  var token = UUID()
  while approvals[token] != nil { token = UUID() }
  approvals[token] = Approval(requestID: requestID, recipient: recipient,
                              text: text, connectionID: connectionID,
                              expiresAt: expiresAt, state: .pending)
  return token
 }

 // Approval is accepted only for the exact request that opened the prompt.
 // A mismatch destroys the token so an edited request cannot inherit consent.
 @discardableResult
 func approve(token: UUID, requestID: UUID, recipient: String, text: String,
              connectionID: UUID,
              now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
  guard now.isFinite else { return false }
  lock.lock()
  defer { lock.unlock() }
  removeExpired(now: now)
  guard var approval = approvals[token] else { return false }
  guard matches(approval, requestID: requestID, recipient: recipient,
                text: text, connectionID: connectionID),
        case .pending = approval.state else {
   approvals.removeValue(forKey: token)
   return false
  }
  approval.state = .approved
  approvals[token] = approval
  return true
 }

 // Cancelling consumes the request ID and removes its text from memory.
 @discardableResult
 func cancel(token: UUID) -> Bool {
  lock.lock()
  defer { lock.unlock() }
  return approvals.removeValue(forKey: token) != nil
 }

 // Disconnecting revokes every approval opened by that connection.
 func disconnect(connectionID: UUID) {
  lock.lock()
  defer { lock.unlock() }
  let revoked = approvals.filter { $0.value.connectionID == connectionID }.map(\.key)
  for token in revoked { approvals.removeValue(forKey: token) }
 }

 // Must be called at the dispatch boundary. Successful consumption is
 // atomic and one-shot; a tuple mismatch revokes the token immediately.
 @discardableResult
 func consume(token: UUID, requestID: UUID, recipient: String, text: String,
              connectionID: UUID,
              now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
  guard now.isFinite else { return false }
  lock.lock()
  defer { lock.unlock() }
  removeExpired(now: now)
  guard let approval = approvals[token] else { return false }
  guard matches(approval, requestID: requestID, recipient: recipient,
                text: text, connectionID: connectionID),
        case .approved = approval.state else {
   approvals.removeValue(forKey: token)
   return false
  }
  approvals.removeValue(forKey: token)
  return true
 }

 // Compatibility for call sites that only need durable request-ID
 // reservation. New confirmation flows should use beginApproval.
 func reserve(_ id: UUID) -> Bool {
  lock.lock()
  defer { lock.unlock() }
  return reserveRequestIDLocked(id)
 }

 private func reserveRequestIDLocked(_ id: UUID) -> Bool {
  lastFailure = nil
  guard !seenRequestIDs.contains(id) else { lastFailure = .duplicate; return false }
  guard seenRequestIDs.count < cap else { lastFailure = .full; return false }
  guard let requestIDLedger else { lastFailure = .unavailable; return false }
  switch requestIDLedger.reserve(id, cap: cap) {
  case .reserved: seenRequestIDs.insert(id); return true
  case .duplicate: seenRequestIDs.insert(id); lastFailure = .duplicate; return false
  case .full: lastFailure = .full; return false
  case .unavailable: lastFailure = .unavailable; return false
  }
 }

 private func matches(_ approval: Approval, requestID: UUID, recipient: String,
                      text: String, connectionID: UUID) -> Bool {
  approval.requestID == requestID && approval.connectionID == connectionID &&
   approval.recipient.utf8.elementsEqual(recipient.utf8) &&
   approval.text.utf8.elementsEqual(text.utf8)
 }

 private func removeExpired(now: TimeInterval) {
  let expired = approvals.filter { $0.value.expiresAt <= now }.map(\.key)
  for token in expired { approvals.removeValue(forKey: token) }
 }
}

// Cross-instance and cross-process durable request-ID ledger. Its only data
// file contains canonical UUID strings. A sidecar flock serializes updates;
// replacements are written through O_EXCL/O_NOFOLLOW, fsynced, then renamed.
private final class PersistentRequestIDLedger {
 private static let inProcessLock = NSLock()
 private let directoryURL: URL
 private let dataName = "send-request-ids.txt"
 private let lockName = "send-request-ids.lock"
 private let maxIDs = 1000
 private let maxBytes = 37_000

 init(directory: URL) {
  directoryURL = directory
 }

 enum ReserveResult { case reserved, duplicate, full, unavailable }

 func reserve(_ id: UUID, cap: Int) -> ReserveResult {
  Self.inProcessLock.lock()
  defer { Self.inProcessLock.unlock() }
  guard cap > 0, cap <= maxIDs else { return .unavailable }
  guard let directoryFD = openDirectory() else { return .unavailable }
  defer { _ = close(directoryFD) }
  guard let openedLock = openLockFile(in: directoryFD) else { return .unavailable }
  let lockFD = openedLock.descriptor
  defer {
   var unlock = Darwin.flock()
   unlock.l_type = Int16(F_UNLCK)
   unlock.l_whence = Int16(SEEK_SET)
   _ = fcntl(lockFD, F_SETLK, &unlock)
   _ = close(lockFD)
  }
  var fileLock = Darwin.flock()
  fileLock.l_type = Int16(F_WRLCK)
  fileLock.l_whence = Int16(SEEK_SET)
  guard fcntl(lockFD, F_SETLKW, &fileLock) == 0,
        let currentIDs = readIDs(in: directoryFD, allowMissing: openedLock.created) else { return .unavailable }
  // Duplicate is checked before capacity so a replayed ID is never reported as "full".
  guard !currentIDs.contains(id) else { return .duplicate }
  guard currentIDs.count < cap else { return .full }
  var nextIDs = currentIDs
  nextIDs.insert(id)
  return writeIDs(nextIDs, in: directoryFD) ? .reserved : .unavailable
 }

 private func openDirectory() -> Int32? {
  let path = directoryURL.path
  // App Sandbox denies opening ancestors such as /Users, even when the final
  // container directory is accessible. Anchor directly at the OS-provided
  // Application Support directory, then validate and open the private child.
  var trustedParent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
  #if MCP_SYNTHETIC || MCP_TEST_AUTO
  // The synthetic ledger lives in the sandbox's own temporary directory.
  // Walking /Users from the sandbox fails, so anchor at that OS-provided
  // directory only in synthetic builds. Production never selects it.
  let temporaryPath = FileManager.default.temporaryDirectory.path
  if let resolved = temporaryPath.withCString({ realpath($0, nil) }) {
   let temporary = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
   free(resolved)
   if directoryURL.deletingLastPathComponent().path == temporary.path {
    trustedParent = temporary
   }
  }
  #endif
  if let support = trustedParent,
     directoryURL.deletingLastPathComponent().path == support.path {
   let name = directoryURL.lastPathComponent
   guard !name.isEmpty, name != ".", name != ".." else { return nil }
   let parent = open(support.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
   guard parent >= 0 else { return nil }
   defer { _ = close(parent) }
   var parentInfo = stat()
   guard fstat(parent, &parentInfo) == 0, (parentInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
         parentInfo.st_uid == getuid(), (parentInfo.st_mode & 0o077) == 0 else { return nil }
   var child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
   if child < 0 && errno == ENOENT {
    guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { return nil }
    child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
   }
   guard child >= 0 else { return nil }
   var info = stat()
   guard fstat(child, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
         info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else { _ = close(child); return nil }
   return child
  }
  guard path.hasPrefix("/"), path != "/" else { return nil }
  let components = path.split(separator: "/").map(String.init)
  guard !components.isEmpty, !components.contains("."), !components.contains("..") else { return nil }

  var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard current >= 0 else { return nil }
  for (index, component) in components.enumerated() {
   let isFinal = index == components.count - 1
   var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
   var created = false
   if next < 0, errno == ENOENT {
    let made = mkdirat(current, component, 0o700)
    guard made == 0 || errno == EEXIST else {
     _ = close(current)
     return nil
    }
    created = made == 0
    next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
   }
   guard next >= 0 else {
    _ = close(current)
    return nil
   }
   var info = stat()
   guard fstat(next, &info) == 0,
         (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
         (!created && !isFinal) || (info.st_uid == getuid() && (info.st_mode & 0o077) == 0) else {
    _ = close(next)
    _ = close(current)
    return nil
   }
   if created {
    guard fchmod(next, 0o700) == 0 else {
     _ = close(next)
     _ = close(current)
     return nil
    }
   }
   if isFinal && (info.st_mode & 0o700) != 0o700 {
    guard fchmod(next, 0o700) == 0 else {
     _ = close(next)
     _ = close(current)
     return nil
    }
   }
   _ = close(current)
   current = next
  }
  return current
 }

 private func openLockFile(in directoryFD: Int32) -> (descriptor: Int32, created: Bool)? {
  var descriptor = openat(directoryFD, lockName,
                          O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                          0o600)
  let created = descriptor >= 0
  if created {
   // Persist the initialization marker before permitting an empty ledger.
   // An interrupted initialization subsequently fails closed.
   guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0,
         fsync(directoryFD) == 0 else {
    _ = close(descriptor)
    return nil
   }
  } else if errno == EEXIST {
   descriptor = openat(directoryFD, lockName,
                       O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
  }
  guard descriptor >= 0 else { return nil }
  var info = stat()
  guard fstat(descriptor, &info) == 0,
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        info.st_uid == getuid(), (info.st_mode & 0o777) == 0o600,
        info.st_nlink == 1, info.st_size == 0 else {
   _ = close(descriptor)
   return nil
  }
  return (descriptor, created)
 }

 private func readIDs(in directoryFD: Int32, allowMissing: Bool) -> Set<UUID>? {
  let descriptor = openat(directoryFD, dataName,
                           O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
  if descriptor < 0 {
   return errno == ENOENT && allowMissing ? Set<UUID>() : nil
  }
  defer { _ = close(descriptor) }

  var info = stat()
  guard fstat(descriptor, &info) == 0,
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        info.st_uid == getuid(), (info.st_mode & 0o777) == 0o600,
        info.st_nlink == 1, info.st_size > 0, info.st_size <= off_t(maxBytes) else { return nil }

  var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
  let count = bytes.withUnsafeMutableBytes { buffer -> Int? in
   guard let base = buffer.baseAddress else { return nil }
   var offset = 0
   while offset < buffer.count {
    let received = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
    if received < 0 {
     if errno == EINTR { continue }
     return nil
    }
    if received == 0 { break }
    offset += received
   }
   return offset
  }
  guard count == bytes.count, let content = String(bytes: bytes, encoding: .utf8),
        content.last == "\n" else { return nil }

  var ids = Set<UUID>()
  for line in content.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
   let value = String(line)
   guard let uuid = UUID(uuidString: value), value == uuid.uuidString.lowercased(),
         ids.insert(uuid).inserted, ids.count <= maxIDs else { return nil }
  }
  guard !ids.isEmpty else { return nil }
  return ids
 }

 private func writeIDs(_ ids: Set<UUID>, in directoryFD: Int32) -> Bool {
  guard !ids.isEmpty, ids.count <= maxIDs else { return false }
  let content = ids.map { $0.uuidString.lowercased() }.sorted().joined(separator: "\n") + "\n"
  guard let data = content.data(using: .utf8), data.count <= maxBytes else { return false }

  var temporaryName: String?
  var descriptor: Int32 = -1
  for _ in 0..<4 {
   let candidate = ".send-request-ids-\(UUID().uuidString.lowercased()).tmp"
   descriptor = openat(directoryFD, candidate,
                       O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                       0o600)
   if descriptor >= 0 {
    temporaryName = candidate
    break
   }
   if errno != EEXIST { return false }
  }
  guard descriptor >= 0, let temporaryName else { return false }
  var didRename = false
  defer {
   _ = close(descriptor)
   if !didRename { _ = unlinkat(directoryFD, temporaryName, 0) }
  }
  guard fchmod(descriptor, 0o600) == 0,
        writeAll(data, to: descriptor), fsync(descriptor) == 0 else { return false }
  var temporaryInfo = stat()
  guard fstat(descriptor, &temporaryInfo) == 0,
        (temporaryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        temporaryInfo.st_uid == getuid(), (temporaryInfo.st_mode & 0o777) == 0o600,
        temporaryInfo.st_nlink == 1 else { return false }

  var existingInfo = stat()
  if fstatat(directoryFD, dataName, &existingInfo, AT_SYMLINK_NOFOLLOW) == 0 {
   guard (existingInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
         existingInfo.st_uid == getuid(), (existingInfo.st_mode & 0o777) == 0o600,
         existingInfo.st_nlink == 1 else { return false }
  } else if errno != ENOENT {
   return false
  }
  guard renameat(directoryFD, temporaryName, directoryFD, dataName) == 0 else { return false }
  didRename = true
  return fsync(directoryFD) == 0
 }

 private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
  data.withUnsafeBytes { raw in
   guard let base = raw.baseAddress else { return false }
   var offset = 0
   while offset < raw.count {
    let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
    if written < 0 {
     if errno == EINTR { continue }
     return false
    }
    if written == 0 { return false }
    offset += written
   }
   return true
  }
 }
}
