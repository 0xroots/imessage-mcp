import Foundation
import Darwin

enum LocalSocketIO {
 static func setBlocking(_ descriptor: Int32) -> Bool {
  let flags: Int32
  while true {
   let current = fcntl(descriptor, F_GETFL, 0)
   if current >= 0 { flags = current; break }
   if errno != EINTR { return false }
  }
  guard flags & O_NONBLOCK != 0 else { return true }
  while true {
   if fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 { return true }
   if errno != EINTR { return false }
  }
 }

 static func readLine(_ descriptor: Int32, limit: Int, onByte: (() -> Void)? = nil) -> Data? {
  guard limit > 0 else { return nil }
  var data = Data(), byte: UInt8 = 0
  while true {
   let count = Darwin.read(descriptor, &byte, 1)
   if count < 0 && errno == EINTR { continue }
   if count <= 0 { return nil }
   if byte == 10 { return data }
   if data.count >= limit { return nil }
   data.append(byte)
   onByte?()
  }
 }
}
