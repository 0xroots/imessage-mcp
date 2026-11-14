import Foundation
import Darwin

// Sends bounded chunks with a fresh authorization check before every write.
// Stop shares the same lock, revokes the session, shuts down the socket and
// signals wakeDescriptor, so the writer cannot append bytes after Stop returns.
final class RevocableSocketWriter {
 private let lock: NSLocking
 private let wakeDescriptor: Int32
 private let shouldSend: () -> Bool
 private let onWrite: ((Int) -> Void)?
 private let onWouldBlock: (() -> Void)?
 private let chunkSize = 16 * 1_024
 private let maximumSendDuration: TimeInterval = 5

 init(lock: NSLocking, wakeDescriptor: Int32,
      onWrite: ((Int) -> Void)? = nil,
      onWouldBlock: (() -> Void)? = nil,
      shouldSend: @escaping () -> Bool) {
  self.lock = lock
  self.wakeDescriptor = wakeDescriptor
  self.onWrite = onWrite
  self.onWouldBlock = onWouldBlock
  self.shouldSend = shouldSend
 }

 func send(_ data: Data, to descriptor: Int32) -> Bool {
  lock.lock()
  guard shouldSend() else { lock.unlock(); return false }
  guard let originalFlags = getStatusFlags(descriptor),
        setStatusFlags(descriptor, originalFlags | O_NONBLOCK) else {
   lock.unlock()
   return false
  }
  lock.unlock()
  let completed = sendChunks(data, to: descriptor, deadline: ProcessInfo.processInfo.systemUptime + maximumSendDuration)
  lock.lock()
  let restored = setStatusFlags(descriptor, originalFlags)
  lock.unlock()
  return completed && restored
 }

 private func sendChunks(_ data: Data, to descriptor: Int32, deadline: TimeInterval) -> Bool {
  var offset = 0
  while offset < data.count {
   guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
   lock.lock()
   guard shouldSend() else { lock.unlock(); return false }
   let count = min(chunkSize, data.count - offset)
   let written = data.withUnsafeBytes { bytes -> Int in
    guard let base = bytes.baseAddress else { return -1 }
    return Darwin.send(descriptor, base.advanced(by: offset), count, Int32(MSG_DONTWAIT))
   }
   let writeError = errno
   if written > 0 {
    onWrite?(written)
    lock.unlock()
    offset += written
    continue
   }
   lock.unlock()
   if written == 0 { return false }
   if writeError == EINTR { continue }
   if writeError != EAGAIN && writeError != EWOULDBLOCK { return false }

   onWouldBlock?()
   var fds = [
    pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0),
    pollfd(fd: wakeDescriptor, events: Int16(POLLIN), revents: 0)
   ]
   let ready = fds.withUnsafeMutableBufferPointer { buffer in
    poll(buffer.baseAddress, nfds_t(buffer.count), 250)
   }
   if ready < 0 && errno != EINTR { return false }
   if ready > 0 && (fds[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 { return false }
   // On timeout, or after wakeup, loop and recheck authorization under lock.
  }
  return true
 }

 private func getStatusFlags(_ descriptor: Int32) -> Int32? {
  while true {
   let flags = fcntl(descriptor, F_GETFL, 0)
   if flags >= 0 { return flags }
   if errno != EINTR { return nil }
  }
 }

 private func setStatusFlags(_ descriptor: Int32, _ flags: Int32) -> Bool {
  while true {
   if fcntl(descriptor, F_SETFL, flags) == 0 { return true }
   if errno != EINTR { return false }
  }
 }
}
