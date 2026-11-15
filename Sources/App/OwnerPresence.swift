import AppKit
import LocalAuthentication

// Message text is shown only after the Mac's owner proves presence (Touch ID or the
// login password). Software that drives the screen, such as an AI assistant, cannot
// pass this step, so it cannot open the message browser behind the owner's back.
enum OwnerPresence {
 static func confirm(reason: String, then: @escaping (Bool) -> Void) {
  let context = LAContext()
  var error: NSError?
  guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
   then(false)
   return
  }
  context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
   DispatchQueue.main.async { then(ok) }
  }
 }
}
