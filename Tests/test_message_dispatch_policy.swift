import Foundation
import Darwin

@main struct Test {
 static let recipient = "+15555550123"
 static let text = "Synthetic test\nsecond line"

 static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
 }

 static func main() {
  if runReservationWorkerIfRequested() { return }
  testValidationAndLegacyReservation()
  testApprovalIsBoundAndOneShot()
  testModificationInvalidatesApproval()
  testRecipientAndConnectionBinding()
  testCancelConsumesRequestID()
  testExpiryConsumesRequestID()
  testDisconnectRevokesPendingAndApproved()
  testDuplicateRequestIDs()
  testDurableDuplicateAcrossRestart()
  testMissingLedgerFailsClosed()
  testUnsafeStoreFailsClosed()
  testConcurrentDuplicateReservation()
  testCrossProcessDuplicateReservation()
  testPersistentCapacityAcrossRestart()
  testSyntheticAppSupportContainer()
  #if MCP_SYNTHETIC || MCP_TEST_AUTO
  require(MessageDispatchPolicy.shared.reserve(UUID()), "synthetic build uses a writable temporary ledger")
  #endif
  print("PASS exact approval and durable duplicate policy: restart, expiry, cancel, disconnect, symlink, concurrency, cap")
 }

 static func runReservationWorkerIfRequested() -> Bool {
  let args = CommandLine.arguments
  guard args.count == 4, args[1] == "--reserve-once",
        let requestID = UUID(uuidString: args[3]) else { return false }
  usleep(100_000)
  let policy = MessageDispatchPolicy(storeDirectory: URL(fileURLWithPath: args[2], isDirectory: true))
  exit(policy.reserve(requestID) ? 0 : 3)
 }

 static func makePolicy() -> (MessageDispatchPolicy, URL) {
  let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
   .appendingPathComponent("message-policy-test-\(UUID().uuidString)", isDirectory: true)
  do {
   try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
  } catch {
   fatalError("FAIL: create synthetic policy directory: \(error)")
  }
  guard chmod(directory.path, 0o700) == 0 else { fatalError("FAIL: secure synthetic policy directory") }
  return (MessageDispatchPolicy(storeDirectory: directory), directory)
 }

 static func removeTestDirectory(_ directory: URL) {
  try? FileManager.default.removeItem(at: directory)
 }

 static func testValidationAndLegacyReservation() {
  require(MessageDispatchPolicy.valid(recipient: recipient, text: text), "valid recipient/text")
  require(!MessageDispatchPolicy.valid(recipient: "5555550123", text: "x"), "reject non-E.164 recipient")
  require(!MessageDispatchPolicy.valid(recipient: recipient, text: "x\u{202e}y"), "reject bidi control")
  require(!MessageDispatchPolicy.valid(recipient: recipient, text: "x\u{2060}y"), "reject default ignorable")
  require(MessageDispatchPolicy.valid(recipient: recipient, text: "love \u{2764}\u{FE0F}"), "allow emoji variation selector")
  require(MessageDispatchPolicy.valid(recipient: recipient, text: "family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"), "allow emoji ZWJ sequence")
  require(!MessageDispatchPolicy.valid(recipient: recipient, text: "x\u{200D}y"), "reject bare ZWJ")
  require(!MessageDispatchPolicy.valid(recipient: recipient, text: "x\u{FE0F}"), "reject bare variation selector")
  require(MessageDispatchPolicy.invalidReason(recipient: "Ash", text: "x") == "recipient_not_e164", "reason: recipient")
  require(MessageDispatchPolicy.invalidReason(recipient: recipient, text: "x\u{2060}y") == "text_hidden_characters", "reason: hidden")
  require(MessageDispatchPolicy.invalidReason(recipient: recipient, text: "") == "text_empty", "reason: empty")
  require(!MessageDispatchPolicy.valid(recipient: recipient, text: String(repeating: "x", count: 1001)), "reject oversized text")

  let (policy, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let id = UUID()
  require(policy.reserve(id), "legacy reservation succeeds once")
  require(!policy.reserve(id), "legacy reservation rejects duplicate")
  require(policy.reserve(UUID()), "legacy reservation accepts a different ID")
 }

 static func testApprovalIsBoundAndOneShot() {
  let (policy, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let requestID = UUID(), connectionID = UUID()
  guard let token = policy.beginApproval(requestID: requestID, recipient: recipient,
                                         text: text, connectionID: connectionID,
                                         now: 100, lifetime: 20) else {
   fatalError("FAIL: begin exact approval")
  }
  require(policy.approve(token: token, requestID: requestID, recipient: recipient,
                         text: text, connectionID: connectionID, now: 101), "approve exact request")
  require(policy.consume(token: token, requestID: requestID, recipient: recipient,
                         text: text, connectionID: connectionID, now: 102), "consume approved request")
  require(!policy.consume(token: token, requestID: requestID, recipient: recipient,
                          text: text, connectionID: connectionID, now: 103), "approval is one shot")
  require(policy.beginApproval(requestID: requestID, recipient: recipient, text: text,
                               connectionID: connectionID, now: 104) == nil,
          "consumed request ID remains reserved")
 }

 static func testModificationInvalidatesApproval() {
  let (policy, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let requestID = UUID(), connectionID = UUID()
  // These strings compare equal under Swift's canonical-equivalence rules but
  // contain different UTF-8 bytes; approval must bind to the exact payload.
  let composed = "Cafe\u{00e9}"
  let decomposed = "Cafe\u{0065}\u{0301}"
  require(composed == decomposed, "fixture uses canonically equivalent strings")
  guard let token = policy.beginApproval(requestID: requestID, recipient: recipient,
                                         text: composed, connectionID: connectionID,
                                         now: 200, lifetime: 20) else {
   fatalError("FAIL: begin modification test")
  }
  require(!policy.approve(token: token, requestID: requestID, recipient: recipient,
                          text: decomposed, connectionID: connectionID, now: 201),
          "modified text cannot receive approval")
  require(!policy.approve(token: token, requestID: requestID, recipient: recipient,
                          text: composed, connectionID: connectionID, now: 202),
          "text mismatch destroys the approval token")

  let secondID = UUID()
  guard let secondToken = policy.beginApproval(requestID: secondID, recipient: recipient,
                                               text: text, connectionID: connectionID,
                                               now: 210, lifetime: 20) else {
   fatalError("FAIL: begin tuple mismatch test")
  }
  require(policy.approve(token: secondToken, requestID: secondID, recipient: recipient,
                         text: text, connectionID: connectionID, now: 211), "approve second exact request")
  require(!policy.consume(token: secondToken, requestID: secondID, recipient: recipient,
                          text: "edited after approval", connectionID: connectionID, now: 212),
          "modified text cannot consume approval")
  require(!policy.consume(token: secondToken, requestID: secondID, recipient: recipient,
                          text: text, connectionID: connectionID, now: 213),
          "failed exact-payload check invalidates approval")

  let thirdID = UUID()
  guard let thirdToken = policy.beginApproval(requestID: thirdID, recipient: recipient,
                                              text: text, connectionID: connectionID,
                                              now: 220, lifetime: 20) else {
   fatalError("FAIL: begin request-ID mismatch test")
  }
  require(!policy.approve(token: thirdToken, requestID: UUID(), recipient: recipient,
                          text: text, connectionID: connectionID, now: 221),
          "different request ID cannot approve token")
 }

 static func testRecipientAndConnectionBinding() {
  let (policy, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let requestID = UUID(), connectionID = UUID()
  guard let recipientToken = policy.beginApproval(requestID: requestID, recipient: recipient,
                                                   text: text, connectionID: connectionID,
                                                   now: 250, lifetime: 20) else {
   fatalError("FAIL: begin recipient binding test")
  }
  require(!policy.approve(token: recipientToken, requestID: requestID, recipient: "+15555550124",
                          text: text, connectionID: connectionID, now: 251),
          "changed recipient cannot receive approval")
  require(!policy.approve(token: recipientToken, requestID: requestID, recipient: recipient,
                          text: text, connectionID: connectionID, now: 252),
          "recipient mismatch destroys the approval token")

  let connectionBoundID = UUID(), otherConnection = UUID()
  guard let connectionToken = policy.beginApproval(requestID: connectionBoundID, recipient: recipient,
                                                    text: text, connectionID: connectionID,
                                                    now: 260, lifetime: 20) else {
   fatalError("FAIL: begin connection binding test")
  }
  require(policy.approve(token: connectionToken, requestID: connectionBoundID, recipient: recipient,
                         text: text, connectionID: connectionID, now: 261), "approve connection-bound request")
  require(!policy.consume(token: connectionToken, requestID: connectionBoundID, recipient: recipient,
                          text: text, connectionID: otherConnection, now: 262),
          "different connection cannot consume approval")
  require(!policy.consume(token: connectionToken, requestID: connectionBoundID, recipient: recipient,
                          text: text, connectionID: connectionID, now: 263),
          "connection mismatch destroys the approval token")

  let idBoundRequestID = UUID()
  guard let idToken = policy.beginApproval(requestID: idBoundRequestID, recipient: recipient,
                                            text: text, connectionID: connectionID,
                                            now: 270, lifetime: 20) else {
   fatalError("FAIL: begin request-ID dispatch binding test")
  }
  require(policy.approve(token: idToken, requestID: idBoundRequestID, recipient: recipient,
                         text: text, connectionID: connectionID, now: 271), "approve request-ID-bound send")
  require(!policy.consume(token: idToken, requestID: UUID(), recipient: recipient,
                          text: text, connectionID: connectionID, now: 272),
          "different request ID cannot consume approval")
 }

 static func testCancelConsumesRequestID() {
  let (policy, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let requestID = UUID(), connectionID = UUID()
  guard let token = policy.beginApproval(requestID: requestID, recipient: recipient,
                                         text: text, connectionID: connectionID,
                                         now: 300, lifetime: 20) else {
   fatalError("FAIL: begin cancellation test")
  }
  require(policy.cancel(token: token), "cancel pending approval")
  require(!policy.approve(token: token, requestID: requestID, recipient: recipient,
                          text: text, connectionID: connectionID, now: 301), "cancelled token cannot approve")
  require(policy.beginApproval(requestID: requestID, recipient: recipient, text: text,
                               connectionID: connectionID, now: 302) == nil,
          "cancelled request ID cannot be reused")

  let approvedID = UUID()
  guard let approvedToken = policy.beginApproval(requestID: approvedID, recipient: recipient,
                                                  text: text, connectionID: connectionID,
                                                  now: 310, lifetime: 20) else {
   fatalError("FAIL: begin approved cancellation test")
  }
  require(policy.approve(token: approvedToken, requestID: approvedID, recipient: recipient,
                         text: text, connectionID: connectionID, now: 311), "approve before cancellation")
  require(policy.cancel(token: approvedToken), "cancel approved send")
  require(!policy.consume(token: approvedToken, requestID: approvedID, recipient: recipient,
                           text: text, connectionID: connectionID, now: 312), "cancelled approval cannot dispatch")
 }

 static func testExpiryConsumesRequestID() {
  let (policy, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let requestID = UUID(), connectionID = UUID()
  guard let token = policy.beginApproval(requestID: requestID, recipient: recipient,
                                         text: text, connectionID: connectionID,
                                         now: 400, lifetime: 10) else {
   fatalError("FAIL: begin expiry test")
  }
  require(!policy.approve(token: token, requestID: requestID, recipient: recipient,
                          text: text, connectionID: connectionID, now: 410), "expired pending approval cannot approve")
  require(policy.beginApproval(requestID: requestID, recipient: recipient, text: text,
                               connectionID: connectionID, now: 411) == nil,
          "expired request ID cannot be reused")
  require(MessageDispatchPolicy(storeDirectory: directory).beginApproval(
           requestID: requestID, recipient: recipient, text: text,
           connectionID: connectionID, now: 412) == nil,
          "expired request ID remains reserved after restart")

  let approvedID = UUID()
  guard let approvedToken = policy.beginApproval(requestID: approvedID, recipient: recipient,
                                                  text: text, connectionID: connectionID,
                                                  now: 420, lifetime: 10) else {
   fatalError("FAIL: begin approved expiry test")
  }
  require(policy.approve(token: approvedToken, requestID: approvedID, recipient: recipient,
                         text: text, connectionID: connectionID, now: 421), "approve before expiry")
  require(!policy.consume(token: approvedToken, requestID: approvedID, recipient: recipient,
                          text: text, connectionID: connectionID, now: 430), "expired approval cannot dispatch")
 }

 static func testDisconnectRevokesPendingAndApproved() {
  let (policy, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let connectionID = UUID(), otherConnection = UUID()
  let pendingID = UUID(), approvedID = UUID()
  let otherID = UUID()
  guard let pending = policy.beginApproval(requestID: pendingID, recipient: recipient,
                                            text: text, connectionID: connectionID,
                                            now: 500, lifetime: 20),
        let approved = policy.beginApproval(requestID: approvedID, recipient: recipient,
                                             text: text, connectionID: connectionID,
                                             now: 500, lifetime: 20),
        let other = policy.beginApproval(requestID: otherID, recipient: recipient,
                                         text: text, connectionID: otherConnection,
                                         now: 500, lifetime: 20) else {
   fatalError("FAIL: begin disconnect fixtures")
  }
  require(policy.approve(token: approved, requestID: approvedID, recipient: recipient,
                         text: text, connectionID: connectionID, now: 501), "approve before disconnect")
  policy.disconnect(connectionID: connectionID)
  require(!policy.approve(token: pending, requestID: pendingID, recipient: recipient,
                          text: text, connectionID: connectionID, now: 502), "disconnect revokes pending approval")
  require(!policy.consume(token: approved, requestID: approvedID, recipient: recipient,
                           text: text, connectionID: connectionID, now: 502), "disconnect revokes approved token")
  require(policy.approve(token: other, requestID: otherID, recipient: recipient,
                         text: text, connectionID: otherConnection, now: 503),
          "disconnect leaves another connection's approval intact")
 }

 static func testDuplicateRequestIDs() {
  let (policy, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let requestID = UUID(), firstConnection = UUID(), secondConnection = UUID()
  guard let first = policy.beginApproval(requestID: requestID, recipient: recipient,
                                         text: text, connectionID: firstConnection,
                                         now: 600, lifetime: 20) else {
   fatalError("FAIL: first duplicate fixture")
  }
  require(policy.beginApproval(requestID: requestID, recipient: recipient, text: text,
                               connectionID: secondConnection, now: 601) == nil,
          "duplicate request ID rejected while pending")
  require(policy.approve(token: first, requestID: requestID, recipient: recipient,
                         text: text, connectionID: firstConnection, now: 602), "first request remains approvable")
  require(policy.beginApproval(requestID: requestID, recipient: recipient, text: text,
                               connectionID: secondConnection, now: 603) == nil,
          "duplicate request ID rejected while approved")

  let otherID = UUID()
  guard let otherToken = policy.beginApproval(requestID: otherID, recipient: recipient,
                                               text: text, connectionID: firstConnection,
                                               now: 610, lifetime: 20) else {
   fatalError("FAIL: token substitution fixture")
  }
  require(policy.approve(token: otherToken, requestID: otherID, recipient: recipient,
                         text: text, connectionID: firstConnection, now: 611), "approve separate request")
  require(!policy.consume(token: otherToken, requestID: requestID, recipient: recipient,
                          text: text, connectionID: firstConnection, now: 612),
          "another token cannot consume request approval")
  require(policy.consume(token: first, requestID: requestID, recipient: recipient,
                         text: text, connectionID: firstConnection, now: 613),
          "wrong token attempt does not alter the correctly bound approval")
 }

 static func testDurableDuplicateAcrossRestart() {
  let (firstProcess, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let requestID = UUID(), connectionID = UUID()
  guard let token = firstProcess.beginApproval(requestID: requestID, recipient: recipient,
                                               text: text, connectionID: connectionID,
                                               now: 700, lifetime: 20) else {
   fatalError("FAIL: first policy instance reserves request ID")
  }
  require(firstProcess.cancel(token: token), "cancel synthetic approval")

  let dataURL = directory.appendingPathComponent("send-request-ids.txt")
  guard let persisted = try? String(contentsOf: dataURL, encoding: .utf8) else {
   fatalError("FAIL: read synthetic request-ID ledger")
  }
  require(persisted == requestID.uuidString.lowercased() + "\n",
          "ledger contains only the canonical UUID and newline")
  require(!persisted.contains(recipient) && !persisted.contains(text), "ledger excludes recipient and message text")
  var fileInfo = stat()
  require(stat(dataURL.path, &fileInfo) == 0 && (fileInfo.st_mode & 0o777) == 0o600,
          "ledger is owner-only")

  let restartedProcess = MessageDispatchPolicy(storeDirectory: directory)
  require(restartedProcess.beginApproval(requestID: requestID, recipient: recipient,
                                         text: text, connectionID: UUID(), now: 701) == nil,
          "restart rejects a previously used ID after cancellation")
 }

 static func testMissingLedgerFailsClosed() {
  let (policy, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let first = UUID()
  require(policy.reserve(first), "initialize journal")
  do { try FileManager.default.removeItem(at: directory.appendingPathComponent("send-request-ids.txt")) }
  catch { fatalError("FAIL: remove synthetic data file: \(error)") }
  require(!policy.reserve(UUID()), "missing journal fails closed in active process")
  let restarted = MessageDispatchPolicy(storeDirectory: directory)
  require(!restarted.reserve(first), "missing journal does not allow duplicate after restart")
  require(!restarted.reserve(UUID()), "missing journal denies new IDs after restart")

  let (_, interrupted) = makePolicy()
  defer { removeTestDirectory(interrupted) }
  let lockPath = interrupted.appendingPathComponent("send-request-ids.lock").path
  let fd = open(lockPath, O_RDWR | O_CREAT | O_EXCL, 0o600)
  require(fd >= 0, "create synthetic interrupted-initialization marker")
  _ = close(fd)
  require(!MessageDispatchPolicy(storeDirectory: interrupted).reserve(UUID()),
          "interrupted initialization fails closed")
 }

 static func testUnsafeStoreFailsClosed() {
  let (policy, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let ledgerURL = directory.appendingPathComponent("send-request-ids.txt")
  let symlinkTarget = directory.appendingPathComponent("synthetic-target.txt")
  do {
   try Data("synthetic-only\n".utf8).write(to: symlinkTarget)
   try FileManager.default.createSymbolicLink(at: ledgerURL, withDestinationURL: symlinkTarget)
  } catch {
   fatalError("FAIL: create synthetic ledger symlink: \(error)")
  }
  require(!policy.reserve(UUID()), "ledger symlink is rejected")

  let (_, lockDirectory) = makePolicy()
  defer { removeTestDirectory(lockDirectory) }
  let lockURL = lockDirectory.appendingPathComponent("send-request-ids.lock")
  let lockTarget = lockDirectory.appendingPathComponent("synthetic-lock-target.txt")
  do {
   try Data().write(to: lockTarget)
   try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: lockTarget)
  } catch {
   fatalError("FAIL: create synthetic lock symlink: \(error)")
  }
  require(!MessageDispatchPolicy(storeDirectory: lockDirectory).reserve(UUID()), "lock symlink is rejected")

  let (_, targetDirectory) = makePolicy()
  defer { removeTestDirectory(targetDirectory) }
  let alias = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
   .appendingPathComponent("message-policy-alias-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: alias) }
  do {
   try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: targetDirectory)
  } catch {
   fatalError("FAIL: create synthetic directory symlink: \(error)")
  }
  require(!MessageDispatchPolicy(storeDirectory: alias).reserve(UUID()), "directory symlink is rejected")
 }

 static func testConcurrentDuplicateReservation() {
  let (_, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let requestID = UUID()
  let resultLock = NSLock()
  var successes = 0
  DispatchQueue.concurrentPerform(iterations: 24) { index in
   let policy = MessageDispatchPolicy(storeDirectory: directory)
   let token = policy.beginApproval(requestID: requestID, recipient: recipient,
                                    text: text, connectionID: UUID(), now: 800 + Double(index))
   if token != nil {
    resultLock.lock()
    successes += 1
    resultLock.unlock()
   }
  }
  require(successes == 1, "concurrent instances reserve a duplicate UUID exactly once")
 }

 static func testCrossProcessDuplicateReservation() {
  let (_, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let requestID = UUID()
  var workers = [Process]()
  for _ in 0..<8 {
   let worker = Process()
   worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
   worker.arguments = ["--reserve-once", directory.path, requestID.uuidString]
   worker.standardOutput = FileHandle.nullDevice
   worker.standardError = FileHandle.nullDevice
   do {
    try worker.run()
   } catch {
    fatalError("FAIL: start synthetic reservation process: \(error)")
   }
   workers.append(worker)
  }
  for worker in workers { worker.waitUntilExit() }
  let successes = workers.filter { $0.terminationStatus == 0 }.count
  require(successes == 1, "separate processes reserve a duplicate UUID exactly once")
  require(!MessageDispatchPolicy(storeDirectory: directory).reserve(requestID),
          "cross-process winner is present in the durable ledger")
 }

 static func testPersistentCapacityAcrossRestart() {
  let (_, directory) = makePolicy()
  defer { removeTestDirectory(directory) }
  let ids = (0..<1000).map { _ in UUID() }
  let content = ids.map { $0.uuidString.lowercased() }.joined(separator: "\n") + "\n"
  let dataURL = directory.appendingPathComponent("send-request-ids.txt")
  guard FileManager.default.createFile(atPath: dataURL.path, contents: Data(content.utf8),
                                       attributes: [.posixPermissions: 0o600]),
        chmod(dataURL.path, 0o600) == 0 else {
   fatalError("FAIL: seed bounded synthetic ledger")
  }
  let restartedProcess = MessageDispatchPolicy(storeDirectory: directory)
  require(!restartedProcess.reserve(UUID()), "ledger denies IDs after the persistent cap")
  require(!MessageDispatchPolicy(storeDirectory: directory).reserve(ids[0]), "duplicate at capacity remains denied")
 }

 static func testSyntheticAppSupportContainer() {
  let container = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
   .appendingPathComponent("synthetic-messages-app-\(UUID().uuidString)", isDirectory: true)
  defer { removeTestDirectory(container) }
  do {
   try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
  } catch {
   fatalError("FAIL: create synthetic app container: \(error)")
  }
  let appSupportStore = container
   .appendingPathComponent("Library", isDirectory: true)
   .appendingPathComponent("Application Support", isDirectory: true)
   .appendingPathComponent("MessagesLocalSendPolicy", isDirectory: true)
  require(MessageDispatchPolicy(storeDirectory: appSupportStore).reserve(UUID()),
          "synthetic app can create a missing owner-only Application Support path")
  for path in [container.appendingPathComponent("Library"),
               container.appendingPathComponent("Library/Application Support"),
               appSupportStore] {
   var info = stat()
   require(stat(path.path, &info) == 0 && info.st_uid == getuid() && (info.st_mode & 0o077) == 0,
           "created synthetic container component is owner-only")
  }

  let unsafeContainer = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
   .appendingPathComponent("synthetic-messages-app-link-\(UUID().uuidString)", isDirectory: true)
  defer { removeTestDirectory(unsafeContainer) }
  do {
   try FileManager.default.createDirectory(at: unsafeContainer, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
   try FileManager.default.createSymbolicLink(at: unsafeContainer.appendingPathComponent("Library"),
                                               withDestinationURL: container)
  } catch {
   fatalError("FAIL: create synthetic container symlink: \(error)")
  }
  let unsafeStore = unsafeContainer
   .appendingPathComponent("Library/Application Support", isDirectory: true)
   .appendingPathComponent("MessagesLocalSendPolicy", isDirectory: true)
  require(!MessageDispatchPolicy(storeDirectory: unsafeStore).reserve(UUID()),
          "intermediate symlink in synthetic container is rejected")
 }
}
