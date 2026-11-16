import Foundation
import Darwin
import Security

// Explicitly started by the user; never a launch agent. Several clients (for
// example Claude Code and Codex) can be connected at once. The owner approves each
// connection, one approval dialog at a time, and all approvals share one run cap.
final class LocalIPCServer {
 private let state = NSCondition()
 private var listener: Int32 = -1
 private var activeFDs = Set<Int32>()
 private var connectionCount = 0
 private var clientLabels: [UUID: String] = [:]
 private static let maxConnections = 8
 private let handlers = DispatchQueue(label: "messagesmcp.connections", qos: .userInitiated, attributes: .concurrent)
 // Approval and send-confirmation dialogs never overlap, whichever connection asks.
 private let approvalGate = NSLock()
 static let idleReadSeconds = 3600
 private var wakeRead: Int32 = -1
 private var wakeWrite: Int32 = -1
 private var running = false
 private var workerActive = false
 private var starting = false
 private var socketPath = ""

 private let authority = SessionAuthority()
 private let folder: URL
 private let filename: String
 private let limits: SessionAuthority.Limits
 private let onRunExpired: () -> Void
 private let onClient: (String?) -> Void
 private let choose: (@escaping () -> Bool) -> SessionAuthority.Mode?
 private let confirmSend: (String, String, @escaping () -> Bool) -> Bool
 private let sendText: (String, String, @escaping () -> Bool) -> String

 init(folder: URL, filename: String, limits: SessionAuthority.Limits,
      onRunExpired: @escaping () -> Void = {},
      onClient: @escaping (String?) -> Void = { _ in },
      confirmSend: @escaping (String, String, @escaping () -> Bool) -> Bool = {_,_,_ in false},
      sendText: @escaping (String, String, @escaping () -> Bool) -> String = {_,_,_ in "not_attempted"},
      choose: @escaping (@escaping () -> Bool) -> SessionAuthority.Mode?) {
  self.folder = folder
  self.filename = filename
  self.limits = limits
  self.onRunExpired = onRunExpired
  self.onClient = onClient
  self.confirmSend = confirmSend
  self.sendText = sendText
  self.choose = choose
 }

 // A socket file left behind by a crashed or force-quit run blocks the next start.
 // Remove it only when it is our own socket and nothing is listening on it.
 private static func clearStaleSocket(at path: String) -> Bool {
  var st = stat()
  if lstat(path, &st) != 0 { return errno == ENOENT }
  guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { return false }
  let probe = socket(AF_UNIX, SOCK_STREAM, 0)
  guard probe >= 0 else { return false }
  defer { _ = close(probe) }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let bytes = Array(path.utf8) + [0]
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
   for index in bytes.indices { buffer[index] = bytes[index] }
  }
  let rc = withUnsafePointer(to: &address) {
   $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
    connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
   }
  }
  // A live listener means another copy of the app is running the bridge: leave it alone.
  guard rc != 0, errno == ECONNREFUSED else { return false }
  return unlink(path) == 0
 }

 // True once if a client asked for more message slots than the run has left.
 func takeBudgetDenied() -> Bool { authority.takeBudgetDenied() }

 func start() -> Bool {
  state.lock()
  if workerActive {
   _ = state.wait(until: Date(timeIntervalSinceNow: 2))
  }
  guard !running, !workerActive, !starting else { state.unlock(); return false }
  starting = true
  state.unlock()

  var listenerFD: Int32 = -1
  var wakeFDs: [Int32] = [-1, -1]
  var didBind = false
  var beganRun = false
  var registered = false
  let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("messages-mcp.sock")
  defer {
   if !registered {
    if beganRun { authority.endExplicitSession() }
    if listenerFD >= 0 { _ = close(listenerFD) }
    for fd in wakeFDs where fd >= 0 { _ = close(fd) }
    if didBind { _ = unlink(path) }
    state.lock()
    starting = false
    state.broadcast()
    state.unlock()
   }
  }

  guard path.utf8.count < 103 else { return false }
  guard Self.clearStaleSocket(at: path) else { return false }
  listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
  guard listenerFD >= 0 else { return false }
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &wakeFDs) == 0 else { return false }
  let wakeFlags = fcntl(wakeFDs[1], F_GETFL, 0)
  guard wakeFlags >= 0, fcntl(wakeFDs[1], F_SETFL, wakeFlags | O_NONBLOCK) == 0 else { return false }
  var noSignal: Int32 = 1
  _ = setsockopt(wakeFDs[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
  _ = setsockopt(wakeFDs[1], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let bytes = Array(path.utf8) + [0]
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
   for index in bytes.indices { buffer[index] = bytes[index] }
  }
  let bound = withUnsafePointer(to: &address) {
   $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
    bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
   }
  }
  guard bound == 0 else { return false }
  didBind = true
  guard chmod(path, 0o600) == 0, listen(listenerFD, 8) == 0 else { return false }
  let listenerFlags = fcntl(listenerFD, F_GETFL, 0)
  guard listenerFlags >= 0, fcntl(listenerFD, F_SETFL, listenerFlags | O_NONBLOCK) == 0 else { return false }
  guard authority.beginExplicitSession(limits: limits) else { return false }
  beganRun = true

  state.lock()
  listener = listenerFD
  wakeRead = wakeFDs[0]
  wakeWrite = wakeFDs[1]
  socketPath = path
  running = true
  workerActive = true
  starting = false
  state.broadcast()
  state.unlock()
  registered = true

  DispatchQueue.global(qos: .userInitiated).async {
   self.serve(listener: listenerFD, wakeRead: wakeFDs[0], wakeWrite: wakeFDs[1], path: path)
  }
  return true
 }

 // Stop revokes the authority before waking the worker. The worker owns and
 // closes listener/wake descriptors after it exits, preventing FD reuse races.
 func stop() {
  state.lock()
  running = false
  authority.endExplicitSession()
  for fd in activeFDs { _ = shutdown(fd, SHUT_RDWR) }
  if wakeWrite >= 0 {
   var byte: UInt8 = 1
   _ = Darwin.write(wakeWrite, &byte, 1)
  }
  state.unlock()
 }

 private func isRunning() -> Bool {
  state.lock(); defer { state.unlock() }
  return running
 }

 private func trusted(_ fd: Int32) -> Bool {
  var uid: uid_t = 0, gid: gid_t = 0
  guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
  var token = [UInt8](repeating: 0, count: 32)
  var length = socklen_t(token.count)
  guard token.withUnsafeMutableBytes({ getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, $0.baseAddress, &length) }) == 0,
        length == 32 else { return false }
  var code: SecCode?, requirement: SecRequirement?
  guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: Data(token)] as CFDictionary,
                                       SecCSFlags(), &code) == errSecSuccess, let code else { return false }
  let text = BuildIdentity.adapterRequirement
  guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
        let requirement else { return false }
  return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
 }

 private func serve(listener listenerFD: Int32, wakeRead wakeReadFD: Int32,
                    wakeWrite wakeWriteFD: Int32, path: String) {
  defer {
   // Connection handlers use the wake descriptor: wait for them before closing it.
   state.lock()
   let deadline = Date(timeIntervalSinceNow: 10)
   while connectionCount > 0 && Date() < deadline { _ = state.wait(until: deadline) }
   state.unlock()
   workerFinished(listener: listenerFD, wakeRead: wakeReadFD, wakeWrite: wakeWriteFD, path: path)
  }
  while isRunning() {
   guard let fd = nextConnection(listener: listenerFD, wakeRead: wakeReadFD) else { break }
   guard LocalSocketIO.setBlocking(fd) else { _ = close(fd); continue }
   state.lock()
   if !running { state.unlock(); _ = close(fd); break }
   if activeFDs.count >= Self.maxConnections { state.unlock(); _ = close(fd); continue }
   activeFDs.insert(fd)
   connectionCount += 1
   state.unlock()

   handlers.async { [self] in
    process(fd, wakeRead: wakeReadFD)
    // Leave the set before closing so Stop can never shut down a reused descriptor.
    state.lock()
    activeFDs.remove(fd)
    connectionCount -= 1
    state.broadcast()
    state.unlock()
    _ = close(fd)
   }
  }
 }

 private func nextConnection(listener listenerFD: Int32, wakeRead wakeReadFD: Int32) -> Int32? {
  while isRunning() {
   guard authority.explicitSessionIsCurrent() else {
    stop()
    DispatchQueue.main.async { [weak self] in self?.onRunExpired() }
    return nil
   }
   var descriptors = [
    pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0),
    pollfd(fd: wakeReadFD, events: Int16(POLLIN), revents: 0)
   ]
   let result = descriptors.withUnsafeMutableBufferPointer { buffer in
    poll(buffer.baseAddress, nfds_t(buffer.count), 1_000)
   }
   if result == 0 { continue }
   if result < 0 {
    if errno == EINTR { continue }
    return nil
   }
   if descriptors[1].revents & Int16(POLLIN) != 0 {
    var byte: UInt8 = 0
    _ = Darwin.read(wakeReadFD, &byte, 1)
    if !isRunning() { return nil }
   }
   if !isRunning() { return nil }
   if descriptors[0].revents & Int16(POLLIN) != 0 {
    let fd = accept(listenerFD, nil, nil)
    if fd >= 0 { return fd }
    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
    return nil
   }
   if descriptors[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return nil }
  }
  return nil
 }

 private func process(_ fd: Int32, wakeRead wakeReadFD: Int32) {
  guard isRunning(), authority.explicitSessionIsCurrent() else { return }
  guard trusted(fd) else { return }
  var timeout = timeval(tv_sec: 30, tv_usec: 0), one: Int32 = 1
  _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

  // Consume the first framed request before showing the approval UI. This
  // leaves the socket readable on peer close, so a stale modal can be dismissed.
  guard let firstLine = LocalSocketIO.readLine(fd, limit: 65_536) else { return }
  let connection = UUID()
  let stillConnected: () -> Bool = {
   guard self.isRunning(), self.authority.explicitSessionIsCurrent() else { return false }
   var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
   let rc = poll(&pfd, 1, 0)
   if rc < 0 { return errno == EINTR }
   if rc == 0 { return true }
   if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return false }
   if pfd.revents & Int16(POLLIN) != 0 {
    var byte: UInt8 = 0
    let n = recv(fd, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
    if n == 0 { return false }
    if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { return false }
   }
   return true
  }
  var selected: SessionAuthority.Mode?
  approvalGate.lock()
  DispatchQueue.main.sync {
   if stillConnected() { selected = self.choose(stillConnected) }
  }
  approvalGate.unlock()
  guard let selected, stillConnected(),
        authority.grant(connection: connection, mode: selected,
                        seconds: Double(limits.durationSeconds), ownerConfirmed: true, warningConfirmed: true) else { return }

  // The approved connection stays open between tool calls. The 30 s read timeout above only
  // guards the approval handshake; keeping it would drop idle clients and force a new approval
  // dialog on their next call. The run expiry and the stop button still end the connection.
  var idle = timeval(tv_sec: Self.idleReadSeconds, tv_usec: 0)
  _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &idle, socklen_t(MemoryLayout<timeval>.size))

  // Client label is display-only: printable ASCII, short. It never affects authorization.
  let rawClient = ((try? JSONSerialization.jsonObject(with: firstLine)) as? [String: Any])?["client"] as? String ?? ""
  let clientLabel = String(rawClient.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 }.prefix(40))
  setClient(connection, clientLabel.isEmpty ? "AI tool" : clientLabel)
  var pending: Data? = firstLine
  while isRunning() {
   let received = pending ?? LocalSocketIO.readLine(fd, limit: 65_536)
   pending = nil
   guard let line = received else { break }
   guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { break }
   let operation = (request["operation"] as? String).flatMap { BackendRouter.names.contains($0) || $0 == "send_message" ? $0 : nil } ?? "invalid"
   let result: [String:Any]
   if operation == "send_message" {
    result = handleSend(request, connection:connection, fd:fd, stillConnected:stillConnected)
   } else {
    result = BackendRouter.response(authority: authority, connection: connection,
                                     folder: folder, filename: filename, request: request)
   }
   let status = result["error"] == nil ? "ok" : "denied_or_error"
   NSLog("MessagesMCP operation=%@ status=%@", operation, status)
   guard var data = try? JSONSerialization.data(withJSONObject: result) else { break }
   if data.count > limits.maxResponseBytes {
    data = (try? JSONSerialization.data(withJSONObject: BackendRouter.error("response_too_large"))) ?? Data()
   }
   guard data.count <= limits.maxResponseBytes, isRunning() else { break }
   data.append(10)
   let writer = RevocableSocketWriter(lock: state, wakeDescriptor: wakeReadFD) {
    self.running && self.activeFDs.contains(fd) && self.authority.currentMode(connection: connection) != nil
   }
   if !writer.send(data, to: fd) { break }
  }
  authority.revoke(connection)
  MessageDispatchPolicy.shared.disconnect(connectionID:connection)
  setClient(connection, nil)
 }

 // Shows every connected client, e.g. "Claude, codex".
 private func setClient(_ connection: UUID, _ label: String?) {
  state.lock()
  clientLabels[connection] = label
  var seen = Set<String>()
  let names = clientLabels.values.sorted().filter { seen.insert($0).inserted }
  state.unlock()
  let text = names.isEmpty ? nil : names.joined(separator: ", ")
  DispatchQueue.main.async { [weak self] in self?.onClient(text) }
 }

 // The permission to read a chat never authorizes sending: every send has a
 // fresh local confirmation. Never retry automatically after an uncertain result.
 private func handleSend(_ request:[String:Any],connection:UUID,fd:Int32,stillConnected:@escaping ()->Bool)->[String:Any] {
  guard Set(request.keys).isSubset(of:["operation","arguments","client"]),let args=request["arguments"] as? [String:Any],
        Set(args.keys)==Set(["recipient","text","request_id"]),let recipient=args["recipient"] as? String,
        let text=args["text"] as? String,let rawID=args["request_id"] as? String,let requestID=UUID(uuidString:rawID),
        MessageDispatchPolicy.valid(recipient:recipient,text:text) else {return BackendRouter.error("invalid_send_request")}
  guard let ticket=authority.ticket(connection:connection,chat:nil,allowAssistedListing:true) else{return BackendRouter.error("access_denied")}
  let policy=MessageDispatchPolicy.shared
  let started=ProcessInfo.processInfo.systemUptime
  guard let token=policy.beginApproval(requestID:requestID,recipient:recipient,text:text,connectionID:connection,now:started) else{
   switch policy.lastFailure {
   case .duplicate: return BackendRouter.error("duplicate_request_id")
   case .full: return BackendRouter.error("request_id_ledger_full")
   case .unavailable: return BackendRouter.error("request_id_ledger_unavailable")
   case nil: return BackendRouter.error("send_rejected")
   }
  }
  defer{policy.cancel(token:token)}
  let approvalAlive: () -> Bool = { stillConnected() && self.authority.isCurrent(ticket) && ProcessInfo.processInfo.systemUptime < started + MessageDispatchPolicy.approvalLifetime }
  var confirmed=false
  approvalGate.lock()
  DispatchQueue.main.sync {
   if approvalAlive() {confirmed=self.confirmSend(recipient,text,approvalAlive)}
  }
  approvalGate.unlock()
  guard confirmed,approvalAlive(),policy.approve(token:token,requestID:requestID,recipient:recipient,text:text,connectionID:connection) else{return BackendRouter.error("send_not_approved")}
  // Commit is ordered against Stop. Once committed, an OS send cannot be
  // recalled; connection failure afterwards is treated as unknown, never retry.
  let canDispatch: () -> Bool = {
   guard stillConnected() else { return false }
   self.state.lock(); defer { self.state.unlock() }
   return self.running && self.activeFDs.contains(fd) && self.authority.isCurrent(ticket) && policy.consume(token:token,requestID:requestID,recipient:recipient,text:text,connectionID:connection)
  }
  guard stillConnected(),authority.isCurrent(ticket) else{return BackendRouter.error("access_revoked")}
  let outcome=sendText(recipient,text,canDispatch)
  // sendText may append ":<reason>" (enum name only); split it into its own field.
  let parts=outcome.split(separator:":",maxSplits:1).map(String.init)
  var reply:[String:Any]=["status":parts.first ?? "unknown","delivery_confirmed":false]
  if parts.count==2 {reply["reason"]=parts[1]}
  return reply
 }

 private func workerFinished(listener listenerFD: Int32, wakeRead wakeReadFD: Int32,
                             wakeWrite wakeWriteFD: Int32, path: String) {
  authority.endExplicitSession()
  state.lock()
  running = false
  if listener == listenerFD { listener = -1 }
  if wakeRead == wakeReadFD { wakeRead = -1 }
  if wakeWrite == wakeWriteFD { wakeWrite = -1 }
  activeFDs.removeAll()
  state.unlock()

  _ = close(listenerFD)
  _ = close(wakeReadFD)
  _ = close(wakeWriteFD)
  _ = unlink(path)

  state.lock()
  workerActive = false
  socketPath = ""
  state.broadcast()
  state.unlock()
 }
}
