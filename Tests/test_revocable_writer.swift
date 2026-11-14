import Foundation
import Darwin

@main struct Test {
 static func main() {
  var sockets: [Int32] = [-1, -1]
  var wake: [Int32] = [-1, -1]
  precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
  precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &wake) == 0)
  defer {
   for fd in sockets + wake where fd >= 0 { _ = close(fd) }
  }

  var sendBuffer: Int32 = 4_096
  _ = setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
  var noSignal: Int32 = 1
  _ = setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
  _ = setsockopt(wake[1], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

  let gate = NSLock()
  let didBlock = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)
  var permitted = true
  var didSignalBlock = false
  var sentBytes = 0
  var completed = true
  let payload = Data(repeating: 0x58, count: 1_048_576)
  let writer = RevocableSocketWriter(lock: gate, wakeDescriptor: wake[0], onWrite: { count in
   sentBytes += count
  }, onWouldBlock: {
   if !didSignalBlock { didSignalBlock = true; didBlock.signal() }
  }) {
   permitted
  }

  DispatchQueue.global().async {
   completed = writer.send(payload, to: sockets[0])
   finished.signal()
  }
  precondition(didBlock.wait(timeout: .now() + 3) == .success, "send should reach a blocked socket")

  // This is the server's Stop critical section: revoke first, shutdown, wake.
  gate.lock()
  permitted = false
  _ = shutdown(sockets[0], SHUT_RDWR)
  var byte: UInt8 = 1
  _ = Darwin.write(wake[1], &byte, 1)
  let bytesAtStop = sentBytes
  gate.unlock()

  precondition(finished.wait(timeout: .now() + 3) == .success, "Stop must release a blocked writer")
  precondition(!completed, "revoked sender must report incomplete response")
  gate.lock()
  let bytesAfterStop = sentBytes
  gate.unlock()
  precondition(bytesAfterStop == bytesAtStop, "writer appended bytes after Stop returned")
  precondition(bytesAtStop < payload.count, "saturated socket must leave response incomplete")

  // Bytes already queued before Stop may remain readable, but the full line
  // was never queued and no new bytes are appended after Stop returns.
  var received = 0
  var buffer = [UInt8](repeating: 0, count: 16_384)
  while true {
   let count = Darwin.read(sockets[1], &buffer, buffer.count)
   if count <= 0 { break }
   received += count
  }
  precondition(received <= bytesAtStop && received < payload.count)
  print("PASS Stop revokes a blocked synthetic send without completing the response")
 }
}
