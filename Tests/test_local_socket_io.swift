import Foundation
import Darwin

final class DataResult {
 private let lock = NSLock()
 private var stored: Data?
 func set(_ value: Data?) { lock.lock(); stored = value; lock.unlock() }
 func get() -> Data? { lock.lock(); defer { lock.unlock() }; return stored }
}

@main struct Test {
 static func main() {
  let path = "/private/tmp/mcp-\(UUID().uuidString).sock"
  let server = socket(AF_UNIX, SOCK_STREAM, 0)
  let client = socket(AF_UNIX, SOCK_STREAM, 0)
  precondition(server >= 0 && client >= 0 && path.utf8.count < 103)
  var accepted: Int32 = -1
  defer {
   _ = close(server)
   _ = close(client)
   if accepted >= 0 { _ = close(accepted) }
   _ = unlink(path)
  }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let pathBytes = Array(path.utf8) + [0]
  withUnsafeMutableBytes(of: &address.sun_path) { bytes in
   for index in pathBytes.indices { bytes[index] = pathBytes[index] }
  }
  let bound = withUnsafePointer(to: &address) {
   $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
    bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
   }
  }
  precondition(bound == 0 && listen(server, 1) == 0)
  let listenerFlags = fcntl(server, F_GETFL, 0)
  precondition(listenerFlags >= 0 && fcntl(server, F_SETFL, listenerFlags | O_NONBLOCK) == 0)
  let connected = withUnsafePointer(to: &address) {
   $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
    connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
   }
  }
  precondition(connected == 0)
  accepted = accept(server, nil, nil)
  precondition(accepted >= 0)
  let inheritedFlags = fcntl(accepted, F_GETFL, 0)
  precondition(inheritedFlags >= 0 && inheritedFlags & O_NONBLOCK != 0,
               "this macOS listener returns accepted sockets as nonblocking")
  precondition(LocalSocketIO.setBlocking(accepted), "accepted descriptor should be restored to blocking mode")
  let restoredFlags = fcntl(accepted, F_GETFL, 0)
  precondition(restoredFlags >= 0 && restoredFlags & O_NONBLOCK == 0)

  let prefix = Data("{\"operation\":".utf8)
  let suffix = Data("\"get_messages\"}\n".utf8)
  let prefixConsumed = DispatchSemaphore(value: 0)
  let lineReady = DispatchSemaphore(value: 0)
  let result = DataResult()
  let readFD = accepted
  DispatchQueue.global().async {
   var count = 0
   let line = LocalSocketIO.readLine(readFD, limit: 1_024) {
    count += 1
    if count == prefix.count { prefixConsumed.signal() }
   }
   result.set(line)
   lineReady.signal()
  }

  let prefixWritten = prefix.withUnsafeBytes { bytes in Darwin.write(client, bytes.baseAddress!, prefix.count) }
  precondition(prefixWritten == prefix.count)
  precondition(prefixConsumed.wait(timeout: .now() + 2) == .success, "reader should consume partial frame")
  let suffixWritten = suffix.withUnsafeBytes { bytes in Darwin.write(client, bytes.baseAddress!, suffix.count) }
  precondition(suffixWritten == suffix.count)
  precondition(lineReady.wait(timeout: .now() + 2) == .success, "reader should finish after newline")
  precondition(result.get() == prefix + Data("\"get_messages\"}".utf8))
  print("PASS accepted nonblocking socket reset and partial newline-framed request")
 }
}
